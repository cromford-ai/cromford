// BH-7429: the build record end to end. The REAL bash writer
// (bin/lib/pool-record.sh pool_record_put) builds the POST body from a
// fixture build dir, the REAL worker (worker.fetch on node:sqlite with the
// composed jobs schema) stores it and answers the GET at the path the REAL
// bash reader (pool_record_get) asks for, and the reader writes the files
// back. Every file must come back byte for byte.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const REPO = resolve(fileURLToPath(new URL('../../..', import.meta.url)));
const LIB = join(REPO, 'bin/lib/pool-record.sh');
const SECRET = 'tok-fixture-bh7429-rt';

function call(DB, method, path, body) {
  const init = { method, headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' } };
  if (body !== undefined) init.body = body;
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, text: await res.text() }));
}
// bash <script> with the lib sourced; the fixture transport is in the script.
function bash(dir, script) {
  return execFileSync('bash', ['-c', `set -u; . "${LIB}" || exit 7\n${script}`], {
    env: { PATH: process.env.PATH, HARNESS: REPO, TMPDIR: join(dir, 'tmp'), POOL_RECORD_FILE_MAX_BYTES: '4096', POOL_RECORD_FAILOVERS_BYTES: '3000' },
    encoding: 'utf8',
  });
}

test('RT1 the bash writer -> the worker -> the bash reader gives every file back byte for byte', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable');
  const dir = mkdtempSync(join(tmpdir(), 'pool-record-rt-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  mkdirSync(join(dir, 'tmp'));
  const bd = join(dir, 'builds', 'project-6-os-TK-7-202610191500');
  mkdirSync(bd, { recursive: true });
  const src = {
    'plan.md': Buffer.from('# Plan\n\nKörper — naïve ✓ 日本語\n', 'utf8'),
    'review.md': Buffer.from('VERDICT: APPROVE\r\nline two\r\n', 'utf8'),
    'reviewed-sha': Buffer.from('0123456789abcdef', 'utf8'),
    'e2e.md': Buffer.alloc(0),
    'pipeline.log': Buffer.from('x'.repeat(5000), 'utf8'),
  };
  for (const [n, b] of Object.entries(src)) writeFileSync(join(bd, n), b);
  const result = Buffer.from('PR_CREATED https://github.com/o/r/pull/7\nTIER: 2\nBUILD_DIR: /data/harness/builds/project-6-os-TK-7-202610191500\n');
  writeFileSync(join(dir, 'RESULT'), result);
  writeFileSync(join(dir, 'failovers.log'), Buffer.from('a'.repeat(70000) + '\nlast line\n'));

  // 1. the writer: its body goes where the fixture _jobs_req_file puts it.
  bash(dir, `_jobs_req_file() { cp "$3" "${dir}/body.json"; }
pool_record_put project-6-os TK-7 m1 "${dir}/RESULT" "${bd}" "${dir}/failovers.log" || exit 8`);
  const post = await call(o.DB, 'POST', '/api/pool/records', readFileSync(join(dir, 'body.json'), 'utf8'));
  assert.equal(post.status, 200, post.text);
  assert.equal(JSON.parse(post.text).skipped, 1);

  // 2. the reader asks; the worker answers that exact path.
  const spawned = new Date(Date.now() - 120e3).toISOString().replace(/\.\d{3}Z$/, 'Z').replace('T', ' '); // determinism: ok the worker stamps posted_at with its own clock, so the spawn must be just before it
  bash(dir, `_jobs_req() { printf '%s' "$2" > "${dir}/get.path"; return 2; }
pool_record_get project-6-os TK-7 m1 "${spawned}" "${dir}/stage0"; [ $? = 2 ] || exit 9`);
  const path = readFileSync(join(dir, 'get.path'), 'utf8');
  assert.match(path, /^\/api\/pool\/records\?project=project-6-os&key=TK-7&machine=m1&since=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
  const got = await call(o.DB, 'GET', path);
  assert.equal(got.status, 200, got.text);
  writeFileSync(join(dir, 'get.json'), got.text);
  const out = bash(dir, `_jobs_req() { cat "${dir}/get.json"; }
pool_record_get project-6-os TK-7 m1 "${spawned}" "${dir}/stage" || exit 10`);
  assert.equal(out, 'project-6-os-TK-7-202610191500\tpipeline.log\n');

  // 3. byte for byte.
  const stage = join(dir, 'stage');
  for (const n of ['plan.md', 'review.md', 'reviewed-sha']) {
    assert.equal(Buffer.compare(readFileSync(join(stage, n)), src[n]), 0, n);
  }
  assert.equal(Buffer.compare(readFileSync(join(stage, 'RESULT')), result), 0, 'RESULT');
  const fo = readFileSync(join(dir, 'failovers.log'));
  assert.equal(Buffer.compare(readFileSync(join(stage, 'failovers.log')), fo.subarray(fo.length - 3000)), 0, 'failovers.log tail');
  // The ssh pull never wrote an empty file ([ -s ]), and a skipped one is named, not written.
  assert.equal(existsSync(join(stage, 'e2e.md')), false, 'an empty file is left out, as over ssh');
  assert.equal(existsSync(join(stage, 'pipeline.log')), false, 'a skipped file is not written');
  assert.deepEqual(readdirSync(stage).sort(), ['RESULT', 'failovers.log', 'plan.md', 'review.md', 'reviewed-sha']);

  // 4. the stamp the reader's side sends is the one the worker takes.
  bash(dir, `_jobs_req() { printf '%s' "$3" > "${dir}/stamp.json"; }
pool_record_reaped project-6-os TK-7 m1 project-6-os-TK-7-202610191500 || exit 11`);
  const st = await call(o.DB, 'POST', '/api/pool/records/reaped', readFileSync(join(dir, 'stamp.json'), 'utf8'));
  assert.equal(st.status, 200, st.text);
  assert.equal(JSON.parse(st.text).reaped, 6);
});
