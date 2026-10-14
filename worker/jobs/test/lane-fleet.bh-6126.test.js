// BH-6126 (BH-6047 part 3 of 5): the lane-run Fly fleet routes — the
// lane_machines record keyed on the Fly machine id and the per-machine-minute
// cost write. Driven through the REAL router (worker.fetch) over a real
// jobs schema database (jobsSchemaSql(), the composition of schema.d/) on the
// node:sqlite shim, with the worker clock pinned.
// The shell side is tests/lane-fleet.bh-6126-test.sh.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'fixture-harness-secret';
const SCHEMA = jobsSchemaSql();

// The worker reads its clock through `new Date()`; pin it.
const RealDate = Date;
let clockMs = RealDate.parse('2099-10-03T04:00:00Z');
class FixtureDate extends RealDate {
  constructor(...a) { if (a.length === 0) super(clockMs); else super(...a); }
  static now() { return clockMs; }
}
const at = (s) => { clockMs = RealDate.parse(s); };

const call = async (DB, method, path, body) => {
  const saved = globalThis.Date;
  globalThis.Date = FixtureDate;
  try {
    const headers = { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` };
    const req = new Request(`https://jobs.test${path}`, {
      method, headers, body: body === undefined ? undefined : JSON.stringify(body),
    });
    const res = await worker.fetch(req, { DB, HARNESS_SECRET: SECRET });
    return { status: res.status, body: await res.json().catch(() => null) };
  } finally { globalThis.Date = saved; }
};
const putMachine = (DB, b) => call(DB, 'POST', '/api/lane-fleet/machines', b);
const getMachines = (DB) => call(DB, 'GET', '/api/lane-fleet/machines');
const cost = (DB, b) => call(DB, 'POST', '/api/lane-fleet/cost', b);
const COST = { cpu_kind: 'shared', cpus: 2, memory_mb: 2048 };
const runRow = (db, o) => db.prepare(
  `INSERT INTO lane_runs (lane, project, args_json, enqueued_at, claimed_at, claimed_by, lease_until, heartbeat_at, status, finished_at)
   VALUES (?, ?, '["bin/x.sh"]', ?, ?, ?, ?, ?, ?, ?)`
).run(o.lane, o.project, o.claimed_at, o.claimed_at, o.by, o.lease_until ?? null, o.heartbeat_at ?? null, o.status, o.finished_at ?? null);

test('BH-6126 lane-fleet routes', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  const fresh = async () => openDb();

  await t.test('W1 lane_machines, its index and the nine seeds; the schema applies twice', async () => {
    const { db } = await fresh();
    const cols = db.prepare('PRAGMA table_info(lane_machines)').all().map((c) => c.name);
    for (const c of ['machine_id', 'app', 'state', 'cpu_kind', 'cpus', 'memory_mb', 'started_at', 'stopped_at',
      'costed_until', 'failed_at', 'updated_at', 'actor']) assert.ok(cols.includes(c), `lane_machines has ${c}`);
    assert.ok(db.prepare("SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_lane_machines_state'").get());
    const val = (k) => (db.prepare('SELECT value FROM settings WHERE key = ?').get(k) || {}).value;
    assert.equal(val('lane_fleet.warm_floor'), '1');
    assert.equal(val('lane_fleet.scale_up_wait_s'), '60');
    assert.equal(val('lane_fleet.idle_stop_s'), '600');
    assert.equal(val('lane_fleet.max_machines'), '0');
    assert.equal(val('lane_fleet.vm_size'), 'shared-cpu-2x');
    assert.equal(val('lane_fleet.vm_memory_mb'), '2048');
    assert.equal(val('lane_fleet.start_grace_s'), '180');
    assert.equal(val('lane_fleet.failed_start_backoff_s'), '900');
    assert.equal(val('lane_fleet.image'), 'registry.fly.io/lane-run:latest');
    db.exec(SCHEMA);
  });

  await t.test('W2 POST insert 201 / update 200 / 400s; GET in_flight, promotion, busy and idle_s', async () => {
    const { db, DB } = await fresh();
    at('2099-10-03T04:00:00Z');
    assert.equal((await putMachine(DB, { machine_id: 'fixturem0001', state: 'starting', ...COST })).status, 201);
    assert.equal((await putMachine(DB, { machine_id: 'fixturem0001', state: 'starting' })).status, 200);
    assert.equal((await putMachine(DB, { machine_id: 'BAD-ID', state: 'starting' })).status, 400);
    assert.equal((await putMachine(DB, { machine_id: 'fixturem0002', state: 'running' })).status, 400);
    assert.equal((await putMachine(DB, { machine_id: 'fixturem0002', state: 'started', started_at: 'yesterday' })).status, 400);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM lane_machines').get().n, 1);
    const kept = db.prepare('SELECT cpus, memory_mb FROM lane_machines').get();
    assert.deepEqual([kept.cpus, kept.memory_mb], [2, 2048], 'an update without a size keeps the size');

    at('2099-10-03T04:02:59Z');
    let m = (await getMachines(DB)).body.machines[0];
    assert.equal(m.in_flight, true, 'within grace (179 s < 180 s)');
    at('2099-10-03T04:03:00Z');
    m = (await getMachines(DB)).body.machines[0];
    assert.equal(m.in_flight, false, 'grace over');
    assert.equal(m.state, 'starting');
    assert.equal(m.idle_s, 180);

    at('2099-10-03T04:01:00Z');
    runRow(db, { lane: 'alpha', project: 'p1', claimed_at: '2099-10-03T04:00:30Z', by: 'fixturem0001',
      lease_until: '2099-10-03T04:02:30Z', heartbeat_at: '2099-10-03T04:00:50Z', status: 'claimed' });
    m = (await getMachines(DB)).body.machines[0];
    assert.equal(m.state, 'started', 'the first claim promotes the row');
    assert.equal(m.in_flight, false);
    assert.equal(m.busy, true);
    assert.equal(m.idle_s, 0);
    assert.equal(db.prepare('SELECT state FROM lane_machines').get().state, 'started');

    db.prepare("UPDATE lane_runs SET status='done', finished_at='2099-10-03T04:01:10Z'").run();
    at('2099-10-03T04:11:10Z');
    m = (await getMachines(DB)).body.machines[0];
    assert.equal(m.busy, false);
    assert.equal(m.idle_s, 600, 'idle since the run finished');

    assert.equal((await putMachine(DB, { machine_id: 'fixturem0001', state: 'stopped' })).status, 200);
    assert.equal((await getMachines(DB)).body.machines.length, 0, 'a stopped row is not listed');
    const r = db.prepare('SELECT stopped_at FROM lane_machines').get();
    assert.equal(r.stopped_at, '2099-10-03T04:11:10Z');
  });

  await t.test('W3 one cost row per minute with lane attribution; replay writes 0; costed_until moves', async () => {
    const { db, DB } = await fresh();
    at('2099-10-03T04:00:00Z');
    await putMachine(DB, { machine_id: 'fixturecost1', state: 'started', started_at: '2099-10-03T04:00:20Z', ...COST });
    runRow(db, { lane: 'alpha', project: 'p1', claimed_at: '2099-10-03T04:00:30Z', by: 'fixturecost1',
      status: 'done', finished_at: '2099-10-03T04:02:10Z' });
    runRow(db, { lane: 'beta', project: 'p2', claimed_at: '2099-10-03T04:03:05Z', by: 'fixturecost1',
      lease_until: '2099-10-03T04:09:00Z', status: 'claimed' });
    at('2099-10-03T04:05:00Z');
    const a = await cost(DB, { machine_id: 'fixturecost1', through: '2099-10-03T04:05:00Z', usd_per_s: 0.00001, ...COST });
    assert.equal(a.status, 200);
    assert.equal(a.body.written, 5);
    assert.equal(a.body.already, 0);
    assert.equal(a.body.incomplete, false);
    assert.equal(a.body.costed_until, '2099-10-03T04:05:00Z');
    const rows = db.prepare("SELECT * FROM cost_rows WHERE box='lane-run-fixturecost1' ORDER BY ts").all();
    assert.deepEqual(rows.map((r) => r.lane_id), ['alpha', 'alpha', 'alpha', 'beta', 'beta']);
    assert.deepEqual(rows.map((r) => r.project), ['p1', 'p1', 'p1', 'p2', 'p2']);
    assert.equal(rows[0].row_hash, 'lane-fleet:fixturecost1:2099-10-03T04:00:00Z');
    assert.equal(rows[0].ts, '2099-10-03T04:01:00Z');
    assert.equal(rows[0].stage, 'infra');
    assert.equal(rows[0].runner, 'fly');
    assert.equal(rows[0].model, 'shared-2x-2048mb');
    assert.equal(rows[0].duration_s, 60);
    assert.ok(Math.abs(rows[0].cost_usd - 0.0006) < 1e-12);
    assert.equal(rows[0].note, 'fly:fixturecost1');
    const b = await cost(DB, { machine_id: 'fixturecost1', through: '2099-10-03T04:05:00Z', usd_per_s: 0.00001, ...COST });
    assert.deepEqual([b.body.written, b.body.already], [0, 0], 'nothing after costed_until');
    db.prepare("UPDATE lane_machines SET costed_until=NULL").run();
    const c = await cost(DB, { machine_id: 'fixturecost1', through: '2099-10-03T04:05:00Z', usd_per_s: 0.00001, ...COST });
    assert.deepEqual([c.body.written, c.body.already], [0, 5], 'a replay of the same minutes writes nothing');
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM cost_rows').get().n, 5);
    at('2099-10-03T04:06:30Z');
    const d = await cost(DB, { machine_id: 'fixturecost1', through: '2099-10-03T04:06:00Z', usd_per_s: 0.00001, ...COST });
    assert.equal(d.body.written, 1);
    assert.equal(db.prepare("SELECT lane_id FROM cost_rows ORDER BY ts DESC LIMIT 1").get().lane_id, 'beta');
  });

  await t.test('W4 a 200-minute gap writes 120 rows and incomplete=true, then 80 and incomplete=false', async () => {
    const { db, DB } = await fresh();
    at('2099-10-03T00:00:00Z');
    await putMachine(DB, { machine_id: 'fixturegap01', state: 'started', ...COST });
    at('2099-10-03T03:20:00Z');
    const a = await cost(DB, { machine_id: 'fixturegap01', through: '2099-10-03T03:20:00Z', usd_per_s: 0.00001 });
    assert.deepEqual([a.body.written, a.body.incomplete, a.body.costed_until], [120, true, '2099-10-03T02:00:00Z']);
    const b = await cost(DB, { machine_id: 'fixturegap01', through: '2099-10-03T03:20:00Z', usd_per_s: 0.00001 });
    assert.deepEqual([b.body.written, b.body.incomplete, b.body.costed_until], [80, false, '2099-10-03T03:20:00Z']);
    const n = db.prepare("SELECT COUNT(*) AS n, SUM(lane_id='lane-fleet') AS idle FROM cost_rows").get();
    assert.deepEqual([n.n, n.idle], [200, 200], 'idle minutes are billed to lane-fleet');
  });

  await t.test('W5 null price = NULL cost + UNPRICED; bad price 400; unknown machine 404; future 400; cost-rows read path', async () => {
    const { db, DB } = await fresh();
    at('2099-10-03T04:00:00Z');
    await putMachine(DB, { machine_id: 'fixtureunp01', state: 'started' });
    at('2099-10-03T04:02:00Z');
    const a = await cost(DB, { machine_id: 'fixtureunp01', through: '2099-10-03T04:02:00Z', usd_per_s: null });
    assert.equal(a.body.written, 2);
    const r = db.prepare('SELECT cost_usd, note, model FROM cost_rows LIMIT 1').get();
    assert.equal(r.cost_usd, null, 'unpriced is NULL, never $0');
    assert.equal(r.note, 'UNPRICED:fly-size-unknown:fixtureunp01');
    assert.equal(r.model, 'unknown-0x-0mb');
    assert.equal((await cost(DB, { machine_id: 'fixtureunp01', through: '2099-10-03T04:02:00Z', usd_per_s: 'abc' })).status, 400);
    assert.equal((await cost(DB, { machine_id: 'fixtureunp01', through: '2099-10-03T04:02:00Z', usd_per_s: -1 })).status, 400);
    assert.equal((await cost(DB, { machine_id: 'fixtureunp01', through: '2099-10-03T04:02:00Z' })).status, 400, 'a missing price is not 0');
    assert.equal((await cost(DB, { machine_id: 'fixtureunp01', through: '2099-10-03T04:02:30Z', usd_per_s: 0 })).status, 400);
    assert.equal((await cost(DB, { machine_id: 'fixtureunp01', through: '2099-10-03T04:10:00Z', usd_per_s: 0 })).status, 400);
    const u = await cost(DB, { machine_id: 'fixturenone1', through: '2099-10-03T04:02:00Z', usd_per_s: 0 });
    assert.equal(u.status, 404);
    assert.equal(u.body.error, 'unknown machine');

    await putMachine(DB, { machine_id: 'fixturepri01', state: 'started', ...COST });
    runRow(db, { lane: 'alpha', project: 'p1', claimed_at: '2099-10-03T04:02:00Z', by: 'fixturepri01',
      lease_until: '2099-10-03T04:09:00Z', status: 'claimed' });
    at('2099-10-03T04:04:00Z');
    await cost(DB, { machine_id: 'fixturepri01', through: '2099-10-03T04:04:00Z', usd_per_s: 0.00002, ...COST });
    const read = await call(DB, 'GET', '/api/metrics/cost-rows?box=lane-run-fixturepri01');
    assert.equal(read.status, 200);
    assert.equal(read.body.cost_rows.length, 2);
    for (const row of read.body.cost_rows) {
      assert.equal(row.lane_id, 'alpha');
      assert.ok(Math.abs(row.cost_usd - 0.0012) < 1e-12);
    }
  });

  await t.test('W6 a reused machine is not billed for the time it sat stopped', async () => {
    const { db, DB } = await fresh();
    at('2099-10-03T04:00:00Z');
    await putMachine(DB, { machine_id: 'fixturereu01', state: 'started', ...COST });
    at('2099-10-03T04:02:00Z');
    await cost(DB, { machine_id: 'fixturereu01', through: '2099-10-03T04:02:00Z', usd_per_s: 0.00001 });
    await putMachine(DB, { machine_id: 'fixturereu01', state: 'stopped' });
    at('2099-10-03T05:00:00Z');
    await putMachine(DB, { machine_id: 'fixturereu01', state: 'starting' });
    at('2099-10-03T05:03:00Z');
    const a = await cost(DB, { machine_id: 'fixturereu01', through: '2099-10-03T05:03:00Z', usd_per_s: 0.00001 });
    assert.equal(a.body.written, 3);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM cost_rows').get().n, 5);
  });

  await t.test('W7 a reuse is in flight until a claim after its start; stopped_at and failed on a stop', async () => {
    const { db, DB } = await fresh();
    at('2099-10-03T04:00:00Z');
    await putMachine(DB, { machine_id: 'fixturereu01', state: 'started', ...COST });
    runRow(db, { lane: 'alpha', project: 'p1', claimed_at: '2099-10-03T04:00:30Z', by: 'fixturereu01',
      status: 'done', finished_at: '2099-10-03T04:01:00Z' });
    at('2099-10-03T04:20:00Z');
    await putMachine(DB, { machine_id: 'fixturereu01', state: 'stopped' });
    at('2099-10-03T05:00:00Z');
    await putMachine(DB, { machine_id: 'fixturereu01', state: 'starting' });
    at('2099-10-03T05:00:30Z');
    let g = (await getMachines(DB)).body;
    assert.deepEqual([g.machines[0].state, g.machines[0].in_flight], ['starting', true], 'an old claim does not end the start');
    assert.equal(g.last_failed_at, null);
    runRow(db, { lane: 'beta', project: 'p1', claimed_at: '2099-10-03T05:00:40Z', by: 'fixturereu01',
      lease_until: '2099-10-03T05:05:00Z', status: 'claimed' });
    at('2099-10-03T05:00:50Z');
    g = (await getMachines(DB)).body;
    assert.deepEqual([g.machines[0].state, g.machines[0].in_flight], ['started', false], 'a claim after the start promotes it');

    assert.equal((await putMachine(DB, { machine_id: 'fixturereu01', state: 'starting', failed: true })).status, 400);
    assert.equal((await putMachine(DB, { machine_id: 'fixturereu01', state: 'stopped', failed: 'yes' })).status, 400);
    assert.equal((await putMachine(DB, { machine_id: 'fixturereu01', state: 'started', stopped_at: '2099-10-03T05:00:10Z' })).status, 400);
    assert.equal((await putMachine(DB, { machine_id: 'fixturereu01', state: 'stopped', stopped_at: 'now' })).status, 400);
    at('2099-10-03T05:10:00Z');
    assert.equal((await putMachine(DB, { machine_id: 'fixturereu01', state: 'stopped', stopped_at: '2099-10-03T05:02:10Z', failed: true })).status, 200);
    const r = db.prepare('SELECT stopped_at, failed_at FROM lane_machines').get();
    assert.deepEqual([r.stopped_at, r.failed_at], ['2099-10-03T05:02:10Z', '2099-10-03T05:10:00Z']);
    assert.equal((await getMachines(DB)).body.last_failed_at, '2099-10-03T05:10:00Z');
    const c = await cost(DB, { machine_id: 'fixturereu01', through: '2099-10-03T05:10:00Z', usd_per_s: 0.00001 });
    assert.equal(c.body.written, 3, 'billed to the stop minute (05:00-05:03), not to now');
    assert.equal((await putMachine(DB, { machine_id: 'fixturefut01', state: 'stopped', stopped_at: '2099-10-03T06:00:00Z' })).status, 201);
    assert.equal(db.prepare("SELECT stopped_at FROM lane_machines WHERE machine_id='fixturefut01'").get().stopped_at,
      '2099-10-03T05:10:00Z', 'a stop time ahead of the worker clock is cut to now');
  });
});
