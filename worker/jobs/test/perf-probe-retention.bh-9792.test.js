// BH-9792: the results retention rule of the perf probe
// (src/routes/retention.d/bh-9786-perf-probe.js), driven through the REAL
// worker.fetch and POST /api/retention/run against the composed jobs schema.
//
//   R1  rows at day-120 and day-10: a dry run counts 1 and keeps both; a live
//       run deletes the day-120 row, keeps the day-10 row, and writes exactly
//       one retention_runs row for rule perf_probe_results.day with removed 1
//   W9  perf_probe.retention_days = 30 deletes a day-45 row; with the default
//       90 the same day-45 row stays
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret-fixture';
const RULE = 'perf_probe_results.day';
const post = (DB, path, body) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method: 'POST', headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' }, body: JSON.stringify(body),
}), { DB, HARNESS_SECRET: SECRET }).then(async (r) => ({ status: r.status, body: await r.json().catch(() => null) }));
// The retention route cuts at its own clock, so each seed day is relative to it.
const daysAgo = (n) => new Date(Date.now() - n * 86400e3).toISOString().slice(0, 10);  // determinism: ok anchored to the route's clock
const seed = async (DB, project, route, day) => {
  const r = await post(DB, '/api/perf-probe/results', {
    project, day, kind: 'daily', run_key: 'daily',
    rows: [{ route, ttfb_ms: 100, total_ms: 200, bytes: 10, status: 200, over_budget: 0, outcome: 'pass', loads: 1, breaks: 0 }],
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
};
const routesOf = (db, project) => db.prepare('SELECT route FROM perf_probe_results WHERE project=? ORDER BY route').all(project).map((r) => r.route);
const run = (DB) => post(DB, '/api/retention/run', {}).then((r) => r.body);

test('BH-9792 perf probe results retention', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('R1 day-120 is deleted, day-10 is kept, one retention_runs row', async () => {
    const { DB, db } = await openDb();
    await seed(DB, 'pp-r1', '/d120', daysAgo(120));
    await seed(DB, 'pp-r1', '/d10', daysAgo(10));
    const dry = await run(DB);
    assert.equal(dry.dry_run, true);
    assert.equal(dry.rules.find((r) => r.rule === RULE).counted, 1);
    assert.deepEqual(routesOf(db, 'pp-r1'), ['/d10', '/d120']);
    db.prepare("UPDATE settings SET value='0' WHERE key='retention.dry_run'").run();
    const live = await run(DB);
    assert.equal(live.dry_run, false);
    const rule = live.rules.find((r) => r.rule === RULE);
    assert.equal(rule.error, null);
    assert.equal(rule.removed, 1);
    assert.deepEqual(routesOf(db, 'pp-r1'), ['/d10']);
    // One audit row per run for the rule: the dry run's, then the live run's.
    const audit = db.prepare('SELECT tbl, dry_run, counted, removed FROM retention_runs WHERE rule=? ORDER BY id').all(RULE);
    assert.deepEqual(audit.map((a) => ({ ...a })), [
      { tbl: 'perf_probe_results', dry_run: 1, counted: 1, removed: 0 },
      { tbl: 'perf_probe_results', dry_run: 0, counted: 1, removed: 1 },
    ]);
  });

  await t.test('W9 perf_probe.retention_days decides the window', async () => {
    const { DB, db } = await openDb();
    db.prepare("UPDATE settings SET value='0' WHERE key='retention.dry_run'").run();
    await seed(DB, 'pp-w9', '/d45', daysAgo(45));
    await seed(DB, 'pp-w9', '/d5', daysAgo(5));
    // default 90: the day-45 row stays
    assert.equal((await run(DB)).rules.find((r) => r.rule === RULE).removed, 0);
    assert.deepEqual(routesOf(db, 'pp-w9'), ['/d45', '/d5']);
    // 30: the day-45 row is deleted, the day-5 row stays
    db.prepare("UPDATE settings SET value='30' WHERE key='perf_probe.retention_days'").run();
    const live = await run(DB);
    assert.equal(live.rules.find((r) => r.rule === RULE).removed, 1);
    assert.deepEqual(routesOf(db, 'pp-w9'), ['/d5']);
  });
});
