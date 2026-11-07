// BH-9076: the 20 hot statements of the harness-jobs D1 use an index, on the
// BH-6727 volume D1 (wakes 206k, cost_rows 95k, jobs 49k, job_heartbeats 46k,
// ledgers 27k rows).
//
// The fixture test/fixtures/hot-statements.bh-9076.json was captured by
// driving the 6727 suite's routes plus the box-tick routes (job heartbeat, job
// live view, wake claim, ledger claim) through capturingD1 on openVolumeDb(),
// deduped by normalized text, and kept to statements whose full text is one
// literal in src/ (so E1 can pin it). Time binds are stored as {ago_h: N} and
// resolve through isoAgo, the d1-volume clock anchor.
//
// E1 pins the fixture to the code: a statement that drifted from src/ fails.
// E2 pins the scan rule on literal plan lines. E3 runs EXPLAIN QUERY PLAN of
// each statement with its binds and fails on any `SCAN <hot table>` or
// `CORRELATED` line. No ANALYZE is run: D1 has no statistics either.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ensureColumns } from '../src/lib/core.js';
import { openVolumeDb, plan, isoAgo } from './lib/d1-volume.bh-6727.js';
import { d1 } from './lib/d1-sqlite.bh-1030.js';
import { HOT_TABLES, aliasesOf, failingLines, normalizeSql } from './lib/hot-scan.bh-9076.js';

const FIXTURE = JSON.parse(readFileSync(new URL('./fixtures/hot-statements.bh-9076.json', import.meta.url), 'utf8'));
const SRC = fileURLToPath(new URL('../src/', import.meta.url));

// The SCAN lines this test accepts on a hot table. Empty: none of the 20 is
// the one scan the 6727 suite allows (GET /api/jobs with no filter, an ordered
// walk of idx_jobs_created that stops at its LIMIT), so no entry is argued here.
const ALLOW = [];
// The 6727 suite's allow entry, used by E2 only, to prove an allow entry is
// what lets that line pass.
const ALLOW_6727 = [/^SCAN j USING INDEX idx_jobs_created$/];

const ws = (s) => s.replace(/\s+/g, ' ').trim();
function srcFiles(dir, out = []) {
  for (const f of readdirSync(dir)) {
    const p = join(dir, f);
    if (statSync(p).isDirectory()) srcFiles(p, out);
    else if (f.endsWith('.js')) out.push(p);
  }
  return out;
}
const bindOf = (v) => (v && typeof v === 'object' && Number.isFinite(v.ago_h) ? isoAgo(v.ago_h) : v);

test('E1: the fixture holds exactly 20 distinct statements, each verbatim in src/', () => {
  const st = FIXTURE.statements;
  assert.ok(Array.isArray(st), 'statements is an array');
  assert.equal(st.length, 20, 'exactly 20 statements');
  assert.match(FIXTURE.source, /replace with the live top-20 after 24 h of d1_stmt_stats samples/);
  assert.equal(new Set(st.map((s) => s.id)).size, 20, 'ids are distinct');
  assert.equal(new Set(st.map((s) => normalizeSql(s.sql))).size, 20, 'normalized texts are distinct');
  const texts = srcFiles(SRC).map((f) => ws(readFileSync(f, 'utf8')));
  assert.ok(texts.length > 100, `read the worker sources (${texts.length} files)`);
  const missing = st.filter((s) => !texts.some((t) => t.indexOf(ws(s.sql)) !== -1)).map((s) => s.id);
  assert.deepEqual(missing, [], `fixture statements not found verbatim in src/: ${missing.join(', ')}`);
  for (const s of st) {
    assert.ok(Array.isArray(s.binds), `${s.id}: binds is an array`);
    assert.ok(s.hot_tables.length > 0 && s.hot_tables.every((t) => HOT_TABLES.includes(t)), `${s.id}: hot_tables`);
    const al = Object.values(aliasesOf(s.sql));
    assert.ok(s.hot_tables.every((t) => al.includes(t)), `${s.id}: the sql reads ${s.hot_tables.join(', ')}`);
  }
});

test('E2: the scan rule on literal plan lines', () => {
  const j = { j: 'jobs', jobs: 'jobs' };
  const cases = [
    ['SCAN jobs', {}, false],
    ['SCAN jobs USING COVERING INDEX idx_jobs_kind_spawn', {}, false],
    ['SEARCH jobs USING INDEX idx_x (a=?)', {}, true],
    ['SCAN wake_repo_last', {}, true],
    ['SCAN json_each VIRTUAL TABLE INDEX 1:', {}, true],
    ['CORRELATED SCALAR SUBQUERY 1', {}, false],
    ['SCAN j USING INDEX idx_jobs_created', { aliases: j }, false],
    ['SCAN j USING INDEX idx_jobs_created', { aliases: j, allow: ALLOW_6727 }, true],
    ['SCAN j USING INDEX idx_jobs_project_created', { aliases: j, allow: ALLOW_6727 }, false],
  ];
  for (const [line, opt, pass] of cases) {
    assert.equal(failingLines([line], opt).length === 0, pass, `${line} ${JSON.stringify(Object.keys(opt))}: expected ${pass ? 'pass' : 'fail'}`);
  }
  assert.deepEqual(aliasesOf('SELECT 1 FROM jobs j LEFT JOIN job_heartbeats h ON h.job_id=j.id WHERE 1'),
    { jobs: 'jobs', j: 'jobs', job_heartbeats: 'job_heartbeats', h: 'job_heartbeats' });
  assert.deepEqual(aliasesOf('SELECT * FROM ledgers WHERE kind=?1'), { ledgers: 'ledgers' });
});

test('E3: EXPLAIN QUERY PLAN of the 20 hot statements uses an index', async (t) => {
  const vol = await openVolumeDb();
  if (!vol) return t.skip('node:sqlite unavailable');
  // The indexes on added columns (core.d ADDED_INDEXES) exist in production
  // after the first request; create them the way the worker does.
  const env = { DB: d1(vol.db) };
  for (const table of HOT_TABLES) await ensureColumns(env, table);
  const failures = [];
  let checked = 0;
  for (const s of FIXTURE.statements) {
    let lines;
    try {
      lines = plan(vol.db, s.sql, ...s.binds.map(bindOf));
    } catch (e) {
      failures.push(`${s.id}: EXPLAIN failed: ${e.message}`);
      continue;
    }
    checked += 1;
    const bad = failingLines(lines, { aliases: aliasesOf(s.sql), allow: ALLOW });
    if (bad.length) failures.push(`${s.id} (${s.route}): ${bad.join('; ')}\n    plan: ${lines.join(' | ')}`);
  }
  assert.deepEqual(failures, [], `hot statements that scan:\n  ${failures.join('\n  ')}`);
  assert.equal(checked, 20);
  console.log(`hot-explain: ${checked} of ${FIXTURE.statements.length} use an index`);
});
