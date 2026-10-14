import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2604: a triage no-signal settle (BH-2542) writes row_source=settled, and
// /api/metrics/llm-spend counts it as `settled`, apart from `refused` (a gate
// refusal). Both are $0 rows, so `usd` and `calls` do not change. Driven
// through the worker's REAL fetch handler over node:sqlite built from
// schema.sql, like llm-spend-lane.bh-2303.test.js.

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();
let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }

function d1(db) {
  const exec = (sql, binds) => {
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
function fresh() {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}
async function call(env, method, path, body) {
  const headers = { authorization: 'Bearer ' + SECRET };
  const init = { method, headers };
  if (body !== undefined) { headers['content-type'] = 'application/json'; init.body = JSON.stringify(body); }
  const res = await worker.fetch(new Request('https://jobs.test' + path, init), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
const DAY = '2026-09-25';
const SINCE = `${DAY}T00:00:00Z`;
let n = 0;
const row = (o) => ({ row_hash: `s${++n}`, line_no: n, ts: `${DAY}T10:00:00Z`, host: 'h', project: 'project-1',
  stage: 'triage-precheck', runner: 'none', model: 'none', rc: 0, cost_usd: 0, lane_id: 'run-triage', ...o });

async function seed() {
  const { db, env } = fresh();
  const r = await call(env, 'POST', '/api/metrics/cost-rows', { box: 'hub', rows: [
    row({ row_source: 'refused', note: 'refused:cap' }),
    row({ row_source: 'settled', note: 'settled:no-signal', ticket: '101' }),
    row({ row_source: 'settled', note: 'settled:no-signal', ticket: '102' }),
    row({ row_source: 'none', runner: 'claude', model: 'm', cost_usd: 0.5 }),
  ] });
  assert.equal(r.status, 200);
  const stored = db.prepare("SELECT COUNT(*) AS c FROM cost_rows WHERE row_source='settled'").get().c;
  assert.equal(Number(stored), 2, 'the settled rows are stored verbatim');
  return env;
}

test('llm-spend?stage= counts settled apart from refused; usd and calls unchanged', { skip: !DatabaseSync }, async () => {
  const env = await seed();
  const r = await call(env, 'GET', `/api/metrics/llm-spend?stage=triage-precheck&since=${SINCE}`);  // determinism: ok since= pins the window to the fixtures' fixed day
  assert.equal(r.status, 200);
  assert.equal(r.body.refused, 1, 'refused keeps its meaning: gate refusals only');
  assert.equal(r.body.settled, 2);
  assert.equal(r.body.calls, 4);
  assert.equal(r.body.usd, 0.5);
});

test('llm-spend?lane=&stage= carries the same settled count', { skip: !DatabaseSync }, async () => {
  const env = await seed();
  const r = await call(env, 'GET', `/api/metrics/llm-spend?lane=run-triage&stage=triage-precheck&since=${SINCE}`);  // determinism: ok since= pins the window to the fixtures' fixed day
  assert.equal(r.status, 200);
  assert.deepEqual([r.body.refused, r.body.settled, r.body.calls, r.body.usd], [1, 2, 4, 0.5]);
});

test('llm-spend?row_source=settled filters to the settles', { skip: !DatabaseSync }, async () => {
  const env = await seed();
  const r = await call(env, 'GET', `/api/metrics/llm-spend?row_source=settled&since=${SINCE}`);  // determinism: ok since= pins the window to the fixtures' fixed day
  assert.equal(r.body.calls, 2);
  assert.equal(r.body.settled, 2);
  assert.equal(r.body.refused, 0);
});

test('no rows: settled is a measured 0, not absent', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  const r = await call(env, 'GET', `/api/metrics/llm-spend?stage=triage-precheck&since=${SINCE}`);  // determinism: ok since= pins the window to the fixtures' fixed day
  assert.equal(r.body.settled, 0);
});
