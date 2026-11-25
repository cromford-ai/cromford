// BH-9583 (BH-9559 part D, item 10): GET /api/gate-red/top ranks the suites
// named in GATE_RED build results, driven through the REAL worker.fetch over
// the composed jobs schema (the node:sqlite D1 shim).
//
//   R1  400 on a missing or bad repo, n=0, n=abc, days=-1; an unknown repo is
//       200 with suites []
//   R2  3/2/1 GATE_RED rows rank fixround-closure-lint, b, c; n=2 keeps two;
//       a count tie orders by last_at desc, then suite asc
//   R3  gateRedSuites on the live line shapes P1-P4 and N1, N2, N8, N9
//   R4  EXPLAIN QUERY PLAN of GATE_RED_RANK_SQL on 5,000 rows names
//       idx_jobs_project_status_created and no line is a bare SCAN jobs
//   R5  N3-N7 rows change no count; another project's rows give 0 (wrong tenant)
//   R6  the R2 answer's suites deep-equal fixtures/gate-red-top.bh-9559.json,
//       the file the shell gate test's fake client prints
//   R7  without n and days the route reads the settings rows, and the fallbacks
//       5 and 14 when the rows are absent; K1 the knob fragment seeds 1/5/14
//       and creates no table
// The clock is pinned with t.mock.timers. Each case seeds its own project with
// a unique suffix, so no two cases share a row.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret-fixture';
const NOW = Date.parse('2026-11-13T08:00:00Z');
const DAYS = 86400e3;
const isoSec = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const FIXTURE = JSON.parse(readFileSync(new URL('./fixtures/gate-red-top.bh-9559.json', import.meta.url), 'utf8'));
let seq = 0;
const uid = () => `${process.pid}-${++seq}`;

const get = (DB, qs) => worker.fetch(new Request(`https://jobs.test/api/gate-red/top?${qs}`, {
  headers: { authorization: `Bearer ${SECRET}` },
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

function project(db, p, repo) {
  db.prepare(`INSERT INTO projects (project, repo, cron_offset, created_at, updated_at) VALUES (?, ?, 0, ?, ?)`)
    .run(p, repo, isoSec(NOW), isoSec(NOW));
}
function job(db, { id, p, status = 'failed', meta, ageMs }) {
  const at = isoSec(NOW - ageMs);
  db.prepare(`INSERT INTO jobs (id, project, kind, box, stage, status, created_at, updated_at, meta)
              VALUES (?, ?, 'build', 'box-fixture', 'review', ?, ?, ?, ?)`).run(id, p, status, at, at, meta);
}
const red = (...suites) => `GATE_RED ${suites.length} red: ${suites.join(',')}; see /root/harness/builds/x/gate.txt`;
const FIX = 'tests/fixround-closure-lint.bh-5064-test.sh';

// R2's rows: 3 x FIX, 2 x b, 1 x c, at distinct ages so last_at is stable.
function seedR2(db, p) {
  const H = 3600e3;
  job(db, { id: `${p}-1`, p, meta: red(FIX, 'tests/b-test.sh'), ageMs: 1 * H });
  job(db, { id: `${p}-2`, p, meta: red(FIX, 'tests/c-test.sh'), ageMs: 2 * H });
  job(db, { id: `${p}-3`, p, meta: red(FIX), ageMs: 3 * H });
  job(db, { id: `${p}-4`, p, meta: red('tests/b-test.sh'), ageMs: 4 * H });
}

test('BH-9583 GATE_RED ranking route', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  t.mock.timers.enable({ apis: ['Date'], now: NOW });
  const mod = await import('../src/routes/gate-red-rank.js');

  await t.test('R1 bad input is 400; an unknown repo is 200 with no suites', async () => {
    const { DB } = await openDb();
    for (const qs of ['', 'repo=', 'repo=a%20b', 'repo=x&n=0', 'repo=x&n=abc', 'repo=x&days=-1', 'repo=x&days=0', 'repo=x&n=1.5']) {
      const r = await get(DB, qs);
      assert.equal(r.status, 400, `${qs}: ${JSON.stringify(r.body)}`);
    }
    const r = await get(DB, `repo=o/none-${uid()}&n=5&days=14`);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.deepEqual(r.body.suites, []);
  });

  await t.test('R2 + R6 the ranking orders by count, then last_at, then suite', async () => {
    const { DB, db } = await openDb();
    const p = `p-${uid()}`; const repo = `o/${p}-fixture`;
    project(db, p, repo);
    seedR2(db, p);
    const r = await get(DB, `repo=${encodeURIComponent(repo)}&n=2&days=14`);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.deepEqual(r.body.suites.map((s) => [s.suite, s.count]), [[FIX, 3], ['tests/b-test.sh', 2]]);
    assert.equal(r.body.n, 2); assert.equal(r.body.days, 14);
    assert.equal(r.body.since, isoSec(NOW - 14 * DAYS));
    assert.equal(r.body.rows_read, 4);
    // R6: the shape the shell gate test's fake client prints.
    assert.deepEqual(r.body.suites, FIXTURE.suites);
    // The project slug answers too.
    const bySlug = await get(DB, `repo=${p}&n=2&days=14`);
    assert.deepEqual(bySlug.body.suites, r.body.suites);
    // A count tie: d and e once each; e newer, so e then d; f ties e on last_at, so suite asc.
    const q = `q-${uid()}`;
    project(db, q, `o/${q}`);
    job(db, { id: `${q}-1`, p: q, meta: red('tests/d-test.sh'), ageMs: 5 * DAYS });
    job(db, { id: `${q}-2`, p: q, meta: red('tests/f-test.sh', 'tests/e-test.sh'), ageMs: DAYS });
    const tie = await get(DB, `repo=o/${q}&n=5&days=14`);
    assert.deepEqual(tie.body.suites.map((s) => s.suite), ['tests/e-test.sh', 'tests/f-test.sh', 'tests/d-test.sh']);
  });

  await t.test('R3 the GATE_RED meta parser', () => {
    const { gateRedSuites } = mod;
    // P1: the live line (bin/lib/selection-gate.sh).
    assert.deepEqual(gateRedSuites('GATE_RED 2 red: tests/a-test.sh,tests/b.bh-1-test.sh; see /root/harness/builds/x/gate.txt'),
      ['tests/a-test.sh', 'tests/b.bh-1-test.sh']);
    // P2: a trailing builder-direct note after the path.
    assert.deepEqual(gateRedSuites('GATE_RED 1 red: tests/a-test.sh; see /b/gate.txt (builder-direct: pushed nothing, note x, y)'),
      ['tests/a-test.sh']);
    // P3: the 300-char fold cut the line: no `; see `, so the last item is
    // dropped, even when what is left of it reads as a whole name (the cut can
    // land inside tests/c-test.sh.bh-1-test.sh, or just before its `; see`).
    assert.deepEqual(gateRedSuites('GATE_RED 3 red: tests/a-test.sh, tests/b-test.sh,tests/fixround-clos'),
      ['tests/a-test.sh', 'tests/b-test.sh']);
    assert.deepEqual(gateRedSuites('GATE_RED 3 red: tests/a-test.sh,tests/b-test.sh,tests/c-test.sh'),
      ['tests/a-test.sh', 'tests/b-test.sh']);
    // P4: an mc/ suite is kept.
    assert.deepEqual(gateRedSuites('GATE_RED 1 red: tests/mc/c-test.sh; see /x/gate.txt'), ['tests/mc/c-test.sh']);
    // N1, N2: other GATE_RED kinds (bin/lib/rebase-job.sh).
    assert.deepEqual(gateRedSuites('GATE_RED migration-number: 0042 is taken'), []);
    assert.deepEqual(gateRedSuites('GATE_RED typecheck: error TS2304 in x.ts'), []);
    // N3: not a prefix. N7: builder-direct JSON meta.
    assert.deepEqual(gateRedSuites('PR_CREATED https://github.com/o/r/pull/1 GATE_RED 1 red: tests/a-test.sh; see x'), []);
    assert.deepEqual(gateRedSuites('{"pr_url":"https://github.com/o/r/pull/1"}'), []);
    assert.deepEqual(gateRedSuites(null), []);
    // N8: not a tests/[mc/]*.sh path.
    assert.deepEqual(gateRedSuites('GATE_RED 4 red: bin/x.sh,tests/../x.sh,tests/a.py,tests/ok-test.sh; see x'), ['tests/ok-test.sh']);
    // N9: one row names a suite twice: counted once.
    assert.deepEqual(gateRedSuites('GATE_RED 2 red: tests/a-test.sh,tests/a-test.sh; see x'), ['tests/a-test.sh']);
  });

  await t.test('R4 EXPLAIN QUERY PLAN on 5,000 seeded rows uses the jobs index', async () => {
    const { db } = await openDb();
    const ps = [`e1-${uid()}`, `e2-${uid()}`, `e3-${uid()}`];
    ps.forEach((p) => project(db, p, `o/${p}`));
    const ins = db.prepare(`INSERT INTO jobs (id, project, kind, box, stage, status, created_at, updated_at, meta)
                            VALUES (?, ?, 'build', 'b', 'review', ?, ?, ?, ?)`);
    db.exec('BEGIN');
    for (let i = 0; i < 5000; i++) {
      const at = isoSec(NOW - (i % 60) * DAYS);
      ins.run(`${ps[i % 3]}-${i}`, ps[i % 3], i % 7 === 0 ? 'failed' : 'done', at, at, i % 7 === 0 ? red('tests/a-test.sh') : 'PR_CREATED x');
    }
    db.exec('COMMIT');
    db.exec('ANALYZE');
    const lines = db.prepare(`EXPLAIN QUERY PLAN ${mod.GATE_RED_RANK_SQL}`).all(`o/${ps[0]}`, isoSec(NOW - 14 * DAYS)).map((x) => x.detail);
    assert.ok(lines.some((l) => l.includes('idx_jobs_project_status_created')), lines.join(' | '));
    assert.deepEqual(lines.filter((l) => /^SCAN jobs\b/.test(l) && !/USING/.test(l)), [], lines.join(' | '));
    assert.ok(!lines.some((l) => /CORRELATED/.test(l)), lines.join(' | '));
  });

  await t.test('R5 non-GATE_RED rows, old rows and another project change nothing', async () => {
    const { DB, db } = await openDb();
    const p = `p-${uid()}`; const repo = `o/${p}-fixture`;
    const other = `x-${uid()}`;
    project(db, p, repo); project(db, other, `o/${other}`);
    seedR2(db, p);
    job(db, { id: `${p}-n3`, p, meta: `PR_CREATED https://x/pull/1 ${red(FIX)}`, ageMs: DAYS });
    job(db, { id: `${p}-n4`, p, status: 'done', meta: red(FIX), ageMs: DAYS });
    job(db, { id: `${p}-n5`, p, meta: red(FIX), ageMs: 15 * DAYS });
    job(db, { id: `${p}-n7`, p, meta: '{"pr_url":"https://x/pull/2"}', ageMs: DAYS });
    job(db, { id: `${p}-n1`, p, meta: 'GATE_RED migration-number: 0042 taken', ageMs: DAYS });
    for (let i = 0; i < 4; i++) job(db, { id: `${other}-${i}`, p: other, meta: red(FIX, 'tests/z-test.sh'), ageMs: DAYS });
    const r = await get(DB, `repo=${encodeURIComponent(repo)}&n=5&days=14`);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.deepEqual(r.body.suites.map((s) => [s.suite, s.count]), [[FIX, 3], ['tests/b-test.sh', 2], ['tests/c-test.sh', 1]]);
    // Wrong tenant: the other project's repo sees only its own rows; a repo with no project sees none.
    const o = await get(DB, `repo=o/${other}&n=5&days=14`);
    assert.deepEqual(o.body.suites.map((s) => [s.suite, s.count]), [[FIX, 4], ['tests/z-test.sh', 4]]);
    const none = await get(DB, `repo=o/nobody-${uid()}&n=5&days=14`);
    assert.equal(none.body.rows_read, 0);
    assert.deepEqual(none.body.suites, []);
  });

  await t.test('R7 + K1 the knobs: rows, fallbacks and the seed fragment', async () => {
    const { DB, db } = await openDb();
    const p = `p-${uid()}`; const repo = `o/${p}`;
    project(db, p, repo);
    seedR2(db, p);
    job(db, { id: `${p}-old`, p, meta: red('tests/old-test.sh'), ageMs: 20 * DAYS });
    // K1: the composed schema seeded the three rows.
    const val = (k) => (db.prepare('SELECT value FROM settings WHERE key=?').get(k) || {}).value;
    assert.equal(val('builder_gate.topred.enabled'), '1');
    assert.equal(val('builder_gate.topred_n'), '5');
    assert.equal(val('builder_gate.topred_window_days'), '14');
    let r = await get(DB, `repo=${repo}`);
    assert.equal(r.body.n, 5); assert.equal(r.body.days, 14);
    assert.equal(r.body.suites.length, 3);
    // The rows change the answer: n=1, days=30 takes in the old row and keeps one suite.
    db.prepare("UPDATE settings SET value='1' WHERE key='builder_gate.topred_n'").run();
    db.prepare("UPDATE settings SET value='30' WHERE key='builder_gate.topred_window_days'").run();
    r = await get(DB, `repo=${repo}`);
    assert.equal(r.body.n, 1); assert.equal(r.body.days, 30); assert.equal(r.body.rows_read, 5);
    assert.deepEqual(r.body.suites.map((s) => s.suite), [FIX]);
    // No rows: the fallbacks 5 and 14.
    db.prepare("DELETE FROM settings WHERE key IN ('builder_gate.topred_n','builder_gate.topred_window_days')").run();
    r = await get(DB, `repo=${repo}`);
    assert.equal(r.body.n, 5); assert.equal(r.body.days, 14); assert.equal(r.body.rows_read, 4);
    // K1: the fragment creates no table.
    const dir = new URL('../schema.d/', import.meta.url);
    const frag = readdirSync(dir).filter((f) => /-bh-9583-builder-topred-knobs\.sql$/.test(f));
    assert.equal(frag.length, 1, `one knob fragment: ${frag}`);
    assert.doesNotMatch(readFileSync(new URL(frag[0], dir), 'utf8'), /CREATE\s+TABLE/i);
  });
});
