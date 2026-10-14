// BH-6127 (BH-6047 part 4 of 5): Mission Control's lane-run list, detail and
// metrics, and the queue-wait alert decision. Driven through the REAL router
// (worker.fetch) over a real schema.sql database on the node:sqlite shim. The
// shell side is tests/lane-run-wait-alert.bh-6127-test.sh.
//
// Seeded times are relative to the real clock and chosen far from every edge
// (900 s against a 600 s limit), so no outcome depends on the exact second. The
// pure helpers take a fixed clock.
import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { laneMetrics, waitDecision } from '../src/routes/lane-runs-metrics.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'fixture-harness-secret';
// BH-6005: the schema is composed from schema.d/; schema.sql is not committed.
const SCHEMA = jobsSchemaSql();
const CONSOLE_FIXTURE = fileURLToPath(new URL('../../../console-ui/tests/fixtures/lane-runs.bh-6127.json', import.meta.url));

const call = (DB, method, path, body) => {
  const headers = { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` };
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const iso = (msv) => new Date(msv).toISOString().replace(/\.\d{3}Z$/, 'Z');
// The router stamps each request with the real clock, so the seeds are offsets
// from ONE anchor read here, and every assertion leaves minutes of slack for
// the seconds the suite takes.
const ANCHOR = Date.now();  // determinism: ok the single anchor; every seed below is an offset off it, compared with wide margins
const ago = (s) => iso(ANCHOR - s * 1000);
// seed(db, {lane, project, status, enq (s ago), claim (s after enq), by, fin (s after claim), rc, prof})
let seq = 0;
function seed(db, r) {
  const enq = r.enq ?? 60;
  const enqMs = ANCHOR - enq * 1000;
  const claimedAt = r.claim === undefined ? null : iso(enqMs + r.claim * 1000);
  const finishedAt = r.fin === undefined || claimedAt === null ? null : iso(Date.parse(claimedAt) + r.fin * 1000);
  seq += 1;
  const info = db.prepare(
    `INSERT INTO lane_runs (lane, project, args_json, enqueued_at, enqueued_by, claimed_at, claimed_by,
       attempts, status, rc, prof_line, finished_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`
  ).run(r.lane || 'demo', r.project || `p${seq}`, r.args_json ?? '["bin/x.sh","p1"]', iso(enqMs), 'hub',
    claimedAt, r.by ?? null, claimedAt ? 1 : 0, r.status || 'queued', r.rc ?? null, r.prof ?? null, finishedAt);
  return Number(info.lastInsertRowid);
}
// The observable-outcome rows: 1 queued 900 s ago, 2 done, 1 claimed, 1 died.
function seedDemo(db) {
  return {
    queued: seed(db, { status: 'queued', enq: 900 }),
    done1: seed(db, { status: 'done', enq: 600, claim: 30, by: 'm1', fin: 20, rc: 0, prof: 'PROF demo ms=20000' }),
    done2: seed(db, { status: 'done', enq: 500, claim: 60, by: 'm2', fin: 10, rc: 3 }),
    claimed: seed(db, { status: 'claimed', enq: 400, claim: 120, by: 'm1' }),
    died: seed(db, { status: 'died', enq: 300, claim: 240, by: 'm2' }),
  };
}
const setting = (db, k, v) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-10-12T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(k, v);
const tick = (DB, body = {}) => call(DB, 'POST', '/api/lane-runs/wait-tick', body);
const ack = (DB, lane) => call(DB, 'POST', '/api/lane-runs/wait-ack', { lane });
const costRow = (db, box, lane, usd, ts) => db.prepare(
  'INSERT INTO cost_rows (box, row_hash, line_no, ts, cost_usd, lane_id, row_source, inserted_at) VALUES (?,?,?,?,?,?,?,?)'
).run(box, `h${(seq += 1)}`, seq, ts, usd, lane, 'fly-machine', ts);

test('BH-6127 lane-run metrics and the queue-wait alert', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  const fresh = async () => openDb();

  await t.test('S1 both tables exist, the seed is 10, and schema.sql applies twice', async () => {
    const { db } = await fresh();
    const cols = (tb) => db.prepare(`PRAGMA table_info(${tb})`).all().map((c) => c.name);
    for (const c of ['lane', 'over_ticks', 'first_over_at', 'last_wait_s', 'last_tick_at', 'alerted_at']) {
      assert.ok(cols('lane_run_wait_alerts').includes(c), `lane_run_wait_alerts has ${c}`);
    }
    for (const c of ['box', 'load1', 'reported_at']) assert.ok(cols('lane_run_hub_load').includes(c), `lane_run_hub_load has ${c}`);
    assert.equal(db.prepare('SELECT value FROM settings WHERE key = ?').get('lane_run.wait_alert_min').value, '10');
    db.exec(SCHEMA);
  });

  await t.test('L1 L2 the list is newest first and says truncated only at the cap', async () => {
    const { db, DB } = await fresh();
    const ids = [seed(db, {}), seed(db, {}), seed(db, {})];
    const a = await call(DB, 'GET', '/api/lane-runs?limit=2');
    assert.equal(a.status, 200);
    assert.deepEqual(a.body.runs.map((r) => r.id), [ids[2], ids[1]]);
    assert.equal(a.body.truncated, true);
    assert.equal(a.body.limit, 2);
    const b = await call(DB, 'GET', '/api/lane-runs?limit=5');
    assert.equal(b.body.runs.length, 3);
    assert.equal(b.body.truncated, false);
    const c = await call(DB, 'GET', '/api/lane-runs?limit=3');
    assert.equal(c.body.truncated, false, 'exactly the limit is not truncated');
    const d = await call(DB, 'GET', '/api/lane-runs');
    assert.equal(d.body.limit, 200);
  });

  await t.test('L3 lane, machine and status filters return only matching rows', async () => {
    const { db, DB } = await fresh();
    const ids = seedDemo(db);
    const other = seed(db, { lane: 'other', status: 'done', claim: 5, by: 'm1', fin: 1, rc: 0 });
    const ids_ = async (q) => (await call(DB, 'GET', `/api/lane-runs?${q}`)).body.runs.map((r) => r.id).sort((x, y) => x - y);
    assert.deepEqual(await ids_('lane=demo'), Object.values(ids).sort((x, y) => x - y));
    assert.deepEqual(await ids_('lane=other'), [other]);
    assert.deepEqual(await ids_('machine=m1'), [ids.done1, ids.claimed, other].sort((x, y) => x - y));
    assert.deepEqual(await ids_('status=done&lane=demo'), [ids.done1, ids.done2].sort((x, y) => x - y));
    assert.deepEqual(await ids_('status=queued'), [ids.queued]);
  });

  await t.test('L4 a bad status, limit or name is a 400, never clamped', async () => {
    const { DB } = await fresh();
    for (const q of ['status=bogus', 'limit=0', 'limit=501', 'limit=abc', 'lane=a%20b', 'machine=x;y']) {
      const r = await call(DB, 'GET', `/api/lane-runs?${q}`);
      assert.equal(r.status, 400, q);
      assert.ok(r.body.error, q);
    }
  });

  await t.test('D1 run detail carries rc, prof, claimer, args and wait; D2 unknown id is 404', async () => {
    const { db, DB } = await fresh();
    const ids = seedDemo(db);
    const r = await call(DB, 'GET', `/api/lane-runs/${ids.done1}`);
    assert.equal(r.status, 200);
    const run = r.body.run;
    assert.equal(run.id, ids.done1);
    assert.equal(run.rc, 0);
    assert.equal(run.prof_line, 'PROF demo ms=20000');
    assert.equal(run.claimed_by, 'm1');
    assert.deepEqual(run.args, ['bin/x.sh', 'p1']);
    const row = db.prepare('SELECT enqueued_at, claimed_at FROM lane_runs WHERE id=?').get(ids.done1);
    assert.equal(run.wait_s, (Date.parse(row.claimed_at) - Date.parse(row.enqueued_at)) / 1000);
    assert.equal(run.wait_s, 30);
    assert.equal(run.run_s, 20);
    const q = (await call(DB, 'GET', `/api/lane-runs/${ids.queued}`)).body.run;
    assert.ok(q.wait_s >= 900 && q.wait_s < 1000, 'a queued run waits now - enqueued_at');
    assert.equal(q.run_s, null);
    assert.equal(q.rc, null, 'no rc yet is null, not 0');
    const bad = seed(db, { args_json: 'not json' });
    assert.equal((await call(DB, 'GET', `/api/lane-runs/${bad}`)).body.run.args, null, 'unparseable args is null, not a 500');
    const missing = await call(DB, 'GET', '/api/lane-runs/999999');
    assert.equal(missing.status, 404);
  });

  await t.test('M2 metrics: per-lane and per-machine counts, wait p50 and max, hub load', async () => {
    const { db, DB } = await fresh();
    seedDemo(db);
    seed(db, { lane: 'other', status: 'done', enq: 100, claim: 10, by: 'm3', fin: 1, rc: 0 });
    const r = await call(DB, 'GET', '/api/lane-runs/metrics');
    assert.equal(r.status, 200);
    const demo = r.body.lanes.find((l) => l.lane === 'demo');
    assert.deepEqual([demo.queued, demo.claimed, demo.done, demo.died], [1, 1, 2, 1]);
    // The sample: claims 30, 60, 120, 240 and the queued 900+: p50 is 120.
    assert.equal(demo.wait_n, 5);
    assert.equal(demo.wait_p50_s, 120);
    assert.ok(demo.wait_max_s >= 900 && demo.wait_max_s < 1000);
    const m = Object.fromEntries(r.body.machines.map((x) => [x.machine, x]));
    assert.deepEqual([m.m1.claimed, m.m1.done, m.m1.died], [1, 1, 0]);
    assert.deepEqual([m.m2.claimed, m.m2.done, m.m2.died], [0, 1, 1]);
    assert.equal(m.m3.done, 1);
    assert.ok(m.m1.last_claimed_at);
    assert.equal(r.body.wait_alert_min, 10);
    assert.equal(r.body.truncated, false);
    assert.equal(r.body.hours, 24);
    await tick(DB, { box: 'hub', load1: 0.42 });
    const r2 = await call(DB, 'GET', '/api/lane-runs/metrics');
    assert.equal(r2.body.hub.load1, 0.42);
    assert.equal(r2.body.hub.box, 'hub');
    assert.ok(r2.body.hub.age_s >= 0 && r2.body.hub.age_s < 60);
    // An old run outside a 1 h window is not counted; a live one always is.
    seed(db, { lane: 'old', status: 'done', enq: 7200, claim: 5, by: 'm9', fin: 1, rc: 0 });
    seed(db, { lane: 'oldq', status: 'queued', enq: 7200 });
    const r3 = await call(DB, 'GET', '/api/lane-runs/metrics?hours=1');
    assert.ok(!r3.body.lanes.some((l) => l.lane === 'old'));
    assert.equal(r3.body.lanes.find((l) => l.lane === 'oldq').queued, 1);
    for (const h of ['0', '169', 'x']) assert.equal((await call(DB, 'GET', `/api/lane-runs/metrics?hours=${h}`)).status, 400, h);
  });

  await t.test('M3 cost sums only the lane\'s lane-run-% rows in the window; M4 none is 0 and available', async () => {
    const { db, DB } = await fresh();
    seedDemo(db);
    const recent = ago(300);
    costRow(db, 'lane-run-a', 'demo', 0.01, recent);
    costRow(db, 'lane-run-b', 'demo', 0.02, recent);
    costRow(db, 'lane-run-a', 'other', 0.5, recent);
    costRow(db, 'hub', 'demo', 7, recent);
    costRow(db, 'lane-run-a', 'demo', 9, ago(3 * 86400));
    costRow(db, 'lane-run-a', 'lane-fleet', 0.004, recent);
    const r = await call(DB, 'GET', '/api/lane-runs/metrics');
    assert.equal(r.body.cost_available, true);
    assert.equal(r.body.lanes.find((l) => l.lane === 'demo').cost_usd, 0.03);
    const other = r.body.lanes.find((l) => l.lane === 'other');
    assert.equal(other.cost_usd, 0.5, 'a lane with cost and no run in the window still shows');
    assert.equal(other.done, 0);
    assert.equal(r.body.idle_cost_usd, 0.004);
    assert.ok(!r.body.lanes.some((l) => l.lane === 'lane-fleet'), 'the idle pseudo-lane is not a lane row');

    const { db: db2, DB: DB2 } = await fresh();
    seedDemo(db2);
    const r2 = await call(DB2, 'GET', '/api/lane-runs/metrics');
    assert.equal(r2.body.lanes.find((l) => l.lane === 'demo').cost_usd, 0);
    assert.equal(r2.body.cost_available, true);
    assert.equal(r2.body.idle_cost_usd, 0);
  });

  await t.test('M5 no hub row is hub:null; a cost read that fails says cost_available:false', async () => {
    const { db, DB } = await fresh();
    seedDemo(db);
    const r = await call(DB, 'GET', '/api/lane-runs/metrics');
    assert.equal(r.body.hub, null);
    db.exec('DROP TABLE cost_rows');
    const r2 = await call(DB, 'GET', '/api/lane-runs/metrics');
    assert.equal(r2.status, 200);
    assert.equal(r2.body.cost_available, false);
    assert.equal(r2.body.lanes.find((l) => l.lane === 'demo').done, 2, 'the rest of the answer stands');
  });

  await t.test('M6 laneMetrics on a fixed clock', () => {
    const now = Date.parse('2026-10-12T12:00:00Z');
    const rows = [
      { lane: 'a', status: 'done', enqueued_at: '2026-10-12T11:00:00Z', claimed_at: '2026-10-12T11:00:10Z' },
      { lane: 'a', status: 'claimed', enqueued_at: '2026-10-12T11:00:00Z', claimed_at: '2026-10-12T11:00:50Z' },
      { lane: 'a', status: 'queued', enqueued_at: '2026-10-12T11:45:00Z', claimed_at: null },
      { lane: 'a', status: 'died', enqueued_at: '2026-10-12T11:00:00Z', claimed_at: null },
      { lane: 'b', status: 'done', enqueued_at: '2026-10-12T11:00:00Z', claimed_at: '2026-10-12T11:00:05Z' },
    ];
    const m = laneMetrics(rows, now);
    assert.deepEqual(m.get('a'), { wait_p50_s: 50, wait_max_s: 900, wait_n: 3 });
    assert.deepEqual(m.get('b'), { wait_p50_s: 5, wait_max_s: 5, wait_n: 1 });
  });

  await t.test('W1 W2 over on 2 ticks fires once; after the ack tick 3 does not fire', async () => {
    const { db, DB } = await fresh();
    seed(db, { status: 'queued', enq: 900 });
    const t1 = await tick(DB);
    assert.equal(t1.status, 200);
    assert.deepEqual(t1.body.fire, []);
    assert.deepEqual(t1.body.over, ['demo']);
    assert.equal(t1.body.threshold_min, 10);
    const t2 = await tick(DB);
    assert.equal(t2.body.fire.length, 1);
    assert.equal(t2.body.fire[0].lane, 'demo');
    assert.equal(t2.body.fire[0].queued, 1);
    assert.equal(t2.body.fire[0].over_ticks, 2);
    assert.ok(t2.body.fire[0].wait_s >= 900);
    const a = await ack(DB, 'demo');
    assert.deepEqual([a.status, a.body.acked], [200, 1]);
    const t3 = await tick(DB);
    assert.deepEqual(t3.body.fire, [], 'latched: no repeat alert');
    assert.deepEqual(t3.body.over, ['demo']);
  });

  await t.test('W3 one spike does not fire: over, under, over', async () => {
    const { db, DB } = await fresh();
    const id = seed(db, { status: 'queued', enq: 900, project: 'p1' });
    assert.deepEqual((await tick(DB)).body.fire, []);
    db.prepare("UPDATE lane_runs SET status='claimed', claimed_at=?, claimed_by='m1' WHERE id=?").run(ago(1), id);
    const under = await tick(DB);
    assert.deepEqual(under.body.fire, []);
    assert.deepEqual(under.body.over, []);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM lane_run_wait_alerts').get().n, 0, 'the under tick resets the count');
    seed(db, { status: 'queued', enq: 900, project: 'p2' });
    assert.deepEqual((await tick(DB)).body.fire, [], 'a new breach starts at tick 1');
  });

  await t.test('W4 a wait exactly at the threshold is not over; a lane with no queued row is not over', () => {
    const d = waitDecision([{ lane: 'demo', wait_s: 600, queued: 1 }, { lane: 'b', wait_s: 601, queued: 1 }], [], 600);
    assert.deepEqual(d.over.map((q) => q.lane), ['b']);
    const e = waitDecision([{ lane: 'z', wait_s: 9999, queued: 0 }], [], 600);
    assert.deepEqual(e.over, []);
  });

  await t.test('W4b a lane with claimed rows only never goes over', async () => {
    const { db, DB } = await fresh();
    seed(db, { status: 'claimed', enq: 5000, claim: 1, by: 'm1' });
    await tick(DB);
    assert.deepEqual((await tick(DB)).body.fire, []);
  });

  await t.test('W5 ack with no breach row is 404; ack twice is 1 then 0; a bad lane is 400', async () => {
    const { db, DB } = await fresh();
    assert.equal((await ack(DB, 'demo')).status, 404);
    assert.equal((await ack(DB, 'demo; rm -rf /')).status, 400);
    seed(db, { status: 'queued', enq: 900 });
    await tick(DB);
    await tick(DB);
    assert.equal((await ack(DB, 'demo')).body.acked, 1);
    const again = await ack(DB, 'demo');
    assert.deepEqual([again.status, again.body.acked], [200, 0]);
  });

  await t.test('W6 the threshold row: abc, 0, 1441 and no row use 10; " 15 " is 15', async () => {
    const { db, DB } = await fresh();
    for (const v of ['abc', '0', '1441', '']) {
      setting(db, 'lane_run.wait_alert_min', v);
      const r = await tick(DB);
      assert.deepEqual([r.body.threshold_min, r.body.threshold_source], [10, 'default'], JSON.stringify(v));
    }
    db.prepare("DELETE FROM settings WHERE key='lane_run.wait_alert_min'").run();
    assert.equal((await tick(DB)).body.threshold_min, 10);
    setting(db, 'lane_run.wait_alert_min', ' 15 ');
    const r = await tick(DB);
    assert.deepEqual([r.body.threshold_min, r.body.threshold_source], [15, 'settings']);
    // A 300 s wait is under both 15 min and the default 10 min; a threshold of
    // 0 (were it used) would put it over.
    seed(db, { status: 'queued', enq: 300 });
    assert.deepEqual((await tick(DB)).body.over, []);
    setting(db, 'lane_run.wait_alert_min', '0');
    assert.deepEqual((await tick(DB)).body.over, [], 'threshold 0 is never used');
  });

  await t.test('W7 a fired breach that drains resolves once and deletes its row', async () => {
    const { db, DB } = await fresh();
    const id = seed(db, { status: 'queued', enq: 900 });
    await tick(DB);
    assert.equal((await tick(DB)).body.fire.length, 1);
    await ack(DB, 'demo');
    db.prepare("UPDATE lane_runs SET status='claimed', claimed_at=?, claimed_by='m1' WHERE id=?").run(ago(1), id);
    const r = await tick(DB);
    assert.deepEqual(r.body.resolve, ['demo']);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM lane_run_wait_alerts').get().n, 0);
    assert.deepEqual((await tick(DB)).body.resolve, [], 'resolved once');
    // A breach that never fired drains silently.
    seed(db, { status: 'queued', enq: 900, project: 'p9' });
    await tick(DB);
    db.prepare("UPDATE lane_runs SET status='died' WHERE project='p9'").run();
    assert.deepEqual((await tick(DB)).body.resolve, []);
  });

  await t.test('W7b a fired breach whose ack was lost still resolves when it drains', async () => {
    const { db, DB } = await fresh();
    const id = seed(db, { status: 'queued', enq: 900 });
    await tick(DB);
    assert.equal((await tick(DB)).body.fire.length, 1);
    // No ack: the "send OK, ack failed" path. alerted_at stays NULL.
    assert.equal(db.prepare('SELECT alerted_at FROM lane_run_wait_alerts WHERE lane=?').get('demo').alerted_at, null);
    db.prepare("UPDATE lane_runs SET status='claimed', claimed_at=?, claimed_by='m1' WHERE id=?").run(ago(1), id);
    const r = await tick(DB);
    assert.deepEqual(r.body.resolve, ['demo'], 'the open alert id is closed');
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM lane_run_wait_alerts').get().n, 0);
    assert.deepEqual((await tick(DB)).body.resolve, [], 'resolved once');
    // The pure rule: a 1-tick row without ack does not resolve; a 2-tick row does.
    const d = waitDecision([], [{ lane: 'x', over_ticks: 1, alerted_at: null }, { lane: 'y', over_ticks: 2, alerted_at: null }], 600);
    assert.deepEqual(d.resolve, ['y']);
  });

  await t.test('W8 no lane_runs table is 503 lane_runs schema not applied', async () => {
    const { db, DB } = await fresh();
    db.exec('DROP TABLE lane_runs');
    for (const [m, p] of [['POST', '/api/lane-runs/wait-tick'], ['GET', '/api/lane-runs/metrics'], ['GET', '/api/lane-runs'], ['GET', '/api/lane-runs/1']]) {
      const r = await call(DB, m, p, m === 'POST' ? {} : undefined);
      assert.equal(r.status, 503, p);
      assert.equal(r.body.error, 'lane_runs schema not applied', p);
    }
  });

  await t.test('W9 the hub load row: a bad box or load1 is skipped and the tick still counts', async () => {
    const { db, DB } = await fresh();
    seed(db, { status: 'queued', enq: 900 });
    for (const b of [{ box: 'hub', load1: -1 }, { box: 'hub', load1: 'x' }, { box: 'a b', load1: 1 }, {}]) {
      assert.equal((await tick(DB, b)).body.hub_load, 'skipped', JSON.stringify(b));
    }
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM lane_run_hub_load').get().n, 0);
    assert.equal(db.prepare("SELECT over_ticks FROM lane_run_wait_alerts WHERE lane='demo'").get().over_ticks, 4);
  });

  await t.test('C0 the console fixture has every key the routes answer (the view reads no shape the route cannot make)', async () => {
    if (!existsSync(CONSOLE_FIXTURE)) assert.fail(`missing ${CONSOLE_FIXTURE}`);
    const fx = JSON.parse(readFileSync(CONSOLE_FIXTURE, 'utf8'));
    const { db, DB } = await fresh();
    const ids = seedDemo(db);
    await tick(DB, { box: 'hub', load1: 0.42 });
    const metrics = (await call(DB, 'GET', '/api/lane-runs/metrics')).body;
    const list = (await call(DB, 'GET', '/api/lane-runs?lane=demo')).body;
    const run = (await call(DB, 'GET', `/api/lane-runs/${ids.done1}`)).body;
    const keys = (o) => Object.keys(o).sort();
    assert.deepEqual(keys(fx.metrics), keys(metrics));
    assert.deepEqual(keys(fx.metrics.lanes[0]), keys(metrics.lanes[0]));
    assert.deepEqual(keys(fx.metrics.machines[0]), keys(metrics.machines[0]));
    assert.deepEqual(keys(fx.metrics.hub), keys(metrics.hub));
    assert.deepEqual(keys(fx.list), keys(list));
    assert.deepEqual(keys(fx.list.runs[0]), keys(list.runs[0]));
    assert.deepEqual(keys(fx.run.run), keys(run.run));
  });
});
