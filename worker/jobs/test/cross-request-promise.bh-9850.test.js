// BH-9850: no pending Promise is shared across requests in the jobs worker.
//
// Sentry CROMFORD-HARNESS-26: "This promise was created by a request that has
// since ended", stack ending in d1OverloadGuarded. Three per-isolate caches
// kept a PENDING Promise in module state and gave it to every later request:
// ensureTable, ensureColumns (lib/core.js) and settingsRows
// (lib/settings-cache.js). A request that awaited another request's promise
// hung forever when that request was cancelled, and in workerd raised the
// cross-request error when either request ended first. They now keep plain
// slots (lib/isolate-flight.js): a request that finds a run in flight polls
// the slot on its own timer, and runs its own work when the poll budget ends.
//
//   F1  settings: request 1's read never settles; request 2 answers on its own
//   F2  worker.fetch GET /api/flags/<ported>: request 1 hangs in the
//       harness_flags create; request 2 answers 200 with its own body
//   F3  10 concurrent GETs under D1 overload: none rejects, each 200 or 503
//   F4  no slot value in the three caches is a thenable
//   F5  isolateFlight: a rejected run rejects its waiters; not final; a final
//       success runs nothing
//   F6  detachFlight: an old waiter gets the old run; a new caller runs again
//   F7  the composed schema seeds both knob rows at the code fallbacks
//   F8  flightKnobs refuses bad values; wait 0 = no join; a frozen Date
//       does not make the poll endless
//   F9  static: the shared-promise shapes are gone from the source
//
// Each test opens its own node:sqlite D1 (or its own stub) and its own unique
// keys, so no test shares data with another. Imports of the new module are
// dynamic, so F1-F4 run (and fail) against the code before the fix.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import * as settingsCache from '../src/lib/settings-cache.js';
import { createdTablesReady, addedColumnsReady, ensureColumns } from '../src/lib/core.js';
import SCHEMA_SQL from '#schema-sql';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { isEnsureTableBatch, runOneByOne } from './lib/ensure-batch.bh-9657.js';

const flight = () => import('../src/lib/isolate-flight.js');

const SECRET = 'tok-fixture-bh9850';
const FULL_READ = /^SELECT \* FROM settings ORDER BY key ASC$/;
const OVERLOAD = 'D1_ERROR: D1 DB is overloaded. Requests queued for too long.';

let seq = 0;
const uniq = (tag) => `bh9850-${tag}-${process.pid}-${++seq}`;
const never = () => new Promise(() => {});
const isThenable = (v) => v !== null && (typeof v === 'object' || typeof v === 'function') && typeof v.then === 'function';

async function fresh(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', '2026-11-20T00:00:00Z');
}
function flagRow(db, name, value) {
  db.prepare(`INSERT INTO harness_flags (scope,name,value,set_by,reason,set_at,cleared_at) VALUES ('fleet',?,?,'test','fixture','2026-11-20T00:00:00Z',NULL)`).run(name, value);
}

// A D1 binding over the node:sqlite shim. It logs every statement.
//   hang.reads / hang.batches: the next N full settings reads / ensureTable
//     batches never settle (the request that sent them is "cancelled").
//   overload: the next N statement executions throw the D1 overload error.
function binding(DB, opts = {}) {
  const log = [];
  const state = { hangReads: opts.hangReads || 0, hangBatches: opts.hangBatches || 0, overload: opts.overload || 0 };
  const exec = async (entry, fn) => {
    log.push(entry);
    if (state.overload > 0) { state.overload--; throw new Error(OVERLOAD); }
    return fn();
  };
  const wrap = (s, sql) => {
    const api = {
      _raw: s, _sql: sql,
      bind(...v) { s.bind(...v); return api; },
      first(c) { return exec({ op: 'first', sql }, () => s.first(c)); },
      all() {
        if (state.hangReads > 0 && FULL_READ.test(sql)) { state.hangReads--; log.push({ op: 'all', sql, hung: true }); return never(); }
        return exec({ op: 'all', sql }, () => s.all());
      },
      run() { return exec({ op: 'run', sql }, () => s.run()); },
    };
    return api;
  };
  return {
    log, state,
    prepare(sql) { return wrap(DB.prepare(sql), sql); },
    batch(stmts) {
      if (isEnsureTableBatch(stmts) && state.hangBatches > 0) { state.hangBatches--; log.push({ op: 'batch', hung: true }); return never(); }
      return exec({ op: 'batch', n: stmts.length }, () => (isEnsureTableBatch(stmts) ? runOneByOne(stmts) : DB.batch(stmts.map((x) => x._raw))));
    },
  };
}
const fullReads = (log) => log.filter((e) => e.op === 'all' && FULL_READ.test(e.sql)).length;
class Ctx {
  constructor() { this.waits = []; }
  waitUntil(p) { this.waits.push(Promise.resolve(p).catch(() => {})); }
  passThroughOnException() {}
}
const get = (env, path) => worker.fetch(new Request(`https://jobs.test${path}`, { headers: { authorization: `Bearer ${SECRET}` } }), env, new Ctx());

// Every slot value the three caches hold for `db`, as [where, value].
function slotValues(db) {
  const out = [];
  for (const [name, wm] of [['createdTablesReady', createdTablesReady], ['addedColumnsReady', addedColumnsReady]]) {
    const per = wm.get(db);
    if (per) for (const [k, v] of per) out.push([`${name}.${k}`, v]);
  }
  const flights = settingsCache.settingsFlights;
  assert.ok(flights instanceof WeakMap, 'settings-cache.js exports settingsFlights (its plain slots)');
  const per = flights.get(db);
  if (per) for (const [k, v] of per) out.push([`settingsFlights.${k}`, v]);
  return out;
}

test('F1 settings: request 1 read never settles; request 2 on the same binding answers on its own read', async (t) => {
  const o = await fresh(t); if (!o) return;
  const key = uniq('f1');
  setting(o.db, key, 'v-f1');
  const DB = binding(o.DB, { hangReads: 1 });
  const env = { DB, SETTINGS_CACHE_TTL_S: '30' };
  settingsCache.settingsRows(env); // request 1: cancelled mid-read, never settles
  const snap = await settingsCache.settingsRows(env); // request 2
  assert.equal(snap.byKey.get(key) && snap.byKey.get(key).value, 'v-f1');
  assert.equal(fullReads(DB.log), 2, 'request 2 ran its own read after the poll budget');
});

test('F2 worker.fetch GET /api/flags/<ported>: request 1 hangs in the create; request 2 answers 200 with its own body', async (t) => {
  const o = await fresh(t); if (!o) return;
  const name = `paused-${uniq('f2')}`;
  flagRow(o.db, name, 'v-f2');
  const DB = binding(o.DB, { hangBatches: 1 });
  const env = { DB, HARNESS_SECRET: SECRET };
  get(env, `/api/flags/${name}`); // request 1: never answers
  const res = await get(env, `/api/flags/${name}`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.flag && body.flag.name, name);
  assert.equal(DB.log.filter((e) => e.op === 'batch').length, 2, 'request 2 sent its own create batch');
});

test('F3 10 concurrent GET /api/flags/<ported> under D1 overload: none rejects; each answers 200 or 503', async (t) => {
  const o = await fresh(t); if (!o) return;
  const name = `paused-${uniq('f3')}`;
  flagRow(o.db, name, 'v-f3');
  const DB = binding(o.DB, { overload: 5 }); // the first create gives up after 5 attempts
  const env = { DB, HARNESS_SECRET: SECRET };
  const warn = console.warn;
  console.warn = () => {};
  let settled;
  try {
    settled = await Promise.allSettled(Array.from({ length: 10 }, () => get(env, `/api/flags/${name}`)));
  } finally {
    console.warn = warn;
  }
  const rejected = settled.filter((s) => s.status === 'rejected');
  assert.deepEqual(rejected.map((s) => String(s.reason)), [], 'no request rejects');
  const res = settled.map((s) => s.value);
  assert.equal(new Set(res).size, 10, 'each request has its own Response');
  for (const r of res) {
    assert.ok(r instanceof Response);
    assert.ok(r.status === 200 || r.status === 503, `status ${r.status}`);
    const body = await r.json();
    if (r.status === 503) {
      assert.equal(body.retryable, true);
      assert.ok(Number.isInteger(body.d1_attempts), JSON.stringify(body));
    } else {
      assert.equal(body.flag.name, name);
    }
  }
});

test('F4 after cross-request traffic, no slot in createdTablesReady, addedColumnsReady or the settings flights is a thenable', async (t) => {
  const o = await fresh(t); if (!o) return;
  const name = `paused-${uniq('f4')}`;
  flagRow(o.db, name, 'v-f4');
  const DB = binding(o.DB, { hangBatches: 1, hangReads: 1 });
  const env = { DB, HARNESS_SECRET: SECRET, SETTINGS_CACHE_TTL_S: '30' };
  get(env, `/api/flags/${name}`); // request 1 hangs in the create
  settingsCache.settingsRows(env); // a settings read that hangs
  assert.equal((await get(env, `/api/flags/${name}`)).status, 200);
  await ensureColumns(env, 'pause_flags');
  await settingsCache.settingsRows(env);
  const vals = slotValues(DB);
  assert.ok(vals.some(([w]) => w === 'createdTablesReady.harness_flags'), vals.map(([w]) => w).join(','));
  assert.ok(vals.some(([w]) => w === 'addedColumnsReady.pause_flags'), vals.map(([w]) => w).join(','));
  assert.ok(vals.some(([w]) => w.startsWith('settingsFlights.')), vals.map(([w]) => w).join(','));
  for (const [where, v] of vals) {
    assert.ok(!isThenable(v), `${where} holds a thenable`);
    for (const [k, inner] of Object.entries(v)) assert.ok(!isThenable(inner), `${where}.${k} holds a thenable`);
    if (v.done) assert.ok(!isThenable(v.done.value) && !isThenable(v.done.error), `${where}.done holds a thenable`);
  }
});

test('F5 isolateFlight: a rejected run rejects every waiter; a failure is not final; a final success runs nothing', async () => {
  const { isolateFlight } = await flight();
  const slots = new Map();
  let runs = 0;
  let fail;
  const failing = () => { runs++; return new Promise((_, rej) => { fail = rej; }); };
  const opts = { waitMs: 2000, pollMs: 5, final: true };
  const a = isolateFlight(slots, 'k', failing, opts);
  const b = isolateFlight(slots, 'k', failing, opts);
  const err = new Error('boom-f5');
  setTimeout(() => fail(err), 20);
  const got = await Promise.allSettled([a, b]);
  assert.deepEqual(got.map((g) => g.status), ['rejected', 'rejected']);
  assert.equal(got[0].reason, err);
  assert.equal(got[1].reason, err, 'the waiter rethrows the run\'s own error object');
  assert.equal(runs, 1, 'the waiter joined the run');
  assert.equal(await isolateFlight(slots, 'k', async () => { runs++; return 'ok'; }, opts), 'ok');
  assert.equal(runs, 2, 'a failed final run is retried by the next caller');
  assert.equal(await isolateFlight(slots, 'k', async () => { runs++; return 'again'; }, opts), 'ok');
  assert.equal(runs, 2, 'a final success runs nothing');
  assert.equal(slots.get('k').running, false);
});

test('F6 detachFlight: a waiter that joined before the detach gets the old run; a caller after it runs anew', async () => {
  const { isolateFlight, detachFlight } = await flight();
  const slots = new Map();
  let releaseA, releaseC;
  let runs = 0;
  const opts = { waitMs: 2000, pollMs: 5 };
  const a = isolateFlight(slots, 's', () => { runs++; return new Promise((r) => { releaseA = r; }); }, opts);
  const b = isolateFlight(slots, 's', async () => { runs++; return 'b-own'; }, opts); // joins a
  await new Promise((r) => setTimeout(r, 10));
  detachFlight(slots, 's');
  assert.equal(slots.get('s').running, false);
  const c = isolateFlight(slots, 's', () => { runs++; return new Promise((r) => { releaseC = r; }); }, opts);
  assert.equal(runs, 2, 'a caller after the detach starts its own run at once');
  releaseA('a-old');
  assert.equal(await a, 'a-old');
  assert.equal(await b, 'a-old', 'the old waiter gets the old run');
  releaseC('c-own');
  assert.equal(await c, 'c-own');
  assert.equal(slots.get('s').done.value, 'c-own', 'the newer run is the one kept');
  assert.equal(runs, 2);
  // If the newer run finishes first, an old waiter takes that newer (fresher) result.
  const s2 = new Map();
  const a2 = isolateFlight(s2, 'k', never, opts);
  const b2 = isolateFlight(s2, 'k', async () => 'b2-own', opts);
  await new Promise((r) => setTimeout(r, 10));
  detachFlight(s2, 'k');
  assert.equal(await isolateFlight(s2, 'k', async () => 'c2-new', opts), 'c2-new');
  assert.equal(await b2, 'c2-new');
  void a2;
});

test('F7 the composed schema seeds d1_flight.wait_ms and d1_flight.poll_ms at the code fallbacks', async () => {
  const { D1_FLIGHT_WAIT_MS, D1_FLIGHT_POLL_MS } = await flight();
  const seedOf = (key) => {
    const m = SCHEMA_SQL.match(new RegExp(`INSERT OR IGNORE INTO settings \\(key,value,note,actor,updated_at\\) VALUES \\('${key.replace('.', '\\.')}','([^']*)'`));
    return m && m[1];
  };
  assert.equal(seedOf('d1_flight.wait_ms'), String(D1_FLIGHT_WAIT_MS));
  assert.equal(seedOf('d1_flight.poll_ms'), String(D1_FLIGHT_POLL_MS));
  assert.equal(D1_FLIGHT_WAIT_MS, 3000);
  assert.equal(D1_FLIGHT_POLL_MS, 20);
});

test('F8 flightKnobs: bad values fall back; wait 0 means no join; a frozen Date does not make the poll endless', async (t) => {
  const { flightKnobs, isolateFlight, D1_FLIGHT_WAIT_MS, D1_FLIGHT_POLL_MS } = await flight();
  const peekOf = (vals) => (_db, key) => (key in vals ? vals[key] : null);
  const fallback = { waitMs: D1_FLIGHT_WAIT_MS, pollMs: D1_FLIGHT_POLL_MS };
  assert.deepEqual(flightKnobs(peekOf({}), {}), fallback);
  for (const bad of ['3000.5', '-1', '9000', ' 20', '', 'abc']) {
    assert.deepEqual(flightKnobs(peekOf({ 'd1_flight.wait_ms': bad, 'd1_flight.poll_ms': bad }), {}), fallback, `value ${JSON.stringify(bad)}`);
  }
  assert.deepEqual(flightKnobs(peekOf({ 'd1_flight.poll_ms': '4' }), {}), fallback, 'poll 4 is under the range');
  assert.deepEqual(flightKnobs(peekOf({ 'd1_flight.wait_ms': '0', 'd1_flight.poll_ms': '500' }), {}), { waitMs: 0, pollMs: 500 });
  assert.deepEqual(flightKnobs(peekOf({ 'd1_flight.wait_ms': '7000', 'd1_flight.poll_ms': '5' }), {}), { waitMs: 7000, pollMs: 5 });

  // wait 0: two concurrent callers run two reads.
  let runs = 0;
  const slots = new Map();
  const slow = async () => { runs++; await new Promise((r) => setTimeout(r, 10)); return runs; };
  await Promise.all([isolateFlight(slots, 'z', slow, { waitMs: 0, pollMs: 5 }), isolateFlight(slots, 'z', slow, { waitMs: 0, pollMs: 5 })]);
  assert.equal(runs, 2, 'wait 0: no join');

  // A frozen Date and a creator that never settles: the waiter still runs its own.
  t.mock.timers.enable({ apis: ['Date'], now: Date.UTC(2026, 10, 20) });
  const s2 = new Map();
  isolateFlight(s2, 'f', never, { waitMs: 50, pollMs: 5 });
  assert.equal(await isolateFlight(s2, 'f', async () => 'own', { waitMs: 50, pollMs: 5 }), 'own');
});

test('F9 static: settings-cache.js shares no promise; core.js stores no run promise in its table maps', () => {
  const src = (p) => readFileSync(new URL(p, import.meta.url), 'utf8');
  const sc = src('../src/lib/settings-cache.js');
  assert.match(sc, /export async function settingsRows\(/);
  assert.match(sc, /export function invalidateSettings\(/);
  assert.doesNotMatch(sc, /inflight/);
  assert.doesNotMatch(sc, /\.promise\b/);
  const core = src('../src/lib/core.js');
  assert.match(core, /export async function ensureTable\(/);
  assert.match(core, /export async function ensureColumns\(/);
  assert.doesNotMatch(core, /per\.set\(table, p\)/);
  assert.doesNotMatch(core, /return per\.get\(table\)/);
});
