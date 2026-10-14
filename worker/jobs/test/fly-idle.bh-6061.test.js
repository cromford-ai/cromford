// BH-6061: the Fly idle reaper's stop ledger and started-machine snapshot.
// Driven through the REAL router (worker.fetch) against a real schema.sql
// database on the node:sqlite shim. W1 and W2 post the checked-in reaper
// fixture (fixtures/fly-idle-stop.bh-6061.json, the body bin/fly-idle-reaper.sh
// POSTs) and read it back. The clock is the fixture's stopped_at + 1 h, set by
// stubbing Date.now, so the 24 h window never depends on the wall clock.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const HARNESS = 'fixture-harness-secret';
const FIXTURE = JSON.parse(readFileSync(new URL('./fixtures/fly-idle-stop.bh-6061.json', import.meta.url), 'utf8'));
const STOP = FIXTURE.rows[0];
const NOW_MS = Date.parse(STOP.stopped_at) + 3600 * 1000;
const isoAt = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');

const call = (DB, method, path, body, auth = HARNESS) => {
  const headers = { 'content-type': 'application/json' };
  if (auth !== null) headers.authorization = `Bearer ${auth}`;
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: HARNESS })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const postStops = (DB, body) => call(DB, 'POST', '/api/fly-idle/stops', body);
const putSnap = (DB, body) => call(DB, 'PUT', '/api/fly-idle/machines', body);
const getIdle = (DB) => call(DB, 'GET', '/api/fly-idle');

// A stop row of the reaper's shape, `hoursAgo` before NOW_MS.
const stopAt = (mid, hoursAgo) => {
  const ms = NOW_MS - hoursAgo * 3600 * 1000;
  return { ...STOP, machine_id: mid, stop_id: `${mid}-${Math.floor(ms / 1000)}`, stopped_at: isoAt(ms) };
};
const snapRow = (mid, idle_state, idle_s, o = {}) => ({
  app: 'pool-cromford', machine_id: mid, size: 'performance-16x', source: 'pool',
  idle_s, idle_state, threshold_s: 900, usd_per_hour: 0.5, ...o,
});
const snap = (rows, o = {}) => ({ pass_at: isoAt(NOW_MS), apps_total: 3, apps_failed: 0, box: 'fixture', rows, ...o });

async function fresh(t) {
  const h = await openDb();
  if (h === null) t.skip('node:sqlite unavailable in this runtime');
  return h;
}

test('BH-6061 fly idle routes', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  const realNow = Date.now;
  Date.now = () => NOW_MS;
  t.after(() => { Date.now = realNow; });

  await t.test('W0 the schema seeds the four reaper settings rows', () => {
    const val = (k) => {
      const r = probe.db.prepare('SELECT value FROM settings WHERE key = ?').get(k);
      return r ? r.value : null;
    };
    assert.equal(val('fly.idle_stop_after_s'), '900');
    assert.equal(val('fly.idle_nosignal_alert_s'), '3600');
    assert.equal(val('fly.idle_fail_alert_after'), '3');
    assert.equal(val('fly.idle_max_stops_per_pass'), '10');
    assert.throws(() => probe.db.prepare(
      "INSERT INTO fly_idle_stops (stop_id, app, machine_id, source, idle_s, threshold_s, status, stopped_at) "
      + "VALUES ('a1b2c3-1791700000','x','a1b2c3','pool',1,1,'stopped','2026-10-11T00:00:00Z')").run(),
    /CHECK/, 'status is requested only');
  });

  await t.test('W1 the reaper fixture inserts once; a replay is ignored', async (tt) => {
    const { db, DB } = await fresh(tt);
    const a = await postStops(DB, FIXTURE);
    assert.equal(a.status, 200, JSON.stringify(a.body));
    assert.equal(a.body.inserted, 1);
    assert.equal(a.body.ignored, 0);
    const b = await postStops(DB, FIXTURE);
    assert.equal(b.status, 200, JSON.stringify(b.body));
    assert.equal(b.body.inserted, 0);
    assert.equal(b.body.ignored, 1);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM fly_idle_stops').get().n, 1);
    const unauth = await call(DB, 'POST', '/api/fly-idle/stops', FIXTURE, null);
    assert.equal(unauth.status, 401, 'the bearer guards the route');
  });

  await t.test('W2 GET returns the fixture row; a row 25 h ago is not in stops', async (tt) => {
    const { DB } = await fresh(tt);
    assert.equal((await postStops(DB, FIXTURE)).status, 200);
    const old = stopAt('0a0d00000025', 25);
    const recent = stopAt('0a0d00000023', 23);
    const p = await postStops(DB, { rows: [old, { ...recent, usd_per_hour: null }] });
    assert.equal(p.status, 200, JSON.stringify(p.body));
    assert.equal(p.body.inserted, 2);
    const g = await getIdle(DB);
    assert.equal(g.status, 200, JSON.stringify(g.body));
    const s0 = g.body.stops[0];
    for (const k of ['stop_id', 'app', 'machine_id', 'size', 'source', 'idle_s', 'threshold_s', 'usd_per_hour', 'status', 'box', 'stopped_at']) {
      assert.equal(s0[k], STOP[k], `stops[0].${k}`);
    }
    assert.equal(s0.status, 'requested');
    assert.deepEqual(g.body.stops.map((s) => s.machine_id), [STOP.machine_id, recent.machine_id], 'newest first, 25 h row gone');
    assert.equal(g.body.stops_24h, 2);
    assert.equal(g.body.unpriced_24h, 1);
    assert.ok(Math.abs(g.body.saved_usd_per_hour_24h - STOP.usd_per_hour) < 1e-9, 'unpriced rows add nothing');
    assert.equal(g.body.pass, null, 'no snapshot yet');
    assert.deepEqual(g.body.machines, []);
    assert.equal(g.body.over_count, 0);
  });

  await t.test('W3 validation answers 400 and writes nothing', async (tt) => {
    const { db, DB } = await fresh(tt);
    const cases = [
      ['uppercase app', { rows: [{ ...STOP, app: 'Pool-Board' }] }],
      ['machine id ../x', { rows: [{ ...STOP, machine_id: '../x' }] }],
      ['negative idle_s', { rows: [{ ...STOP, idle_s: -1 }] }],
      ['51 rows', { rows: Array.from({ length: 51 }, (_, i) => stopAt(`0b0d${String(i).padStart(8, '0')}`, 1)) }],
      ['status stopped', { rows: [{ ...STOP, status: 'stopped' }] }],
      ['no rows', { rows: [] }],
      ['stop_id of another machine', { rows: [{ ...STOP, stop_id: 'abcdef123456-1791700000' }] }],
      ['negative usd', { rows: [{ ...STOP, usd_per_hour: -0.1 }] }],
      ['stopped_at not UTC', { rows: [{ ...STOP, stopped_at: '2026-10-11 06:26:40' }] }],
      ['one bad row of two', { rows: [stopAt('0c0d00000001', 1), { ...STOP, idle_s: 1.5 }] }],
    ];
    for (const [name, body] of cases) {
      const r = await postStops(DB, body);
      assert.equal(r.status, 400, `${name}: ${JSON.stringify(r.body)}`);
    }
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM fly_idle_stops').get().n, 0);
    const fifty = await postStops(DB, { rows: Array.from({ length: 50 }, (_, i) => stopAt(`0d0d${String(i).padStart(8, '0')}`, 1)) });
    assert.equal(fifty.status, 200, JSON.stringify(fifty.body));
    assert.equal(fifty.body.inserted, 50, '50 rows is the cap, and over 9 rows spans chunks');
  });

  await t.test('W4 a PUT replaces the snapshot; pass and over_count follow it', async (tt) => {
    const { DB } = await fresh(tt);
    const three = [
      snapRow('1a0000000001', 'over', 1200),
      snapRow('1a0000000002', 'idle', 300),
      snapRow('1a0000000003', 'unknown', null, { usd_per_hour: null }),
    ];
    const a = await putSnap(DB, snap(three));
    assert.equal(a.status, 200, JSON.stringify(a.body));
    let g = (await getIdle(DB)).body;
    assert.equal(g.machines.length, 3);
    assert.equal(g.over_count, 1);
    assert.deepEqual(g.machines.map((m) => m.machine_id), ['1a0000000001', '1a0000000002', '1a0000000003'], 'idle desc, unknown last');
    assert.equal(g.machines[2].idle_s, null, 'unknown idle stays null, never 0');
    assert.equal(g.pass.partial, 0);

    const b = await putSnap(DB, snap([snapRow('2b0000000001', 'busy', 0, { source: 'testhost', app: 'bh-testhost-example-org' })],
      { apps_total: 5, apps_failed: 2 }));
    assert.equal(b.status, 200, JSON.stringify(b.body));
    g = (await getIdle(DB)).body;
    assert.deepEqual(g.machines.map((m) => [m.app, m.machine_id, m.idle_state]), [['bh-testhost-example-org', '2b0000000001', 'busy']]);
    assert.equal(g.over_count, 0);
    assert.equal(g.pass.apps_total, 5);
    assert.equal(g.pass.apps_failed, 2);
    assert.equal(g.pass.partial, 1);
    assert.equal(g.pass.pass_at, isoAt(NOW_MS));

    const empty = await putSnap(DB, snap([]));
    assert.equal(empty.status, 200, JSON.stringify(empty.body));
    assert.deepEqual((await getIdle(DB)).body.machines, [], 'a pass with no started machine empties the snapshot');
  });

  await t.test('W5 a PUT with one invalid row is 400 and the previous snapshot stays', async (tt) => {
    const { DB } = await fresh(tt);
    assert.equal((await putSnap(DB, snap([snapRow('3c0000000001', 'over', 1000)]))).status, 200);
    const before = (await getIdle(DB)).body;
    const cases = [
      ['bad idle_state', [snapRow('3c0000000002', 'idle', 10), snapRow('3c0000000003', 'sleeping', 10)]],
      ['bad machine id', [snapRow('XYZ', 'idle', 10)]],
      ['negative idle_s', [snapRow('3c0000000004', 'idle', -5)]],
      ['duplicate machine', [snapRow('3c0000000005', 'idle', 1), snapRow('3c0000000005', 'idle', 2)]],
    ];
    for (const [name, rows] of cases) {
      const r = await putSnap(DB, snap(rows, { apps_failed: 1 }));
      assert.equal(r.status, 400, `${name}: ${JSON.stringify(r.body)}`);
    }
    for (const [name, body] of [
      ['apps_failed over apps_total', snap([], { apps_total: 1, apps_failed: 2 })],
      ['pass_at not ISO', snap([], { pass_at: 'yesterday' })],
    ]) {
      const r = await putSnap(DB, body);
      assert.equal(r.status, 400, `${name}: ${JSON.stringify(r.body)}`);
    }
    const after = (await getIdle(DB)).body;
    assert.deepEqual(after.machines, before.machines);
    assert.deepEqual(after.pass, before.pass);
  });
});
