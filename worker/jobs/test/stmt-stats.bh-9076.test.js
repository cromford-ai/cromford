// BH-9076 (slice 5 of BH-9067): the sampled D1 statement counter
// (src/lib/stmt-stats.js), its table d1_stmt_stats and GET
// /api/d1/stmt-stats/top, on node:sqlite with the composed jobs schema
// (worker/jobs/schema.d/). Each test opens its own DB and resets the
// isolate state with _resetStmtStats().
//
//   S1  the sampling decision table, and a knob row that is not an integer
//       in range runs as the fallback 1
//   S2  pct 100: 3 calls of one statement in one request = one row, calls 3
//   S3  rows_read is summed from meta.rows_read; /top?hours=1&n=20 returns
//       the row with calls and rows_read
//   S4  normalizeSql: literals and IN lists fold to one hash; another table
//       is another hash
//   S5  one batch per flush; an empty accumulator runs no statement
//   S6  pct 0: no row, and the handler gets the very env.DB it was given;
//       no ctx: never sampled, no knob read
//   S7  /top orders by calls desc; n=0, n=101, hours=abc, hours=337 are 400
//       naming the field
//   S8  a real retention run deletes a 15-day-old hour and keeps a 1-hour-old one
//   S9  EXPLAIN QUERY PLAN of the /top read uses an index on d1_stmt_stats
//   S10 the default export of src/index.js at pct 100 writes a row for the
//       statements a real route ran (the production entry point)
//   S11 the flush and the knob read are never counted; a failed flush is
//       dropped without a throw; the overflow key caps the accumulator
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import {
  withStmtStats, stmtStatsDb, normalizeSql, sqlHash, sampled, flushStmtStats,
  loadStmtStatsKnobs, _resetStmtStats, OVERFLOW_HASH,
} from '../src/lib/stmt-stats.js';
import { TOP_SQL } from '../src/routes/d1-stmt-stats.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'tok-fixture-bh9076';
const NOW = Date.now();  // determinism: ok the single anchor; every seeded time is an offset from it
const hourAgo = (h) => new Date(NOW - h * 3600e3).toISOString().slice(0, 13);
const isoAgo = (h) => new Date(NOW - h * 3600e3).toISOString().replace(/\.\d{3}Z$/, 'Z');

async function fresh(t) {
  _resetStmtStats();
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  return o;
}
function setting(db, key, value) {
  db.prepare(`INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'',?,?)
              ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, String(value), 'test', isoAgo(0));
}
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
// The shim with meta.rows_read on every all()/run() and batch result, the
// field real D1 sets, plus a log of the statements that reached the binding.
function metered(DB, rowsRead, log = []) {
  const addMeta = (r) => ({ ...r, meta: { ...(r && r.meta), rows_read: rowsRead } });
  return {
    log,
    prepare(sql) {
      const s = DB.prepare(sql);
      const api = {
        _raw: s, _sql: sql,
        bind(...v) { s.bind(...v); return api; },
        first(c) { log.push(`first ${sql}`); return s.first(c); },
        async all() { log.push(`all ${sql}`); return addMeta(await s.all()); },
        async run() { log.push(`run ${sql}`); return addMeta(await s.run()); },
      };
      return api;
    },
    async batch(stmts) {
      log.push(`batch ${stmts.length}`);
      return (await DB.batch(stmts.map((x) => x._raw))).map(addMeta);
    },
  };
}
const statRows = (db) => db.prepare('SELECT hour, sql_hash, sql_text, calls, rows_read FROM d1_stmt_stats ORDER BY calls DESC').all();
const ONE_SQL = 'SELECT key, value FROM settings WHERE key = ?1';
// A handler that runs ONE_SQL `times` times and remembers the env.DB it got.
function handler(times = 3) {
  const h = {
    seen: null,
    async fetch(req, env) {
      h.seen = env.DB;
      for (let i = 0; i < times; i++) await env.DB.prepare(ONE_SQL).bind(`k${i}`).all();
      return new Response('ok');
    },
  };
  return h;
}
// The first request of an isolate reads the knobs (in waitUntil) and is never
// sampled; this request does that, so the next one sees the knob rows.
async function warm(w, env) {
  const ctx = new Ctx();
  await w.fetch(new Request('https://jobs.test/warm'), env, ctx);
  await settle(ctx);
}
async function hit(w, env, path = '/x') {
  const ctx = new Ctx();
  const res = await w.fetch(new Request(`https://jobs.test${path}`, { headers: { authorization: `Bearer ${SECRET}` } }), env, ctx);
  await settle(ctx);
  return res;
}
function call(DB, path, { method = 'GET', body } = {}) {
  return worker.fetch(new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  }), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
}

test('S1 sampling decision table; a bad pct row runs as 1', async (t) => {
  const cases = [
    [100, 0.999, true], [1, 0.005, true], [50, 0.49, true],
    [0, 0, false], [1, 0.01, false], [50, 0.5, false],
  ];
  for (const [pct, r, want] of cases) assert.equal(sampled(pct, r), want, `pct ${pct} r ${r}`);
  const o = await fresh(t); if (!o) return;
  for (const bad of ['abc', '101', '-1', '', '2.5']) {
    setting(o.db, 'd1.stmt_stats_sample_pct', bad);
    assert.equal((await loadStmtStatsKnobs(o.DB)).pct, 1, `row "${bad}" runs as the fallback 1`);
  }
  setting(o.db, 'd1.stmt_stats_sample_pct', '37');
  assert.equal((await loadStmtStatsKnobs(o.DB)).pct, 37);
  o.db.prepare("DELETE FROM settings WHERE key = 'd1.stmt_stats_sample_pct'").run();
  assert.equal((await loadStmtStatsKnobs(o.DB)).pct, 1, 'an absent row runs as 1');
  // The seed row is 1.
  const o2 = await openDb();
  assert.equal(o2.db.prepare("SELECT value FROM settings WHERE key='d1.stmt_stats_sample_pct'").get().value, '1');
});

test('S2 pct 100: three calls of one statement in one request give one row with calls 3', async (t) => {
  const o = await fresh(t); if (!o) return;
  setting(o.db, 'd1.stmt_stats_sample_pct', 100);
  const h = handler(3);
  const w = withStmtStats(h, { random: () => 0.999 });
  const env = { DB: o.DB };
  await warm(w, env);
  assert.equal(statRows(o.db).length, 0, 'the first request of an isolate is not sampled');
  await hit(w, env);
  const rows = statRows(o.db);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].calls, 3);
  assert.equal(rows[0].sql_hash, sqlHash(normalizeSql(ONE_SQL)));
  assert.equal(rows[0].hour, hourAgo(0));
  await hit(w, env);
  assert.equal(statRows(o.db)[0].calls, 6, 'a second flush in the same hour adds to the row');
});

test('S3 rows_read is summed from meta; /top?hours=1&n=20 returns calls and rows_read', async (t) => {
  const o = await fresh(t); if (!o) return;
  setting(o.db, 'd1.stmt_stats_sample_pct', 100);
  const env = { DB: metered(o.DB, 7) };
  const w = withStmtStats(handler(3), { random: () => 0.5 });
  await warm(w, env);
  await hit(w, env);
  const top = await call(o.DB, '/api/d1/stmt-stats/top?hours=1&n=20');
  assert.equal(top.status, 200);
  const row = top.body.rows.find((r) => r.sql_hash === sqlHash(normalizeSql(ONE_SQL)));
  assert.ok(row, `the counted statement is in /top: ${JSON.stringify(top.body.rows)}`);
  assert.equal(row.calls, 3);
  assert.equal(row.rows_read, 21);
  assert.equal(row.rows_per_call, 7);
  assert.equal(row.sql_text, normalizeSql(ONE_SQL));
  assert.equal(top.body.hours, 1);
  assert.equal(top.body.n, 20);
  assert.equal(top.body.sample_pct, 100);
});

test('S4 normalizeSql folds literals and IN lists; another table is another hash', () => {
  const h = (s) => sqlHash(normalizeSql(s));
  assert.equal(h("SELECT * FROM jobs WHERE id = 5 AND s = 'a'"), h("SELECT * FROM jobs WHERE id = 9 AND s = 'b'"));
  assert.equal(h('SELECT * FROM jobs WHERE id IN (?,?,?)'), h('SELECT * FROM jobs WHERE id IN (?)'));
  assert.equal(h('SELECT *  FROM jobs -- note\n WHERE id = ?1'), h('SELECT * FROM jobs WHERE id = ?'));
  assert.equal(h("SELECT 'it''s' FROM jobs"), h("SELECT 'x' FROM jobs"));
  assert.notEqual(h('SELECT * FROM jobs WHERE id = ?'), h('SELECT * FROM wakes WHERE id = ?'));
  assert.notEqual(h('SELECT * FROM t1 WHERE id = ?'), h('SELECT * FROM t2 WHERE id = ?'), 'digits inside a name stay');
  assert.match(h('SELECT 1'), /^[0-9a-f]{16}$/);
  assert.equal(normalizeSql("SELECT a FROM t WHERE b = 'x' AND c IN (1, 2, 3) LIMIT 50"), 'SELECT a FROM t WHERE b = ? AND c IN (?) LIMIT ?');
});

test('S5 one batch per flush; an empty accumulator runs no statement', async (t) => {
  const o = await fresh(t); if (!o) return;
  setting(o.db, 'd1.stmt_stats_sample_pct', 100);
  const log = [];
  const env = { DB: metered(o.DB, 1, log) };
  const w = withStmtStats({
    async fetch(req, e) {
      await e.DB.prepare('SELECT 1 AS a').first();
      await e.DB.prepare('SELECT 2 AS b').all();
      await e.DB.batch([e.DB.prepare('SELECT 3 AS c'), e.DB.prepare('SELECT 4 AS d')]);
      return new Response('ok');
    },
  }, { random: () => 0 });
  await warm(w, env);
  log.length = 0;
  await hit(w, env);
  const batches = log.filter((l) => l.startsWith('batch'));
  // the handler's own batch, plus exactly one flush batch
  assert.deepEqual(batches, ['batch 2', 'batch 4'], `batches: ${JSON.stringify(log)}`);
  assert.equal(statRows(o.db).length, 4, 'four shapes (the aliases differ), one call each, the batch counted per statement');
  assert.deepEqual(statRows(o.db).map((r) => r.calls), [1, 1, 1, 1]);
  log.length = 0;
  assert.equal(await flushStmtStats(env.DB), 0);
  assert.deepEqual(log, [], 'an empty accumulator runs no statement');
});

test('S6 pct 0: no row, same env.DB; no ctx: never sampled, nothing read', async (t) => {
  const o = await fresh(t); if (!o) return;
  setting(o.db, 'd1.stmt_stats_sample_pct', 0);
  const h = handler(3);
  const w = withStmtStats(h, { random: () => 0 });
  const env = { DB: o.DB };
  await warm(w, env);
  await hit(w, env);
  assert.equal(h.seen, o.DB, 'an unsampled request gets the very binding');
  assert.equal(statRows(o.db).length, 0);
  // contrast: at 100 the handler sees the stats proxy
  setting(o.db, 'd1.stmt_stats_sample_pct', 100);
  await loadStmtStatsKnobs(o.DB);
  await hit(w, env);
  assert.notEqual(h.seen, o.DB);
  assert.equal(h.seen, stmtStatsDb(o.DB), 'the stats proxy is memoised per binding');
  // no ctx: the node suites' worker.fetch(req, env) shape
  _resetStmtStats();
  const log = [];
  const env2 = { DB: metered(o.DB, 1, log) };
  const h2 = handler(1);
  const w2 = withStmtStats(h2, { random: () => 0 });
  for (let i = 0; i < 3; i++) await w2.fetch(new Request('https://jobs.test/x'), env2);
  assert.equal(h2.seen, env2.DB);
  assert.deepEqual(log.filter((l) => !l.includes(ONE_SQL)), [], 'no knob read and no flush without ctx');
});

test('S7 /top orders by calls desc; bad n and hours are 400 naming the field', async (t) => {
  const o = await fresh(t); if (!o) return;
  const ins = o.db.prepare('INSERT INTO d1_stmt_stats (hour, sql_hash, sql_text, calls, rows_read) VALUES (?,?,?,?,?)');
  ins.run(hourAgo(0), 'aaaa', 'SELECT a', 5, 50);
  ins.run(hourAgo(0), 'bbbb', 'SELECT b', 9, 9);
  ins.run(hourAgo(0), 'cccc', 'SELECT c', 1, 0);
  ins.run(hourAgo(1), 'cccc', 'SELECT c', 2, 0);
  ins.run(hourAgo(30), 'dddd', 'SELECT d', 100, 0);
  const r = await call(o.DB, '/api/d1/stmt-stats/top?hours=1&n=20');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.rows.map((x) => [x.sql_hash, x.calls]), [['bbbb', 9], ['aaaa', 5], ['cccc', 1]]);
  const r2 = await call(o.DB, '/api/d1/stmt-stats/top?hours=2&n=2');
  assert.deepEqual(r2.body.rows.map((x) => [x.sql_hash, x.calls]), [['bbbb', 9], ['aaaa', 5]]);
  const r3 = await call(o.DB, '/api/d1/stmt-stats/top');
  assert.equal(r3.body.hours, 24);
  assert.equal(r3.body.n, 20);
  assert.deepEqual(r3.body.rows.map((x) => [x.sql_hash, x.calls]), [['bbbb', 9], ['aaaa', 5], ['cccc', 3]]);
  for (const [q, field] of [['n=0', 'n'], ['n=101', 'n'], ['hours=abc', 'hours'], ['hours=337', 'hours'], ['hours=0', 'hours'], ['n=2.5', 'n']]) {
    const bad = await call(o.DB, `/api/d1/stmt-stats/top?${q}`);
    assert.equal(bad.status, 400, q);
    assert.equal(bad.body.field, field, q);
  }
  setting(o.db, 'd1.stmt_stats_top_max', 200);
  assert.equal((await call(o.DB, '/api/d1/stmt-stats/top?n=101')).status, 200, 'the cap is the settings row');
  const noAuth = await worker.fetch(new Request('https://jobs.test/api/d1/stmt-stats/top'), { DB: o.DB, HARNESS_SECRET: SECRET });
  assert.equal(noAuth.status, 401);
});

test('S8 a real retention run deletes a 15-day-old hour and keeps a 1-hour-old one', async (t) => {
  const o = await fresh(t); if (!o) return;
  const ins = o.db.prepare('INSERT INTO d1_stmt_stats (hour, sql_hash, sql_text, calls, rows_read) VALUES (?,?,?,?,?)');
  ins.run(hourAgo(15 * 24), 'old', 'SELECT old', 1, 0);
  ins.run(hourAgo(1), 'new', 'SELECT new', 1, 0);
  setting(o.db, 'retention.dry_run', 0);
  const r = await call(o.DB, '/api/retention/run', { method: 'POST', body: {} });
  assert.equal(r.status, 200);
  const rule = r.body.rules.find((x) => x.rule === 'stmt_stats.age');
  assert.ok(rule, 'the stmt_stats.age rule ran');
  assert.equal(rule.error, null);
  assert.equal(rule.removed, 1);
  assert.deepEqual(o.db.prepare('SELECT sql_hash FROM d1_stmt_stats').all().map((x) => x.sql_hash), ['new']);
  const audit = o.db.prepare("SELECT removed, dry_run FROM retention_runs WHERE rule = 'stmt_stats.age'").all();
  assert.deepEqual(audit.map((a) => [a.removed, a.dry_run]), [[1, 0]]);
});

test('S9 EXPLAIN QUERY PLAN of the /top read and the retention id read use an index', async (t) => {
  const o = await fresh(t); if (!o) return;
  const ins = o.db.prepare('INSERT INTO d1_stmt_stats (hour, sql_hash, sql_text, calls, rows_read) VALUES (?,?,?,?,?)');
  o.db.exec('BEGIN');
  for (let h = 0; h < 336; h++) for (let k = 0; k < 60; k++) ins.run(hourAgo(h), `h${k}`, `SELECT ${k}`, k + 1, k);
  o.db.exec('COMMIT');
  o.db.exec('ANALYZE');
  const top = plan(o.db, TOP_SQL, hourAgo(23), 20);
  assert.deepEqual(fullScans(top, ['d1_stmt_stats']), [], top.join(' | '));
  assert.ok(top.some((l) => /^SEARCH d1_stmt_stats USING (COVERING )?INDEX idx_d1_stmt_stats_hour_calls \(hour>\?\)/.test(l)), top.join(' | '));
  const ids = plan(o.db, 'SELECT rowid AS id FROM d1_stmt_stats WHERE hour < substr(?1, 1, 13) ORDER BY hour LIMIT ?2', isoAgo(14 * 24), 500);
  assert.deepEqual(fullScans(ids, ['d1_stmt_stats']), [], ids.join(' | '));
});

test('S10 the worker default export at pct 100 writes a row for a real route', async (t) => {
  const o = await fresh(t); if (!o) return;
  setting(o.db, 'd1.stmt_stats_sample_pct', 100);
  const env = { DB: o.DB, HARNESS_SECRET: SECRET };
  await warm(worker, env);
  const res = await hit(worker, env, '/api/d1/stmt-stats/top?hours=1&n=20');
  assert.equal(res.status, 200);
  const rows = statRows(o.db);
  const top = rows.find((r) => r.sql_hash === sqlHash(normalizeSql(TOP_SQL)));
  assert.ok(top, `the /top read was counted: ${JSON.stringify(rows.map((r) => r.sql_text))}`);
  assert.equal(top.calls, 1);
  const again = await call(o.DB, '/api/d1/stmt-stats/top?hours=1&n=20');
  assert.ok(again.body.rows.some((r) => r.sql_hash === top.sql_hash), 'the /top answer shows its own counted read');
  // the flush's upsert and the knob read never count themselves
  assert.ok(!rows.some((r) => /INSERT INTO d1_stmt_stats|d1\.stmt_stats|WHERE key IN/.test(r.sql_text)), JSON.stringify(rows.map((r) => r.sql_text)));
  // every own property of the handler object is kept by the wrap
  for (const k of ['ROUTES', 'OPEN_ROUTES', 'CREATED_TABLES', 'MACHINE_STATES', 'MACHINE_TERMINAL']) assert.ok(worker[k], k);
});

test('S11 a failed flush is dropped without a throw; the overflow key caps the accumulator', async (t) => {
  const o = await fresh(t); if (!o) return;
  setting(o.db, 'd1.stmt_stats_sample_pct', 100);
  setting(o.db, 'd1.stmt_stats_max_keys', 10);
  await loadStmtStatsKnobs(o.DB);
  const db = stmtStatsDb(o.DB);
  for (let i = 0; i < 15; i++) await db.prepare(`SELECT ${i} AS x${i} FROM settings LIMIT 1`).first();
  assert.equal(await flushStmtStats(o.DB), 11, '10 keys plus the overflow key');
  const over = o.db.prepare('SELECT calls, sql_text FROM d1_stmt_stats WHERE sql_hash = ?').get(OVERFLOW_HASH);
  assert.equal(over.calls, 5);
  assert.equal(over.sql_text, '(overflow)');
  // a flush that throws: no throw out, the counts are gone, the next flush is empty
  await db.prepare('SELECT 1 AS a').first();
  const broken = { prepare: (s) => o.DB.prepare(s), batch: async () => { throw new Error('D1 DB is overloaded'); } };
  const warns = [];
  const realWarn = console.warn;
  console.warn = (m) => warns.push(String(m));
  try { assert.equal(await flushStmtStats(broken), 0); } finally { console.warn = realWarn; }
  assert.equal(warns.length, 1);
  assert.match(warns[0], /stmt-stats: flush of 1 key\(s\) dropped/);
  assert.equal(await flushStmtStats(o.DB), 0);
  // a handler that throws: the throw is unchanged and the flush still runs
  const w = withStmtStats({ async fetch(req, e) { await e.DB.prepare('SELECT 9 AS z').first(); throw new Error('route bug'); } }, { random: () => 0 });
  const ctx = new Ctx();
  await assert.rejects(() => w.fetch(new Request('https://jobs.test/x'), { DB: o.DB }, ctx), /route bug/);
  await settle(ctx);
  assert.ok(o.db.prepare('SELECT 1 FROM d1_stmt_stats WHERE sql_hash = ?').get(sqlHash(normalizeSql('SELECT 9 AS z'))));
});
