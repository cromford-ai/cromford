// BH-9657 (slice C1 of BH-9249): the hot D1 statement and its load.
//
// The live statement counter put `SELECT * FROM settings ORDER BY key ASC`
// (lib/settings-cache.js settingsRows) at about 88% of sampled rows read. Two
// defects ran it more often than its TTL allows, and ensureTable sent one D1
// call per DDL statement. Each test opens its own node:sqlite D1 and its own
// unique keys, so no test shares data with another.
//
//   AT3  EXPLAIN QUERY PLAN of the statement settingsRows really sends, at the
//        live row count (1,008): it walks the primary-key index, no temp sort
//   AT4  the worker default export: 20 concurrent GET /api/settings/<key> on a
//        cold binding run the full read once; a sampled 21st request inside
//        the TTL runs it 0 times (budget SETTINGS_FULL_READS_PER_BURST = 1)
//   B1   20 concurrent settingsRows calls -> 1 read, one shared rows object
//   B2   a sampled request (withStmtStats) after a warm unsampled read -> 0
//        reads; peekSetting through retry(stats(raw)) sees the snapshot
//   B3   fresh snapshot -> 0 reads, byKey round-trips the seed
//   B4   a rejected read is not shared with the next caller
//   B5   two bindings -> two reads
//   E1   TTL 30 -> stored; E2 invalidate during the read -> not stored;
//   E3   TTL row '0' -> callers share one read, nothing stored;
//   E4   TTL row '61' -> the env TTL is used
//   R1-R4 rawDb / rootDb unwrap every registered wrapper and nothing else
//   T3a-T3d ensureTable sends its statements as one batch when it can
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { settingsRows, invalidateSettings, peekSetting } from '../src/lib/settings-cache.js';
import { retryingDb, rawDb } from '../src/lib/d1-retry.js';
import { stmtStatsDb, withStmtStats, _resetStmtStats } from '../src/lib/stmt-stats.js';
import { ensureTable, CREATED_TABLES } from '../src/lib/core.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh9657';
const FULL_READ = /^SELECT \* FROM settings ORDER BY key ASC$/;
const LIVE_SETTINGS_ROWS = 1008; // the live settings row count, 2026-11-13
const SETTINGS_FULL_READS_PER_BURST = 1; // the budget the note documents
const FIXED_NOW = Date.UTC(2026, 10, 13, 12, 0, 0);

let seq = 0;
const uniq = (tag) => `bh9657.${tag}.${process.pid}.${++seq}`;

async function fresh(t) {
  _resetStmtStats();
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', '2026-11-13T00:00:00Z');
}
// Fill settings up to the live row count with unique keys.
function seedToLive(db, tag) {
  const have = db.prepare('SELECT COUNT(*) AS n FROM settings').get().n;
  const ins = db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)`);
  for (let i = have; i < LIVE_SETTINGS_ROWS; i++) ins.run(`${tag}.${i}`, String(i), 'test', '2026-11-13T00:00:00Z');
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM settings').get().n, LIVE_SETTINGS_ROWS);
}
// A D1 binding that logs every statement that reaches it, then runs it on DB.
// `failNext` makes the next N full settings reads (or batches) reject.
function counting(DB, opts = {}) {
  const log = [];
  const state = { failReads: opts.failReads || 0, failBatches: opts.failBatches || 0, gate: null };
  const wrap = (s, sql) => {
    const api = {
      _raw: s, _sql: sql,
      bind(...v) { s.bind(...v); return api; },
      async first(c) { log.push({ op: 'first', sql }); return s.first(c); },
      async all() {
        log.push({ op: 'all', sql });
        if (state.gate && FULL_READ.test(sql)) await state.gate;
        if (state.failReads > 0 && FULL_READ.test(sql)) { state.failReads--; throw new Error('D1 fixture read failure'); }
        return s.all();
      },
      async run() { log.push({ op: 'run', sql }); return s.run(); },
    };
    return api;
  };
  const b = {
    log, state,
    prepare(sql) { return wrap(DB.prepare(sql), sql); },
    async batch(stmts) {
      log.push({ op: 'batch', n: stmts.length, sqls: stmts.map((x) => x._sql) });
      if (state.failBatches > 0) { state.failBatches--; throw new Error('D1 fixture batch failure'); }
      return DB.batch(stmts.map((x) => x._raw));
    },
  };
  return b;
}
const fullReads = (log) => log.filter((e) => e.op === 'all' && FULL_READ.test(e.sql)).length;
class Ctx {
  constructor() { this.waits = []; }
  waitUntil(p) { this.waits.push(Promise.resolve(p)); }
  passThroughOnException() {}
}
async function settle(ctx) {
  for (let seen = -1; seen !== ctx.waits.length;) {
    seen = ctx.waits.length;
    await Promise.all(ctx.waits);
  }
}
const pinClock = (t) => t.mock.timers.enable({ apis: ['Date'], now: FIXED_NOW });

test('AT3 EXPLAIN of the statement settingsRows sends, at the live row count, uses the primary-key index', async (t) => {
  const o = await fresh(t); if (!o) return;
  seedToLive(o.db, uniq('at3'));
  const DB = counting(o.DB);
  await settingsRows({ DB, SETTINGS_CACHE_TTL_S: '30' });
  const sent = DB.log.filter((e) => e.op === 'all').map((e) => e.sql);
  assert.equal(sent.length, 1, JSON.stringify(sent));
  assert.match(sent[0], FULL_READ);
  const lines = plan(o.db, sent[0]);
  assert.deepEqual(lines, ['SCAN settings USING INDEX sqlite_autoindex_settings_1']);
  assert.ok(!lines.some((l) => /TEMP B-TREE/.test(l)), lines.join(' | '));
  assert.deepEqual(fullScans(lines, ['settings']), []);
});

test('AT4 worker.fetch: 20 concurrent GET /api/settings/<key> run the full read once; a sampled 21st runs it 0 times', async (t) => {
  const o = await fresh(t); if (!o) return;
  pinClock(t);
  const key = uniq('at4');
  setting(o.db, key, 'v-at4');
  setting(o.db, 'd1.stmt_stats_sample_pct', 100); // every request after the knob load is sampled
  const DB = counting(o.DB);
  const env = { DB, HARNESS_SECRET: SECRET, SETTINGS_CACHE_TTL_S: '30' };
  const get = async () => {
    const ctx = new Ctx();
    const res = await worker.fetch(new Request(`https://jobs.test/api/settings/${key}`, { headers: { authorization: `Bearer ${SECRET}` } }), env, ctx);
    await settle(ctx);
    return { status: res.status, body: await res.json() };
  };
  const burst = await Promise.all(Array.from({ length: 20 }, get));
  for (const r of burst) {
    assert.equal(r.status, 200);
    assert.equal(r.body.setting && r.body.setting.value, 'v-at4');
  }
  assert.equal(fullReads(DB.log), SETTINGS_FULL_READS_PER_BURST, 'one full settings read for the cold burst');
  const before = fullReads(DB.log);
  const r21 = await get();
  assert.equal(r21.status, 200);
  assert.equal(r21.body.setting.value, 'v-at4');
  assert.equal(fullReads(DB.log) - before, 0, 'a sampled request inside the TTL reads nothing');
});

test('B1 20 concurrent settingsRows calls on a cold binding run one read and share its rows', async (t) => {
  const o = await fresh(t); if (!o) return;
  const DB = counting(o.DB);
  const env = { DB, SETTINGS_CACHE_TTL_S: '30' };
  const outs = await Promise.all(Array.from({ length: 20 }, () => settingsRows(env)));
  assert.equal(fullReads(DB.log), 1);
  for (const s of outs) assert.equal(s.rows, outs[0].rows);
});

test('B2 a sampled request after a warm unsampled read runs no settings read', async (t) => {
  const o = await fresh(t); if (!o) return;
  pinClock(t);
  const key = uniq('b2');
  setting(o.db, key, 'v-b2');
  const DB = counting(o.DB);
  const env = { DB, SETTINGS_CACHE_TTL_S: '30' };
  let got = null;
  // The handler wraps env.DB the way src/index.js does.
  const h = withStmtStats({
    async fetch(req, e) {
      const wrapped = { ...e, DB: retryingDb(e.DB) };
      got = (await settingsRows(wrapped)).byKey.get(key);
      return new Response('ok');
    },
  }, { random: () => 0 });
  // Request 1: the knob load runs, the request is not sampled.
  let ctx = new Ctx();
  await h.fetch(new Request('https://jobs.test/a'), env, ctx);
  await settle(ctx);
  assert.equal(fullReads(DB.log), 1);
  // Request 2: sampled (pct 1, random 0): env.DB is the stats proxy.
  ctx = new Ctx();
  await h.fetch(new Request('https://jobs.test/b'), env, ctx);
  await settle(ctx);
  assert.equal(fullReads(DB.log), 1, 'the sampled request used the snapshot');
  assert.equal(got.value, 'v-b2');
  assert.equal(peekSetting(retryingDb(stmtStatsDb(DB)), key), 'v-b2');
});

test('B3 a fresh snapshot answers with no read, and byKey round-trips the seed', async (t) => {
  const o = await fresh(t); if (!o) return;
  pinClock(t);
  const key = uniq('b3');
  setting(o.db, key, 'v-b3');
  const DB = counting(o.DB);
  const env = { DB, SETTINGS_CACHE_TTL_S: '30' };
  await settingsRows(env);
  t.mock.timers.tick(29_000);
  const s = await settingsRows(env);
  assert.equal(fullReads(DB.log), 1);
  assert.equal(s.byKey.get(key).value, 'v-b3');
  t.mock.timers.tick(1_000);
  await settingsRows(env);
  assert.equal(fullReads(DB.log), 2, 'at the TTL the snapshot is stale');
});

test('B4 a rejected read rejects every waiter and is not shared with the next caller', async (t) => {
  const o = await fresh(t); if (!o) return;
  const DB = counting(o.DB, { failReads: 1 });
  const env = { DB, SETTINGS_CACHE_TTL_S: '30' };
  const both = await Promise.allSettled([settingsRows(env), settingsRows(env)]);
  assert.deepEqual(both.map((r) => r.status), ['rejected', 'rejected']);
  assert.equal(fullReads(DB.log), 1);
  const s = await settingsRows(env);
  assert.ok(s.rows.length > 0);
  assert.equal(fullReads(DB.log), 2);
});

test('B5 two bindings do not share a snapshot', async (t) => {
  const o1 = await fresh(t); if (!o1) return;
  const o2 = await openDb();
  const A = counting(o1.DB), B = counting(o2.DB);
  await Promise.all([settingsRows({ DB: A, SETTINGS_CACHE_TTL_S: '30' }), settingsRows({ DB: B, SETTINGS_CACHE_TTL_S: '30' })]);
  assert.equal(fullReads(A.log), 1);
  assert.equal(fullReads(B.log), 1);
});

test('E1 TTL 30: the snapshot is stored', async (t) => {
  const o = await fresh(t); if (!o) return;
  pinClock(t);
  const DB = counting(o.DB);
  const env = { DB, SETTINGS_CACHE_TTL_S: '30' };
  const s = await settingsRows(env);
  assert.equal(s.ttlMs, 30_000);
  await settingsRows(env);
  assert.equal(fullReads(DB.log), 1);
});

test('E2 invalidateSettings during a read: waiters get the result, the old snapshot is not stored', async (t) => {
  const o = await fresh(t); if (!o) return;
  pinClock(t);
  const key = uniq('e2');
  setting(o.db, key, 'old');
  const DB = counting(o.DB);
  const env = { DB, SETTINGS_CACHE_TTL_S: '30' };
  let open;
  DB.state.gate = new Promise((r) => { open = r; });
  const pending = settingsRows(env);
  // A write lands while the read is in flight.
  await Promise.resolve();
  setting(o.db, key, 'new');
  invalidateSettings(env);
  DB.state.gate = null;
  open();
  const first = await pending;
  assert.ok(first.byKey.has(key));
  const next = await settingsRows(env);
  assert.equal(fullReads(DB.log), 2, 'the next call reads again');
  assert.equal(next.byKey.get(key).value, 'new');
});

test("E3 TTL row '0': concurrent callers share one read, nothing is stored", async (t) => {
  const o = await fresh(t); if (!o) return;
  setting(o.db, 'settings_cache_ttl_s', '0');
  const DB = counting(o.DB);
  const env = { DB, SETTINGS_CACHE_TTL_S: '30' };
  const outs = await Promise.all(Array.from({ length: 5 }, () => settingsRows(env)));
  assert.equal(outs[0].ttlMs, 0);
  assert.equal(fullReads(DB.log), 1);
  await settingsRows(env);
  assert.equal(fullReads(DB.log), 2);
  assert.equal(peekSetting(DB, 'settings_cache_ttl_s'), null, 'TTL 0 stores no snapshot');
});

test("E4 a TTL row that is not valid falls back to the env TTL", async (t) => {
  for (const bad of ['61', 'abc']) {
    const o = await fresh(t); if (!o) return;
    setting(o.db, 'settings_cache_ttl_s', bad);
    const s = await settingsRows({ DB: counting(o.DB), SETTINGS_CACHE_TTL_S: '30' });
    assert.equal(s.ttlMs, 30_000, `row '${bad}'`);
  }
});

test('R1-R4 rawDb and rootDb return the true binding behind every registered wrapper', async () => {
  const { rootDb } = await import('../src/lib/db-root.js');
  const raw = d1(null);
  for (const f of [rawDb, rootDb]) {
    assert.equal(f(raw), raw, 'R1 raw');
    assert.equal(f(retryingDb(stmtStatsDb(raw))), raw, 'R2 retry(stats(raw))');
    assert.equal(f(stmtStatsDb(raw)), raw, 'R3 stats(raw)');
    assert.equal(f(retryingDb(raw)), raw, 'retry(raw)');
    const plain = { prepare() {} };
    assert.equal(f(plain), plain, 'R4 a plain object');
  }
  // A proxy that is not registered is not unwrapped.
  const other = new Proxy(raw, {});
  assert.equal(rootDb(other), other);
});

test('T3a ensureTable(lane_ticks) sends its 3 statements as one batch', async (t) => {
  const { DatabaseSync } = await import('node:sqlite');
  const db = new DatabaseSync(':memory:');
  const DB = counting(d1(db));
  assert.equal(CREATED_TABLES.lane_ticks.length, 3);
  await ensureTable({ DB }, 'lane_ticks');
  assert.deepEqual(DB.log.map((e) => e.op), ['batch']);
  assert.equal(DB.log[0].n, 3);
  const names = db.prepare("SELECT name FROM sqlite_master WHERE tbl_name='lane_ticks' AND type IN ('table','index') AND name NOT LIKE 'sqlite_%' ORDER BY name").all().map((r) => r.name);
  assert.deepEqual(names, ['idx_lane_ticks_lane', 'idx_lane_ticks_tick', 'lane_ticks']);
  // memoised: a second call sends nothing
  await ensureTable({ DB }, 'lane_ticks');
  assert.equal(DB.log.length, 1);
});

test('T3a through the retry and stats proxies: still one batch on the binding', async () => {
  const { DatabaseSync } = await import('node:sqlite');
  const DB = counting(d1(new DatabaseSync(':memory:')));
  await ensureTable({ DB: retryingDb(stmtStatsDb(DB)) }, 'lane_ticks');
  assert.deepEqual(DB.log.map((e) => e.op), ['batch']);
});

test('T3b a table with one statement runs it once, no batch', async () => {
  const { DatabaseSync } = await import('node:sqlite');
  const one = Object.entries(CREATED_TABLES).find(([, v]) => v.length === 1)[0];
  const DB = counting(d1(new DatabaseSync(':memory:')));
  await ensureTable({ DB }, one);
  assert.deepEqual(DB.log.map((e) => e.op), ['run']);
});

test('T3c a binding with no batch runs the statements one by one', async () => {
  const { DatabaseSync } = await import('node:sqlite');
  const DB = counting(d1(new DatabaseSync(':memory:')));
  const noBatch = { prepare: (sql) => DB.prepare(sql) };
  await ensureTable({ DB: noBatch }, 'lane_ticks');
  assert.deepEqual(DB.log.map((e) => e.op), ['run', 'run', 'run']);
});

test('T3d a failed batch rejects and is not memoised; the next call retries', async () => {
  const { DatabaseSync } = await import('node:sqlite');
  const db = new DatabaseSync(':memory:');
  const DB = counting(d1(db), { failBatches: 1 });
  await assert.rejects(ensureTable({ DB }, 'lane_ticks'), /fixture batch failure/);
  await ensureTable({ DB }, 'lane_ticks');
  assert.deepEqual(DB.log.map((e) => e.op), ['batch', 'batch']);
  assert.ok(db.prepare("SELECT 1 FROM sqlite_master WHERE name='lane_ticks'").get());
});

test('T3c a no-batch binding under the retry and stats proxies still runs one by one', async () => {
  const { DatabaseSync } = await import('node:sqlite');
  const DB = counting(d1(new DatabaseSync(':memory:')));
  const noBatch = { prepare: (sql) => DB.prepare(sql) };
  await ensureTable({ DB: retryingDb(stmtStatsDb(noBatch)) }, 'lane_ticks');
  assert.deepEqual(DB.log.map((e) => e.op), ['run', 'run', 'run']);
});
