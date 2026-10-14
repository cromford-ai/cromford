import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { ensureColumns } from '../src/lib/core.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2489: the pre-call spend gate asks GET /api/metrics/llm-spend?lane=… once
// per registered stage on every capped model call, and that query was one
// statement with a parameter-dependent OR over a cost_rows table with no index
// on stage or lane_id — a full scan per stage, billed per row read by D1. The
// worker now creates (lane_id, ts) and (stage, ts) right after ensureColumns
// adds lane_id (never in schema.sql, #2473), and the lane branch picks one of
// two constant statements so each can use its index.
//
// The plans below are node:sqlite's. D1 is SQLite, but the live plan is not
// probed from this suite.

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();
let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }

// The d1 shim from llm-spend-lane.bh-2303, plus a record of every statement
// run and an optional hook that rejects some of them.
function d1(db, { log = [], reject = null } = {}) {
  const exec = (sql, binds) => {
    log.push({ sql, binds });
    if (reject && reject(sql)) throw new Error('D1_ERROR: rejected by test shim');
    const stmt = db.prepare(sql);
    if (/^\s*(SELECT|PRAGMA)\b/i.test(sql)) return { results: stmt.all(...binds), meta: { changes: 0 } };
    const r = stmt.run(...binds);
    return { results: [], meta: { changes: Number(r.changes) } };
  };
  const make = (sql, binds) => ({
    _sql: sql, _binds: binds,
    bind: (...b) => make(sql, b),
    run: async () => exec(sql, binds),
    first: async () => { const r = exec(sql, binds); return r.results.length ? r.results[0] : null; },
    all: async () => exec(sql, binds),
  });
  return {
    prepare: (sql) => make(sql, []),
    batch: async (stmts) => {
      db.exec('BEGIN');
      try { const out = stmts.map((s) => exec(s._sql, s._binds)); db.exec('COMMIT'); return out; }
      catch (e) { db.exec('ROLLBACK'); throw e; }
    },
  };
}
// The LIVE table's shape on deploy day: schema.sql's cost_rows without lane_id.
function preLaneDb() {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  for (const ix of db.prepare("SELECT name, sql FROM sqlite_master WHERE type='index' AND tbl_name='cost_rows' AND sql IS NOT NULL").all()) {
    if (/\blane_id\b/.test(ix.sql)) db.exec(`DROP INDEX ${ix.name}`);
  }
  db.exec('ALTER TABLE cost_rows DROP COLUMN lane_id');
  return db;
}
function fresh(opts) {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const log = [];
  return { db, log, env: { DB: d1(db, { log, ...opts }), HARNESS_SECRET: SECRET } };
}
async function call(env, method, path, body) {
  const headers = { authorization: 'Bearer ' + SECRET };
  const init = { method, headers };
  if (body !== undefined) { headers['content-type'] = 'application/json'; init.body = JSON.stringify(body); }
  const res = await worker.fetch(new Request('https://jobs.test' + path, init), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const indexes = (db) => db.prepare('PRAGMA index_list(cost_rows)').all().map((r) => r.name);
const DAY = '2026-09-25';
let n = 0;
const row = (o) => ({ row_hash: `h${++n}`, line_no: n, ts: `${DAY}T10:00:00Z`, host: 'h', project: 'p1',
  stage: 'prd', runner: 'claude', model: 'm', rc: 0, cost_usd: 1, ...o });

// The spend statement the real route ran for `path`, and its query plan.
async function planFor(path) {
  const { db, log, env } = fresh();
  const r = await call(env, 'GET', path);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const q = log.filter((e) => /FROM cost_rows/i.test(e.sql) && /SUM\(/i.test(e.sql));
  assert.equal(q.length, 1, `expected one spend statement, saw ${q.length}`);
  const plan = db.prepare('EXPLAIN QUERY PLAN ' + q[0].sql).all(...q[0].binds).map((p) => p.detail).join(' | ');
  return plan;
}

test('ensureColumns creates both indexes on a pre-lane_id cost_rows', { skip: !DatabaseSync }, async () => {
  const db = preLaneDb();
  assert.ok(!indexes(db).includes('idx_cost_rows_lane_ts'), 'precondition: no lane index yet');
  await ensureColumns({ DB: d1(db) }, 'cost_rows');
  const cols = db.prepare('PRAGMA table_info(cost_rows)').all().map((c) => c.name);
  assert.ok(cols.includes('lane_id'), `cost_rows columns: ${cols.join(',')}`);
  const ix = indexes(db);
  assert.ok(ix.includes('idx_cost_rows_lane_ts'), `indexes: ${ix.join(',')}`);
  assert.ok(ix.includes('idx_cost_rows_stage_ts'), `indexes: ${ix.join(',')}`);
  // Idempotent: a second isolate running it again is a no-op, not an error.
  await ensureColumns({ DB: d1(db) }, 'cost_rows');
});

test('ensureColumns creates no index on any other table', { skip: !DatabaseSync }, async () => {
  const { log, env } = fresh();
  await ensureColumns(env, 'pr_costs');
  assert.ok(!log.some((e) => /CREATE INDEX/i.test(e.sql)), log.map((e) => e.sql).join('\n'));
});

test('a failing index create neither fails ensureColumns nor the cost-rows ingest', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh({ reject: (sql) => /^\s*CREATE INDEX/i.test(sql) });
  const warn = console.warn; const warned = [];
  console.warn = (...a) => warned.push(a.join(' '));
  try {
    const r = await call(env, 'POST', '/api/metrics/cost-rows', { box: 'hub', rows: [row({ lane_id: 'run-product' })] });
    assert.equal(r.status, 200, JSON.stringify(r.body));
  } finally { console.warn = warn; }
  assert.equal(db.prepare('SELECT COUNT(*) AS c FROM cost_rows').get().c, 1);
  assert.ok(warned.some((w) => /idx_cost_rows/.test(w)), `the failure is logged: ${warned.join(' / ')}`);
});

test('llm-spend?lane=&stage= uses idx_cost_rows_stage_ts, never a scan', { skip: !DatabaseSync }, async () => {
  const plan = await planFor(`/api/metrics/llm-spend?stage=prd&since=${DAY}T00:00:00Z&lane=run-product`);  // determinism: ok since= pins the window to a fixed day
  assert.match(plan, /idx_cost_rows_stage_ts/, plan);
  assert.doesNotMatch(plan, /SCAN cost_rows/, plan);
  // One range read. The pre-split OR'd statement also avoided the scan once the
  // indexes existed, but as a MULTI-INDEX OR that walked every row the lane
  // wrote today (any stage) on top of the stage's rows, and D1 bills each one.
  assert.doesNotMatch(plan, /MULTI-INDEX OR|idx_cost_rows_lane_ts/, plan);
});

test('llm-spend?lane= with no stage uses idx_cost_rows_lane_ts, never a scan', { skip: !DatabaseSync }, async () => {
  const plan = await planFor(`/api/metrics/llm-spend?since=${DAY}T00:00:00Z&lane=run-product`);  // determinism: ok since= pins the window to a fixed day
  assert.match(plan, /idx_cost_rows_lane_ts/, plan);
  assert.doesNotMatch(plan, /SCAN cost_rows/, plan);
  assert.doesNotMatch(plan, /MULTI-INDEX OR|idx_cost_rows_stage_ts/, plan);
});

test('llm-spend?lane=&project= still reads through an index', { skip: !DatabaseSync }, async () => {
  for (const q of [`project=project-3&stage=prd&since=${DAY}T00:00:00Z&lane=run-product`,  // determinism: ok since= pins the window to a fixed day
                   `project=project-3&since=${DAY}T00:00:00Z&lane=run-product`]) {       // determinism: ok since= pins the window to a fixed day
    const plan = await planFor(`/api/metrics/llm-spend?${q}`);
    assert.match(plan, /idx_cost_rows_(stage_ts|lane_ts|project_ts)/, `${q}: ${plan}`);
    assert.doesNotMatch(plan, /SCAN cost_rows/, `${q}: ${plan}`);
    assert.doesNotMatch(plan, /MULTI-INDEX OR/, `${q}: ${plan}`);
  }
});

test('the split lane query counts the same rows: own + legacy NULL on the stage, never another lane', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  await call(env, 'POST', '/api/metrics/cost-rows', { box: 'hub', rows: [
    row({ lane_id: 'run-product', cost_usd: 3 }),
    row({ cost_usd: 2 }),                                         // legacy NULL lane, same stage
    row({ lane_id: 'review-prs', cost_usd: 40 }),                 // another lane
    row({ lane_id: 'run-product', stage: 'map', cost_usd: 5 }),   // own lane, other stage
    row({ lane_id: 'run-product', cost_usd: 9, ts: '2026-09-24T10:00:00Z' }), // yesterday
  ] });
  const since = `${DAY}T00:00:00Z`;
  const st = await call(env, 'GET', `/api/metrics/llm-spend?stage=prd&since=${since}&lane=run-product`);  // determinism: ok since= pins the window to a fixed day
  assert.equal(st.body.usd, 5, 'prd: own 3 + legacy 2');
  assert.equal(st.body.calls, 2);
  const bare = await call(env, 'GET', `/api/metrics/llm-spend?since=${since}&lane=run-product`);  // determinism: ok since= pins the window to a fixed day
  assert.equal(bare.body.usd, 8, 'no stage: own stamped rows only, any stage (3 + 5)');
  const until = await call(env, 'GET', `/api/metrics/llm-spend?stage=prd&since=2026-09-24T00:00:00Z&until=2026-09-24T23:59:59Z&lane=run-product`);
  assert.equal(until.body.usd, 9, 'until= still bounds the window');
});

test('schema.sql never names the cap-query indexes (#2473)', () => {
  assert.doesNotMatch(SCHEMA, /idx_cost_rows_lane_ts/);
  assert.doesNotMatch(SCHEMA, /idx_cost_rows_stage_ts/);
});
