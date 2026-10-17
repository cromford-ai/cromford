// BH-6877: the Fly idle reaper's destroy rows, their retention with the daily
// rollup, and the last-work fields of the started-machine snapshot.
// Driven through the REAL router (worker.fetch) against the composed jobs
// schema on the node:sqlite shim (the fly-idle.bh-6061 harness).
//
//   W1 the reaper fixture (fixtures/fly-idle-destroy.bh-6877.json, the body
//      bin/fly-idle-reaper.sh POSTs) inserts once; a replay is ignored; GET
//      returns it in destroys with usd_per_hour, destroys_24h = 1
//   W2 a bad row is 400 and nothing is written
//   W3 50,000 seeded rows: the 24 h reads and the retention id read use
//      fly_idle_destroys_destroyed_at; no full SCAN of fly_idle_destroys
//   W4 a live retention run removes stop and destroy rows past 400 days and
//      adds their counts and $/h sums to fly_idle_daily; newer rows stay
//   W5 a PUT with last_work_at and no_claim reads back; an old body without
//      them still works and reads back null
//   W6 round trips of one GET (lead review BLOCK on 83ca230c): the two destroy
//      reads are ONE env.DB.batch, and no read of the GET waits for another
//      (5 trips, all 5 in flight together); with fly_idle_destroys missing the
//      batch still fails soft
//
// The GET clock is the fixture's destroyed_at + 1 h (Date.now is stubbed), so
// the 24 h window never depends on the wall clock.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import * as flyIdleRoutes from '../src/routes/fly-idle.js';
import { RULES } from '../src/routes/retention.js';

const HARNESS = 'fixture-harness-secret';
const FIXTURE = JSON.parse(readFileSync(new URL('./fixtures/fly-idle-destroy.bh-6877.json', import.meta.url), 'utf8'));
const DESTROY = FIXTURE.rows[0];
const STOP = JSON.parse(readFileSync(new URL('./fixtures/fly-idle-stop.bh-6061.json', import.meta.url), 'utf8')).rows[0];
const NOW_MS = Date.parse(DESTROY.destroyed_at) + 3600 * 1000;
const isoAt = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const daysAgo = (d) => isoAt(NOW_MS - d * 86400e3);
// The retention route cuts its window off the server clock (new Date(), which
// the Date.now stub does not reach), so W4 seeds offsets from the real clock.
const REAL_MS = Date.now();  // determinism: ok the retention anchor; every W4 time is an offset from it
const realDaysAgo = (d) => isoAt(REAL_MS - d * 86400e3);

const call = (DB, method, path, body, auth = HARNESS) => {
  const headers = { 'content-type': 'application/json' };
  if (auth !== null) headers.authorization = `Bearer ${auth}`;
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: HARNESS })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const postDestroys = (DB, body) => call(DB, 'POST', '/api/fly-idle/destroys', body);
const postStops = (DB, body) => call(DB, 'POST', '/api/fly-idle/stops', body);
const putSnap = (DB, body) => call(DB, 'PUT', '/api/fly-idle/machines', body);
const getIdle = (DB) => call(DB, 'GET', '/api/fly-idle');
const count = (db, sql) => db.prepare(sql).get().n;

// A destroy row of the reaper's shape at `iso`.
const destroyAt = (mid, iso, o = {}) => ({
  ...DESTROY, machine_id: mid, destroy_id: `${mid}-${Math.floor(Date.parse(iso) / 1000)}`, destroyed_at: iso, ...o,
});
const stopAt = (mid, iso, o = {}) => ({
  ...STOP, machine_id: mid, stop_id: `${mid}-${Math.floor(Date.parse(iso) / 1000)}`, stopped_at: iso, ...o,
});
const snapRow = (mid, o = {}) => ({
  app: 'lane-run-cromford', machine_id: mid, size: 'shared-cpu-2x', source: 'lane-run',
  idle_s: 120, idle_state: 'idle', threshold_s: 900, usd_per_hour: 0.02, ...o,
});
const snap = (rows) => ({ pass_at: isoAt(NOW_MS), apps_total: 2, apps_failed: 0, box: 'fixture', rows });

async function fresh(t) {
  const h = await openDb();
  if (h === null) t.skip('node:sqlite unavailable in this runtime');
  return h;
}

test('BH-6877 fly idle destroys', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  const realNow = Date.now;
  Date.now = () => NOW_MS;
  t.after(() => { Date.now = realNow; });

  await t.test('W0 the schema seeds the BH-6877 settings rows', () => {
    const val = (k) => {
      const r = probe.db.prepare('SELECT value FROM settings WHERE key = ?').get(k);
      return r ? r.value : null;
    };
    const want = {
      'fly.no_claim_alert_s': '600', 'fly.probe_busy_cpu_pct': '5', 'fly.metrics_idle_cpu_pct': '2',
      'fly.metrics_idle_net_bps': '2048', 'fly.destroy_after_stopped_s': '604800', 'fly.destroy_max_per_pass': '10',
      'fly.destroy_enabled': '1', 'retention.fly_idle_stops.days': '400', 'retention.fly_idle_destroys.days': '400',
    };
    for (const [k, v] of Object.entries(want)) assert.equal(val(k), v, k);
  });

  await t.test('W1 the reaper fixture inserts once; GET returns it with its $/h', async (tt) => {
    const { db, DB } = await fresh(tt);
    const a = await postDestroys(DB, FIXTURE);
    assert.equal(a.status, 200, JSON.stringify(a.body));
    assert.equal(a.body.inserted, 1);
    assert.equal(a.body.ignored, 0);
    const b = await postDestroys(DB, FIXTURE);
    assert.equal(b.status, 200, JSON.stringify(b.body));
    assert.equal(b.body.inserted, 0);
    assert.equal(b.body.ignored, 1);
    assert.equal(count(db, 'SELECT COUNT(*) AS n FROM fly_idle_destroys'), 1);
    assert.equal((await call(DB, 'POST', '/api/fly-idle/destroys', FIXTURE, null)).status, 401, 'the bearer guards the route');

    // One more priced row in the window, one unpriced, one 25 h old.
    const recent = destroyAt('1f1d000000b3', isoAt(NOW_MS - 2 * 3600e3), { usd_per_hour: 0.1 });
    const unpriced = destroyAt('1f1d000000b4', isoAt(NOW_MS - 3 * 3600e3), { usd_per_hour: null, size: null, box: null });
    const old = destroyAt('1f1d000000b5', isoAt(NOW_MS - 25 * 3600e3));
    const p = await postDestroys(DB, { rows: [recent, unpriced, old] });
    assert.equal(p.status, 200, JSON.stringify(p.body));
    assert.equal(p.body.inserted, 3);

    const g = await getIdle(DB);
    assert.equal(g.status, 200, JSON.stringify(g.body));
    const d0 = g.body.destroys[0];
    for (const k of Object.keys(DESTROY)) assert.equal(d0[k], DESTROY[k], `destroys[0].${k}`);
    assert.equal(typeof d0.usd_per_hour, 'number');
    assert.equal(typeof d0.stopped_s, 'number');
    assert.deepEqual(g.body.destroys.map((d) => d.machine_id), [DESTROY.machine_id, recent.machine_id, unpriced.machine_id],
      'newest first; the 25 h row is out of the window');
    assert.equal(g.body.destroys[2].usd_per_hour, null, 'an unpriced row stays null, never 0');
    assert.equal(g.body.destroys_24h, 3);
    assert.ok(Math.abs(g.body.destroy_usd_per_hour_24h - (DESTROY.usd_per_hour + 0.1)) < 1e-9, 'only priced rows add');
    assert.equal(g.body.stops_24h, 0, 'the stop fields stay');
  });

  await t.test('W1b with no destroy row the GET answers an empty list and zero sums', async (tt) => {
    const { DB } = await fresh(tt);
    const g = await getIdle(DB);
    assert.equal(g.status, 200, JSON.stringify(g.body));
    assert.deepEqual(g.body.destroys, []);
    assert.equal(g.body.destroys_24h, 0);
    assert.equal(g.body.destroy_usd_per_hour_24h, 0);
  });

  await t.test('W1c the GET still answers the stop half when fly_idle_destroys is missing', async (tt) => {
    const { db, DB } = await fresh(tt);
    assert.equal((await postStops(DB, { rows: [STOP] })).status, 200);
    db.exec('DROP TABLE fly_idle_destroys');
    const g = await getIdle(DB);
    assert.equal(g.status, 200, JSON.stringify(g.body));
    assert.equal(g.body.stops_24h, 1);
    assert.equal(g.body.destroys, null, 'a missing table is not an empty list');
    assert.equal(g.body.destroys_24h, null);
    assert.match(g.body.destroys_error, /fly_idle_destroys schema not applied/);
    const p = await postDestroys(DB, FIXTURE);
    assert.equal(p.status, 503, 'the POST answers 503, never a silent success');
  });

  await t.test('W2 a bad row answers 400 and writes nothing', async (tt) => {
    const { db, DB } = await fresh(tt);
    const cases = [
      ['machine id ../x', { rows: [{ ...DESTROY, machine_id: '../x' }] }],
      ['uppercase machine id', { rows: [{ ...DESTROY, machine_id: '1F1D000000A2', destroy_id: '1F1D000000A2-1791700000' }] }],
      ['destroy_id of another machine', { rows: [{ ...DESTROY, destroy_id: 'abcdef123456-1791700000' }] }],
      ['destroy_id epoch of 8 digits', { rows: [{ ...DESTROY, destroy_id: '1f1d000000a2-17917000' }] }],
      ['uppercase app', { rows: [{ ...DESTROY, app: 'Pool-Board' }] }],
      ['bad source', { rows: [{ ...DESTROY, source: 'Pool!' }] }],
      ['negative stopped_s', { rows: [{ ...DESTROY, stopped_s: -1 }] }],
      ['fractional stopped_s', { rows: [{ ...DESTROY, stopped_s: 1.5 }] }],
      ['negative usd', { rows: [{ ...DESTROY, usd_per_hour: -0.1 }] }],
      ['kind stop', { rows: [{ ...DESTROY, kind: 'stop' }] }],
      ['status destroyed', { rows: [{ ...DESTROY, status: 'destroyed' }] }],
      ['bad box', { rows: [{ ...DESTROY, box: 'a b' }] }],
      ['destroyed_at not UTC', { rows: [{ ...DESTROY, destroyed_at: '2026-10-11 06:26:40' }] }],
      ['no rows', { rows: [] }],
      ['51 rows', { rows: Array.from({ length: 51 }, (_, i) => destroyAt(`0b0d${String(i).padStart(8, '0')}`, daysAgo(0.01))) }],
      ['one bad row of two', { rows: [destroyAt('0c0d00000001', daysAgo(0.01)), { ...DESTROY, machine_id: 'zz' }] }],
    ];
    for (const [name, body] of cases) {
      const r = await postDestroys(DB, body);
      assert.equal(r.status, 400, `${name}: ${JSON.stringify(r.body)}`);
    }
    assert.equal(count(db, 'SELECT COUNT(*) AS n FROM fly_idle_destroys'), 0);
    const fifty = await postDestroys(DB, { rows: Array.from({ length: 50 }, (_, i) => destroyAt(`0d0d${String(i).padStart(8, '0')}`, daysAgo(0.01))) });
    assert.equal(fifty.status, 200, JSON.stringify(fifty.body));
    assert.equal(fifty.body.inserted, 50, '50 rows is the cap, and it spans several chunks');
  });

  await t.test('W3 at 50,000 rows the 24 h reads and the retention id read use the destroyed_at index', async (tt) => {
    const { db } = await fresh(tt);
    const PER = 500;
    for (let b = 0; b < 100; b += 1) {
      const vals = [];
      for (let i = 0; i < PER; i += 1) {
        const n = b * PER + i;
        const mid = n.toString(16).padStart(12, '0');
        const ts = isoAt(NOW_MS - n * 600e3);
        vals.push(`('${mid}-${Math.floor(Date.parse(ts) / 1000)}','pool-cromford','${mid}','performance-16x','pool',691200,0.5,'destroy','requested','fixture','${ts}')`);
      }
      db.exec('INSERT INTO fly_idle_destroys (destroy_id, app, machine_id, size, source, stopped_s, usd_per_hour, kind, status, box, destroyed_at) VALUES '
        + vals.join(','));
    }
    assert.equal(count(db, 'SELECT COUNT(*) AS n FROM fly_idle_destroys'), 50000);
    const rule = RULES.find((r) => r.rule === 'fly_idle_destroys.age');
    assert.ok(rule, 'a retention rule for fly_idle_destroys exists');
    const plans = [
      ['24 h list', flyIdleRoutes.DESTROYS_24H_SQL, [daysAgo(1), 200]],
      ['24 h sums', flyIdleRoutes.DESTROYS_AGG_SQL, [daysAgo(1)]],
      ['retention ids', rule.ids, [daysAgo(400), 500]],
    ];
    for (const [name, sql, binds] of plans) {
      const lines = db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((x) => x.detail);
      assert.ok(lines.some((l) => /fly_idle_destroys USING (COVERING )?INDEX fly_idle_destroys_destroyed_at/.test(l)),
        `${name}: ${lines.join(' | ')}`);
      assert.ok(!lines.some((l) => /^SCAN fly_idle_destroys\b/.test(l) && !/USING (COVERING )?INDEX/.test(l)),
        `${name} scans the table: ${lines.join(' | ')}`);
      assert.ok(!lines.some((l) => /USE TEMP B-TREE FOR ORDER BY/.test(l)), `${name} sorts outside the index: ${lines.join(' | ')}`);
    }
  });

  await t.test('W4 a live retention run archives old stop and destroy rows into fly_idle_daily', async (tt) => {
    const { db, DB } = await fresh(tt);
    db.prepare("UPDATE settings SET value = '0' WHERE key = 'retention.dry_run'").run();
    const oldDay = realDaysAgo(401).slice(0, 10);
    const d401 = realDaysAgo(401);
    const d410 = realDaysAgo(410);
    const r1 = await postDestroys(DB, { rows: [
      destroyAt('2a0000000001', d401, { usd_per_hour: 0.5 }),
      destroyAt('2a0000000002', d401, { usd_per_hour: 0.25 }),
      destroyAt('2a0000000003', d401, { usd_per_hour: null }),
      destroyAt('2a0000000004', d410, { app: 'builder-cromford', usd_per_hour: 1 }),
      destroyAt('2a0000000005', realDaysAgo(399), { usd_per_hour: 2 }),
    ] });
    assert.equal(r1.status, 200, JSON.stringify(r1.body));
    const r2 = await postStops(DB, { rows: [
      stopAt('3a0000000001', d401, { usd_per_hour: 0.125 }),
      stopAt('3a0000000002', d401, { usd_per_hour: 0.125 }),
      stopAt('3a0000000003', realDaysAgo(10), { usd_per_hour: 4 }),
    ] });
    assert.equal(r2.status, 200, JSON.stringify(r2.body));

    const run = await call(DB, 'POST', '/api/retention/run', {});
    assert.equal(run.status, 200, JSON.stringify(run.body));
    assert.equal(run.body.dry_run, false);
    const rd = run.body.rules.find((r) => r.rule === 'fly_idle_destroys.age');
    const rs = run.body.rules.find((r) => r.rule === 'fly_idle_stops.age');
    assert.equal(rd.error, null);
    assert.equal(rd.removed, 4);
    assert.equal(rs.error, null);
    assert.equal(rs.removed, 2);

    assert.deepEqual(db.prepare('SELECT machine_id FROM fly_idle_destroys').all().map((r) => r.machine_id), ['2a0000000005']);
    assert.deepEqual(db.prepare('SELECT machine_id FROM fly_idle_stops').all().map((r) => r.machine_id), ['3a0000000003']);
    const daily = db.prepare('SELECT day, app, action, n, usd_per_hour_sum FROM fly_idle_daily ORDER BY day, app, action').all()
      .map((r) => ({ ...r }));
    assert.deepEqual(daily, [
      { day: d410.slice(0, 10), app: 'builder-cromford', action: 'destroy', n: 1, usd_per_hour_sum: 1 },
      { day: oldDay, app: 'pool-cromford', action: 'destroy', n: 3, usd_per_hour_sum: 0.75 },
      { day: oldDay, app: 'pool-cromford', action: 'stop', n: 2, usd_per_hour_sum: 0.25 },
    ]);

    // A second batch for the same day adds to the row; it never replaces it.
    assert.equal((await postDestroys(DB, { rows: [destroyAt('2a0000000006', d401, { usd_per_hour: 0.5 })] })).status, 200);
    assert.equal((await call(DB, 'POST', '/api/retention/run', {})).status, 200);
    const again = db.prepare("SELECT n, usd_per_hour_sum FROM fly_idle_daily WHERE day = ? AND app = 'pool-cromford' AND action = 'destroy'").get(oldDay);
    assert.equal(again.n, 4);
    assert.equal(again.usd_per_hour_sum, 1.25);
  });

  await t.test('W4b the seeded dry run counts the old rows and removes none', async (tt) => {
    const { db, DB } = await fresh(tt);
    assert.equal((await postDestroys(DB, { rows: [destroyAt('2b0000000001', realDaysAgo(401))] })).status, 200);
    const run = await call(DB, 'POST', '/api/retention/run', {});
    assert.equal(run.status, 200, JSON.stringify(run.body));
    assert.equal(run.body.rules.find((r) => r.rule === 'fly_idle_destroys.age').counted, 1);
    assert.equal(count(db, 'SELECT COUNT(*) AS n FROM fly_idle_destroys'), 1);
    assert.equal(count(db, 'SELECT COUNT(*) AS n FROM fly_idle_daily'), 0);
  });

  await t.test('W5 last_work_at and no_claim read back; an old body still works', async (tt) => {
    const { DB } = await fresh(tt);
    const lw = isoAt(NOW_MS - 300e3);
    const a = await putSnap(DB, snap([
      snapRow('4a0000000001', { last_work_at: lw, no_claim: false }),
      snapRow('4a0000000002', { idle_s: 60, last_work_at: null, no_claim: true }),
      snapRow('4a0000000003', { idle_s: 30 }),
    ]));
    assert.equal(a.status, 200, JSON.stringify(a.body));
    const g = (await getIdle(DB)).body;
    const by = Object.fromEntries(g.machines.map((m) => [m.machine_id, m]));
    assert.equal(by['4a0000000001'].last_work_at, lw);
    assert.equal(by['4a0000000001'].no_claim, false);
    assert.equal(by['4a0000000002'].last_work_at, null);
    assert.equal(by['4a0000000002'].no_claim, true);
    assert.equal(by['4a0000000003'].last_work_at, null, 'absent is null');
    assert.equal(by['4a0000000003'].no_claim, null, 'absent is null, never false');

    for (const [name, o] of [
      ['last_work_at not UTC', { last_work_at: '2026-10-11 06:00:00' }],
      ['last_work_at a number', { last_work_at: 1791700000 }],
      ['no_claim a string', { no_claim: 'yes' }],
      ['no_claim 1', { no_claim: 1 }],
    ]) {
      const r = await putSnap(DB, snap([snapRow('4a0000000009', o)]));
      assert.equal(r.status, 400, `${name}: ${JSON.stringify(r.body)}`);
    }
    assert.equal((await getIdle(DB)).body.machines.length, 3, 'a refused PUT leaves the snapshot');
  });
  // W6: a DB wrapper that counts round trips (one per first/all/run outside a
  // batch, one per batch) and the most trips in flight at once. Each trip
  // waits a little before it runs, so a read that waits for another shows up
  // as a lower in-flight peak.
  const counted = (DB) => {
    const trips = [];
    let inflight = 0; let peak = 0;
    const trip = async (kind, sql, fn) => {
      inflight += 1; peak = Math.max(peak, inflight); trips.push({ kind, sql });
      try { await new Promise((r) => setTimeout(r, 5)); return await fn(); } finally { inflight -= 1; }
    };
    const wrap = {
      prepare(sql) {
        const inner = DB.prepare(sql);
        const w = {
          _inner: inner, _sql: sql, _isRead: inner._isRead,
          bind(...v) { inner.bind(...v); return w; },
          first(c) { return trip('first', sql, () => inner.first(c)); },
          all() { return trip('all', sql, () => inner.all()); },
          run() { return trip('run', sql, () => inner.run()); },
        };
        return w;
      },
      batch(stmts) { return trip('batch', stmts.map((x) => x._sql).join(' ;; '), () => DB.batch(stmts.map((x) => x._inner))); },
    };
    return { DB: wrap, trips, peak: () => peak };
  };
  const getTrips = (c) => c.trips.filter((x) => !/^\s*(PRAGMA|ALTER|CREATE)\b/i.test(x.sql));

  await t.test('W6 one GET: the destroy reads are one batch, and no read waits for another', async (tt) => {
    const { DB } = await fresh(tt);
    assert.equal((await postDestroys(DB, FIXTURE)).status, 200);
    assert.equal((await postStops(DB, { rows: [STOP] })).status, 200);
    await getIdle(DB); // ensureColumns runs once per DB; its PRAGMA is not this GET's cost
    const c = counted(DB);
    const g = await getIdle(c.DB);
    assert.equal(g.status, 200, JSON.stringify(g.body));
    assert.equal(g.body.destroys_24h, 1);
    assert.equal(g.body.stops_24h, 1);
    const trips = getTrips(c);
    const onDestroys = trips.filter((x) => /fly_idle_destroys/.test(x.sql));
    assert.equal(onDestroys.length, 1, `one trip reads fly_idle_destroys: ${JSON.stringify(onDestroys)}`);
    assert.equal(onDestroys[0].kind, 'batch', 'the destroy reads go in one env.DB.batch');
    assert.ok(onDestroys[0].sql.includes(flyIdleRoutes.DESTROYS_24H_SQL) && onDestroys[0].sql.includes(flyIdleRoutes.DESTROYS_AGG_SQL),
      'the batch holds both destroy reads');
    assert.equal(trips.length, 5, `5 round trips: pass, machines, stops, stop sums, the destroy batch: ${JSON.stringify(trips.map((x) => x.kind))}`);
    assert.equal(c.peak(), 5, 'the 5 independent reads are in flight together');
  });

  await t.test('W6b the destroy batch fails soft when fly_idle_destroys is missing', async (tt) => {
    const { db, DB } = await fresh(tt);
    db.exec('DROP TABLE fly_idle_destroys');
    const c = counted(DB);
    const g = await getIdle(c.DB);
    assert.equal(g.status, 200, JSON.stringify(g.body));
    assert.equal(g.body.destroys, null);
    assert.match(g.body.destroys_error, /fly_idle_destroys schema not applied/);
    // (The node:sqlite shim throws in prepare() for a missing table, before the
    // batch is sent; D1 fails in the batch. Either way the catch answers.)
    assert.equal(g.body.stops_24h, 0, 'the stop half still answers');
    assert.ok(getTrips(c).filter((x) => /fly_idle_destroys/.test(x.sql)).length <= 1, 'at most one destroy trip');
  });
});
