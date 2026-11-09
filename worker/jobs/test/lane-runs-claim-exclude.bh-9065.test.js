// BH-9065: POST /api/lane-runs/claim takes an optional `exclude_lanes` array.
// A shared fleet machine sends the lanes whose catalog/lanes.d file declares
// `machine`, so the claim leaves their rows `queued` with attempts unchanged
// for the lane machine bin/lane-fleet.sh starts. Driven through the REAL
// router (worker.fetch) over the composed jobs schema on the node:sqlite shim.
// The shell side is tests/lane-run-lanes-claim.bh-9065-test.sh.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { CLAIM_SQL } from '../src/routes/lane-runs.js';

const SECRET = 'fixture-harness-secret';

const call = (DB, method, path, body) => {
  const headers = { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` };
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const enqueue = (DB, lane, project) => call(DB, 'POST', '/api/lane-runs', { lane, project, args: ['bin/x.sh'] });
const claim = (DB, extra = {}) => call(DB, 'POST', '/api/lane-runs/claim', { machine: 'm1', ...extra });
const row = (db, id) => db.prepare('SELECT * FROM lane_runs WHERE id = ?').get(id);
const at = (db, id, ts) => db.prepare('UPDATE lane_runs SET enqueued_at=? WHERE id=?').run(ts, id);
// A fixed anchor: the excluded row is the older one, so a claim with no
// filter would take it first.
const OLD = '2026-01-01T00:00:00Z';

test('BH-9065 claim exclude_lanes', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('E1 BH-9065 exclude_lanes: an excluded lane stays queued with attempts 0, another lane is claimed', async () => {
    const { db, DB } = await openDb();
    const hv = await enqueue(DB, 'cpu-heavy', 'px');
    const lt = await enqueue(DB, 'cpu-light', 'px');
    at(db, hv.body.id, OLD);
    const c = await claim(DB, { exclude_lanes: ['cpu-heavy'] });
    assert.equal(c.status, 200);
    assert.equal(c.body.id, lt.body.id, 'the newer, not excluded row is claimed');
    assert.equal(row(db, hv.body.id).status, 'queued');
    assert.equal(row(db, hv.body.id).attempts, 0);
    assert.equal((await claim(DB, { exclude_lanes: ['cpu-heavy'] })).status, 204, 'only the excluded row is left');
    const l = await claim(DB, { machine: 'lm1', lanes: ['cpu-heavy'] });
    assert.equal(l.body.id, hv.body.id, 'a lane machine claims it');
    const e = await claim(DB, { exclude_lanes: [] });
    assert.equal(e.status, 204, 'an empty list is no filter (the queue is empty)');
  });

  await t.test('E2 BH-9065 a bad exclude_lanes answers 400', async () => {
    const { DB } = await openDb();
    for (const v of ['cpu-heavy', ['bad/name'], [1], Array.from({ length: 33 }, (_, i) => `l${i}`)]) {
      const c = await claim(DB, { exclude_lanes: v });
      assert.equal(c.status, 400, `exclude_lanes ${JSON.stringify(v).slice(0, 40)}`);
      assert.match(c.body.error, /exclude_lanes/);
    }
  });

  await t.test('E3 BH-9065 EXPLAIN QUERY PLAN on 20 000 rows: exclude_lanes keeps the claim index, no SCAN lane_runs', async () => {
    const { db } = await openDb();
    const ins = db.prepare(`INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status, attempts, rc, finished_at)
                            VALUES (?,?,?,?,?,?,?,?)`);
    db.exec('BEGIN');
    for (let i = 0; i < 20000; i++) {
      const ts = new Date(Date.UTC(2026, 9, 1) + i * 60e3).toISOString().replace(/\.\d{3}Z$/, 'Z');
      const queued = i >= 19800;
      ins.run(i % 2 ? 'cpu-heavy' : 'cpu-light', `p${i % 13}.${i}`, '["bin/x.sh"]', ts,
        queued ? 'queued' : 'done', queued ? 0 : 1, queued ? null : 0, queued ? null : ts);
    }
    db.exec('COMMIT');
    const b = (x) => ['m1', '2026-10-15T00:00:00Z', '2026-10-15T00:02:00Z', null, null, null, null, null, null, null,
      null, null, null, null, null, x];
    const plan = (x) => db.prepare(`EXPLAIN QUERY PLAN ${CLAIM_SQL}`).all(...b(x)).map((r) => r.detail);
    const withX = plan('["cpu-heavy"]');
    const lr = (lines) => lines.filter((l) => /\blane_runs\b/.test(l));
    assert.deepEqual(lr(withX), lr(plan(null)), 'the same lane_runs access path with and without exclude_lanes');
    assert.ok(!withX.some((l) => /^SCAN lane_runs\b(?!.*USING)/.test(l)), `no full SCAN lane_runs: ${withX.join(' | ')}`);
    const r = db.prepare(CLAIM_SQL).get(...b('["cpu-heavy"]'));
    assert.equal(r.lane, 'cpu-light');
  });
});
