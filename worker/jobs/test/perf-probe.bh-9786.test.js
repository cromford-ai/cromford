// BH-9786: the perf_probe_results table and POST /api/perf-probe/results,
// driven through the REAL worker.fetch against the composed jobs schema (the
// node:sqlite D1 shim).
//
//   W1  a POST of 2 rows is 200 {written:2}; a second POST of the same key
//       with a new ttfb_ms updates it (still 2 rows); each JSON field lands in
//       its column
//   W2  the same route and day under kind daily and post-deploy is 2 rows;
//       kind other is 400 {error:"kind"}; the table CHECK refuses it too
//   W3  400 for each bad field, the row cap from perf_probe.rows_max (row = 2:
//       3 rows 400; no row: 501 rows 400, 500 rows 200); no bearer is 401;
//       no row written on a refusal
//   W6  EXPLAIN QUERY PLAN on 100,000 seeded rows: the hot reads use their
//       indexes, no full SCAN of perf_probe_results
//   W7  retention: dry run deletes nothing; a live run deletes a row past
//       perf_probe.retention_days and keeps a recent one
//   W8  the seed rows perf_probe.retention_days = '90' and
//       perf_probe.rows_max = '500'
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret-fixture';
const PATH = '/api/perf-probe/results';
const req = (DB, body, { bearer = true } = {}) => worker.fetch(new Request(`https://jobs.test${PATH}`, {
  method: 'POST',
  headers: { ...(bearer ? { authorization: `Bearer ${SECRET}` } : {}), 'content-type': 'application/json' },
  body: JSON.stringify(body),
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
const row = (route, over = {}) => ({
  route, ttfb_ms: 120, total_ms: 340, bytes: 2048, status: 200, over_budget: 0, outcome: 'pass', loads: 1, breaks: 0, ...over,
});
const payload = (project, rows, over = {}) => ({ project, day: '2026-11-18', kind: 'daily', run_key: 'daily', rows, ...over });
const rowsOf = (db, project) => db.prepare('SELECT * FROM perf_probe_results WHERE project=? ORDER BY route, kind').all(project);

test('BH-9786 perf probe results', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W1 POST writes rows; a rerun of the same key updates them', async () => {
    const { DB, db } = await openDb();
    const r1 = await req(DB, payload('pp-w1', [row('/'), row('/reports', { ttfb_ms: 1500, total_ms: 1600, over_budget: 1, outcome: 'fail', breaks: 1 })]));
    assert.equal(r1.status, 200, JSON.stringify(r1.body));
    assert.deepEqual(r1.body, { written: 2 });
    let rows = rowsOf(db, 'pp-w1');
    assert.equal(rows.length, 2);
    const rep = rows.find((x) => x.route === '/reports');
    assert.deepEqual([rep.project, rep.day, rep.kind, rep.run_key, rep.ttfb_ms, rep.total_ms, rep.bytes, rep.status, rep.over_budget, rep.outcome, rep.loads, rep.breaks],
      ['pp-w1', '2026-11-18', 'daily', 'daily', 1500, 1600, 2048, 200, 1, 'fail', 1, 1]);
    assert.match(rep.created_at, /^\d{4}-\d{2}-\d{2}T/);
    const r2 = await req(DB, payload('pp-w1', [row('/', { ttfb_ms: 77 })]));
    assert.equal(r2.status, 200, JSON.stringify(r2.body));
    rows = rowsOf(db, 'pp-w1');
    assert.equal(rows.length, 2);
    assert.equal(rows.find((x) => x.route === '/').ttfb_ms, 77);
    assert.equal(rows.find((x) => x.route === '/reports').ttfb_ms, 1500);
    // null metrics are stored as NULL (an unmeasured route)
    const r3 = await req(DB, payload('pp-w1', [row('/null', { ttfb_ms: null, total_ms: null, bytes: null, status: 0, outcome: 'unmeasured' })]));
    assert.equal(r3.status, 200, JSON.stringify(r3.body));
    const n = rowsOf(db, 'pp-w1').find((x) => x.route === '/null');
    assert.deepEqual([n.ttfb_ms, n.total_ms, n.bytes, n.status, n.outcome], [null, null, null, 0, 'unmeasured']);
  });

  await t.test('W2 kind daily and post-deploy are 2 rows; another kind is refused', async () => {
    const { DB, db } = await openDb();
    assert.equal((await req(DB, payload('pp-w2', [row('/')]))).status, 200);
    assert.equal((await req(DB, payload('pp-w2', [row('/')], { kind: 'post-deploy', run_key: 'sha-abc' }))).status, 200);
    assert.deepEqual(rowsOf(db, 'pp-w2').map((x) => x.kind), ['daily', 'post-deploy']);
    const r = await req(DB, payload('pp-w2', [row('/')], { kind: 'other' }));
    assert.equal(r.status, 400);
    assert.deepEqual(r.body, { error: 'kind' });
    assert.throws(() => db.prepare("INSERT INTO perf_probe_results (project, route, day, kind, run_key, created_at) VALUES ('x','/','2026-11-18','other','k','t')").run(), /CHECK/);
    assert.equal(rowsOf(db, 'pp-w2').length, 2);
  });

  await t.test('W3 bad fields are 400, the row cap holds, no bearer is 401', async () => {
    const { DB, db } = await openDb();
    for (const [body, field] of [
      [payload('PP-Bad', [row('/')]), 'project'],
      [payload('-pp', [row('/')]), 'project'],
      [payload('pp-w3', [row('/')], { day: '2026-11-1' }), 'day'],
      [payload('pp-w3', [row('/')], { day: 20261118 }), 'day'],
      [payload('pp-w3', [row('/')], { kind: undefined }), 'kind'],
      [payload('pp-w3', [row('/')], { run_key: 'a b' }), 'run_key'],
      [payload('pp-w3', [row('/')], { run_key: 'k'.repeat(81) }), 'run_key'],
      [payload('pp-w3', []), 'rows'],
      [payload('pp-w3', 'nope'), 'rows'],
      [payload('pp-w3', [row('reports')]), 'rows[0].route'],
      [payload('pp-w3', [row(`/${'a'.repeat(500)}`)]), 'rows[0].route'],
      [payload('pp-w3', [row('/'), row('/x', { ttfb_ms: -1 })]), 'rows[1].ttfb_ms'],
      [payload('pp-w3', [row('/', { bytes: 1.5 })]), 'rows[0].bytes'],
      [payload('pp-w3', [row('/', { status: 1000 })]), 'rows[0].status'],
      [payload('pp-w3', [row('/', { loads: '1' })]), 'rows[0].loads'],
      [payload('pp-w3', [row('/', { over_budget: 2 })]), 'rows[0].over_budget'],
      [payload('pp-w3', [row('/', { over_budget: true })]), 'rows[0].over_budget'],
      [payload('pp-w3', [row('/', { outcome: 'ok' })]), 'rows[0].outcome'],
    ]) {
      const r = await req(DB, body);
      assert.equal(r.status, 400, `${field}: ${JSON.stringify(r.body)}`);
      assert.deepEqual(r.body, { error: field });
    }
    assert.equal(rowsOf(db, 'pp-w3').length, 0);
    const nob = await req(DB, payload('pp-w3', [row('/')]), { bearer: false });
    assert.equal(nob.status, 401);
    assert.equal(rowsOf(db, 'pp-w3').length, 0);
    // no settings row: the fallback 500 holds (501 refused, 500 written)
    db.prepare("DELETE FROM settings WHERE key='perf_probe.rows_max'").run();
    const many = (n) => Array.from({ length: n }, (_, i) => row(`/r${i}`));
    let r = await req(DB, payload('pp-w3d', many(501)));
    assert.equal(r.status, 400, JSON.stringify(r.body));
    assert.deepEqual(r.body, { error: 'rows' });
    r = await req(DB, payload('pp-w3d', many(500)));
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(rowsOf(db, 'pp-w3d').length, 500);
    // the row read: rows_max = 2 refuses 3 rows
    const { DB: DB2, db: db2 } = await openDb();
    db2.prepare("UPDATE settings SET value='2' WHERE key='perf_probe.rows_max'").run();
    r = await req(DB2, payload('pp-w3c', many(3)));
    assert.equal(r.status, 400, JSON.stringify(r.body));
    assert.deepEqual(r.body, { error: 'rows' });
    assert.equal((await req(DB2, payload('pp-w3c', many(2)))).status, 200);
    assert.equal(rowsOf(db2, 'pp-w3c').length, 2);
  });

  await t.test('W6 the hot reads use their indexes on 100,000 seeded rows', async () => {
    const { db } = await openDb();
    const ins = db.prepare(`INSERT INTO perf_probe_results (project, route, day, kind, run_key, ttfb_ms, total_ms, bytes, status, over_budget, outcome, loads, breaks, created_at)
      VALUES (?,?,?,?,?,100,200,300,200,0,'pass',1,0,'2026-11-18T06:17:00Z')`);
    const base = Date.parse('2026-01-01T00:00:00Z');
    db.exec('BEGIN');
    for (let i = 0; i < 100000; i++) {
      // 200 rows a day: 5 projects x 40 routes; every 4th day is post-deploy rows.
      const d = Math.floor(i / 200);
      const j = i % 200;
      const day = new Date(base + d * 86400e3).toISOString().slice(0, 10);
      const kind = d % 4 === 3 ? 'post-deploy' : 'daily';
      ins.run(`proj-${j % 5}`, `/r${Math.floor(j / 5)}`, day, kind, kind === 'daily' ? 'daily' : `sha-${d}`);
    }
    db.exec('COMMIT');
    db.exec('ANALYZE');
    assert.equal(db.prepare('SELECT count(*) AS n FROM perf_probe_results').get().n, 100000);
    const plan = (sql, ...b) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((x) => x.detail);
    const uses = (lines, idx) => assert.ok(lines.some((l) => /^SEARCH perf_probe_results USING/.test(l) && l.includes(idx)), `${idx} not used: ${lines.join(' | ')}`);
    const noScan = (lines) => assert.deepEqual(lines.filter((l) => /^SCAN perf_probe_results\b/.test(l)), [], lines.join(' | '));
    let l = plan('SELECT * FROM perf_probe_results WHERE project=? AND route=? AND day=?', 'proj-1', '/r1', '2026-03-01');
    uses(l, 'uq_perf_probe_results'); noScan(l);
    l = plan('SELECT * FROM perf_probe_results WHERE project=? AND day=? AND kind=? ORDER BY route', 'proj-1', '2026-03-01', 'daily');
    uses(l, 'idx_perf_probe_results_pday'); noScan(l);
    const { SQL } = await import('../src/routes/perf-probe.js');
    noScan(plan(SQL.upsert, 'p', '/', '2026-11-18', 'daily', 'daily', 1, 2, 3, 200, 0, 'pass', 1, 0, 't'));
    const { default: RULES } = await import('../src/routes/retention.d/bh-9786-perf-probe.js');
    for (const r of RULES) {
      l = plan(r.ids, '2026-02-01T00:00:00Z', 500); uses(l, 'idx_perf_probe_results_day'); noScan(l);
      noScan(plan(r.del, '[1]'));
    }
    // The plan lines, recorded in the schema fragment header.
    console.log(`W6 plans: ${JSON.stringify({
      route: plan('SELECT * FROM perf_probe_results WHERE project=? AND route=? AND day=?', 'proj-1', '/r1', '2026-03-01'),
      pday: plan('SELECT * FROM perf_probe_results WHERE project=? AND day=? AND kind=? ORDER BY route', 'proj-1', '2026-03-01', 'daily'),
      retention: plan(RULES[0].ids, '2026-02-01T00:00:00Z', 500),
    })}`);
  });

  await t.test('W7 retention deletes a row past the window and keeps a recent one', async () => {
    const { DB, db } = await openDb();
    const dayOf = (ms) => new Date(ms).toISOString().slice(0, 10);
    const old = dayOf(Date.now() - 95 * 86400e3);  // determinism: ok the retention route cuts at its own clock, so the seed is relative to it
    const fresh = dayOf(Date.now() - 2 * 86400e3);  // determinism: ok same anchor as above
    assert.equal((await req(DB, payload('pp-w7', [row('/old')], { day: old }))).status, 200);
    assert.equal((await req(DB, payload('pp-w7', [row('/fresh')], { day: fresh }))).status, 200);
    const run = () => worker.fetch(new Request('https://jobs.test/api/retention/run', {
      method: 'POST', headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' }, body: '{}',
    }), { DB, HARNESS_SECRET: SECRET }).then((r) => r.json());
    const dry = await run();
    assert.equal(dry.dry_run, true);
    assert.equal(dry.rules.find((r) => r.rule === 'perf_probe_results.day').counted, 1);
    assert.equal(rowsOf(db, 'pp-w7').length, 2);
    db.prepare("UPDATE settings SET value='0' WHERE key='retention.dry_run'").run();
    const live = await run();
    const rule = live.rules.find((r) => r.rule === 'perf_probe_results.day');
    assert.equal(rule.error, null);
    assert.equal(rule.removed, 1);
    assert.deepEqual(rowsOf(db, 'pp-w7').map((r) => r.route), ['/fresh']);
  });

  await t.test('W8 the seed rows', async () => {
    const { db } = await openDb();
    assert.equal(db.prepare("SELECT value FROM settings WHERE key='perf_probe.retention_days'").get().value, '90');
    assert.equal(db.prepare("SELECT value FROM settings WHERE key='perf_probe.rows_max'").get().value, '500');
  });
});
