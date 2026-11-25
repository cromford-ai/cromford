// BH-9792: the perf_probe_warm table and GET/POST /api/perf-probe/warm (the
// deploy watermark of bin/perf-probe-warm.sh), driven through the REAL
// worker.fetch against the composed jobs schema (the node:sqlite D1 shim).
//
//   W5a  POST a new key: 200 {created:1}; the same key again: {created:0},
//        still 1 row, the first warmed_at kept
//   W5b  400 for each bad field; no bearer is 401; no row on a refusal; the
//        table CHECK refuses outcome other
//   W5c  GET answers the newest row by warmed_at of 3; another project:
//        {row:null}; a bad project: 400
//   W5d  POST /api/perf-probe/results takes outcome failed-then-recovered;
//        bogus is still 400 {error:"rows[0].outcome"}
//   W6w  EXPLAIN QUERY PLAN on 20,000 seeded rows: the GET uses
//        idx_perf_probe_warm_latest, the retention ids use idx_perf_probe_warm_at,
//        no full SCAN of perf_probe_warm
//   W7w  retention: a dry run counts the 120-day-old row and deletes nothing;
//        a live run deletes it and keeps the 10-day-old row
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret-fixture';
const PATH = '/api/perf-probe/warm';
const call = (DB, method, path, body, { bearer = true } = {}) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method,
  headers: { ...(bearer ? { authorization: `Bearer ${SECRET}` } : {}), 'content-type': 'application/json' },
  ...(body === undefined ? {} : { body: JSON.stringify(body) }),
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
const put = (DB, body, o) => call(DB, 'POST', PATH, body, o);
const get = (DB, project) => call(DB, 'GET', `${PATH}?project=${encodeURIComponent(project)}`);
const warm = (project, deployment_id, over = {}) => ({ project, deployment_id, outcome: 'warmed', routes: 3, over: 0, ...over });
const rowsOf = (db, project) => db.prepare('SELECT * FROM perf_probe_warm WHERE project=? ORDER BY warmed_at, deployment_id').all(project);

test('BH-9792 perf probe warm watermark', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W5a POST writes one row per key; a repeat is a no-op', async () => {
    const { DB, db } = await openDb();
    const r1 = await put(DB, warm('pp-w5a', 'd-42'));
    assert.equal(r1.status, 200, JSON.stringify(r1.body));
    assert.deepEqual(r1.body, { created: 1 });
    const first = rowsOf(db, 'pp-w5a');
    assert.equal(first.length, 1);
    assert.deepEqual([first[0].deployment_id, first[0].outcome, first[0].routes, first[0].over], ['d-42', 'warmed', 3, 0]);
    assert.match(first[0].warmed_at, /^\d{4}-\d{2}-\d{2}T/);
    db.prepare("UPDATE perf_probe_warm SET warmed_at='2026-01-01T00:00:00.000Z' WHERE project='pp-w5a'").run();
    const r2 = await put(DB, warm('pp-w5a', 'd-42', { outcome: 'deploy-failed', routes: 0 }));
    assert.equal(r2.status, 200, JSON.stringify(r2.body));
    assert.deepEqual(r2.body, { created: 0 });
    const again = rowsOf(db, 'pp-w5a');
    assert.equal(again.length, 1);
    assert.deepEqual([again[0].outcome, again[0].routes, again[0].warmed_at], ['warmed', 3, '2026-01-01T00:00:00.000Z']);
  });

  await t.test('W5b bad fields are 400, no bearer is 401, nothing written', async () => {
    const { DB, db } = await openDb();
    for (const [body, field] of [
      [warm('PP-Bad', 'd-1'), 'project'],
      [warm('-pp', 'd-1'), 'project'],
      [{ ...warm('pp-w5b', 'd-1'), project: undefined }, 'project'],
      [warm('pp-w5b', 'd 1'), 'deployment_id'],
      [warm('pp-w5b', ''), 'deployment_id'],
      [warm('pp-w5b', 'k'.repeat(81)), 'deployment_id'],
      [warm('pp-w5b', 42), 'deployment_id'],
      [warm('pp-w5b', 'd-1', { outcome: 'other' }), 'outcome'],
      [warm('pp-w5b', 'd-1', { routes: -1 }), 'routes'],
      [warm('pp-w5b', 'd-1', { routes: 1.5 }), 'routes'],
      [warm('pp-w5b', 'd-1', { over: '1' }), 'over'],
    ]) {
      const r = await put(DB, body);
      assert.equal(r.status, 400, `${field}: ${JSON.stringify(r.body)}`);
      assert.deepEqual(r.body, { error: field });
    }
    const nob = await put(DB, warm('pp-w5b', 'd-1'), { bearer: false });
    assert.equal(nob.status, 401);
    assert.equal(rowsOf(db, 'pp-w5b').length, 0);
    assert.throws(() => db.prepare("INSERT INTO perf_probe_warm (project, deployment_id, outcome, warmed_at) VALUES ('x','d','other','t')").run(), /CHECK/);
    // routes and over default to 0
    assert.deepEqual((await put(DB, { project: 'pp-w5b', deployment_id: 'd-2', outcome: 'deploy-failed' })).body, { created: 1 });
    assert.deepEqual(rowsOf(db, 'pp-w5b').map((x) => [x.routes, x.over]), [[0, 0]]);
  });

  await t.test('W5c GET answers the newest row of the project', async () => {
    const { DB, db } = await openDb();
    const ins = db.prepare('INSERT INTO perf_probe_warm (project, deployment_id, outcome, routes, over, warmed_at) VALUES (?,?,?,?,?,?)');
    ins.run('pp-w5c', 'd-1', 'warmed', 3, 0, '2026-11-18T06:00:00.000Z');
    ins.run('pp-w5c', 'd-3', 'deploy-failed', 0, 0, '2026-11-18T08:00:00.000Z');
    ins.run('pp-w5c', 'd-2', 'warmed', 3, 1, '2026-11-18T07:00:00.000Z');
    ins.run('pp-other', 'd-9', 'warmed', 1, 0, '2026-11-19T07:00:00.000Z');
    const r = await get(DB, 'pp-w5c');
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.deepEqual(r.body, { row: { project: 'pp-w5c', deployment_id: 'd-3', outcome: 'deploy-failed', routes: 0, over: 0, warmed_at: '2026-11-18T08:00:00.000Z' } });
    assert.deepEqual((await get(DB, 'pp-none')).body, { row: null });
    const b = await get(DB, 'PP Bad');
    assert.equal(b.status, 400);
    assert.deepEqual(b.body, { error: 'project' });
    assert.equal((await call(DB, 'GET', PATH)).status, 400);
    // the round trip: what POST wrote, GET reads back
    await put(DB, warm('pp-w5c2', 'd-77'));
    assert.equal((await get(DB, 'pp-w5c2')).body.row.deployment_id, 'd-77');
  });

  await t.test('W5d results take outcome failed-then-recovered', async () => {
    const { DB, db } = await openDb();
    const res = (outcome) => call(DB, 'POST', '/api/perf-probe/results', {
      project: 'pp-w5d', day: '2026-11-18', kind: 'post-deploy', run_key: 'd-42',
      rows: [{ route: '/b', ttfb_ms: 100, total_ms: 200, bytes: 10, status: 200, over_budget: 0, outcome, loads: 2, breaks: 1 }],
    });
    const ok = await res('failed-then-recovered');
    assert.equal(ok.status, 200, JSON.stringify(ok.body));
    assert.equal(db.prepare("SELECT outcome FROM perf_probe_results WHERE project='pp-w5d'").get().outcome, 'failed-then-recovered');
    const bad = await res('bogus');
    assert.equal(bad.status, 400);
    assert.deepEqual(bad.body, { error: 'rows[0].outcome' });
  });

  await t.test('W6w the hot reads use their indexes on 20,000 seeded rows', async () => {
    const { db } = await openDb();
    const ins = db.prepare("INSERT INTO perf_probe_warm (project, deployment_id, outcome, routes, over, warmed_at) VALUES (?,?,'warmed',10,0,?)");
    const base = Date.parse('2026-01-01T00:00:00Z');
    db.exec('BEGIN');
    for (let p = 0; p < 20; p++) {
      for (let d = 0; d < 1000; d++) ins.run(`proj-${p}`, `d-${p}-${d}`, new Date(base + d * 5400e3 + p * 1000).toISOString());
    }
    db.exec('COMMIT');
    db.exec('ANALYZE');
    assert.equal(db.prepare('SELECT count(*) AS n FROM perf_probe_warm').get().n, 20000);
    const plan = (sql, ...b) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...b).map((x) => x.detail);
    const uses = (lines, idx) => assert.ok(lines.some((l) => /^SEARCH perf_probe_warm USING/.test(l) && l.includes(idx)), `${idx} not used: ${lines.join(' | ')}`);
    const noScan = (lines) => assert.deepEqual(lines.filter((l) => /^SCAN perf_probe_warm\b/.test(l)), [], lines.join(' | '));
    const noTemp = (lines) => assert.deepEqual(lines.filter((l) => /TEMP B-TREE/.test(l)), [], lines.join(' | '));
    const { SQL } = await import('../src/routes/perf-probe-warm.js');
    let l = plan(SQL.latest, 'proj-3'); uses(l, 'idx_perf_probe_warm_latest'); noScan(l); noTemp(l);
    noScan(plan(SQL.insert, 'proj-3', 'd-new', 'warmed', 1, 0, '2026-11-18T06:17:00Z'));
    const { default: RULES } = await import('../src/routes/retention.d/bh-9792-perf-probe-warm.js');
    assert.equal(RULES.length, 1);
    l = plan(RULES[0].ids, '2026-02-01T00:00:00Z', 500); uses(l, 'idx_perf_probe_warm_at'); noScan(l);
    noScan(plan(RULES[0].del, '[1]'));
    console.log(`W6w plans: ${JSON.stringify({ latest: plan(SQL.latest, 'proj-3'), retention: plan(RULES[0].ids, '2026-02-01T00:00:00Z', 500), del: plan(RULES[0].del, '[1]') })}`);
  });

  await t.test('W7w retention deletes a warm row past the window and keeps a recent one', async () => {
    const { DB, db } = await openDb();
    const ins = db.prepare("INSERT INTO perf_probe_warm (project, deployment_id, outcome, routes, over, warmed_at) VALUES ('pp-w7w',?,'warmed',3,0,?)");
    ins.run('d-old', new Date(Date.now() - 120 * 86400e3).toISOString());  // determinism: ok the retention route cuts at its own clock, so the seed is relative to it
    ins.run('d-new', new Date(Date.now() - 10 * 86400e3).toISOString());  // determinism: ok same anchor as above
    const run = () => call(DB, 'POST', '/api/retention/run', {}).then((r) => r.body);
    const dry = await run();
    assert.equal(dry.dry_run, true);
    const dr = dry.rules.find((r) => r.rule === 'perf_probe_warm.warmed_at');
    assert.ok(dr, JSON.stringify(dry.rules.map((r) => r.rule)));
    assert.equal(dr.counted, 1);
    assert.equal(rowsOf(db, 'pp-w7w').length, 2);
    db.prepare("UPDATE settings SET value='0' WHERE key='retention.dry_run'").run();
    const live = await run();
    const rule = live.rules.find((r) => r.rule === 'perf_probe_warm.warmed_at');
    assert.equal(rule.error, null);
    assert.equal(rule.removed, 1);
    assert.deepEqual(rowsOf(db, 'pp-w7w').map((r) => r.deployment_id), ['d-new']);
  });
});
