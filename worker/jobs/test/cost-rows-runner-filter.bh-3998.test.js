import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-3998 (BH-3983.0): GET /api/metrics/cost-rows accepts ?runner=, so a
// reader that only wants one runner's rows (the OpenRouter gap tracer,
// bin/lib/openrouter-ledger.sh) can ask for exactly those. An absent param
// leaves the query as it was.

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();
let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }

// The d1 shim from cost-rows-lane-index.bh-2489.
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
async function call(env, method, path, body) {
  const headers = { authorization: 'Bearer ' + SECRET };
  const init = { method, headers };
  if (body !== undefined) { headers['content-type'] = 'application/json'; init.body = JSON.stringify(body); }
  const res = await worker.fetch(new Request('https://jobs.test' + path, init), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}
async function seeded() {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const env = { DB: d1(db), HARNESS_SECRET: SECRET };
  const base = { host: 'h', project: 'p1', stage: 'prd', model: 'm', rc: 0 };
  const r = await call(env, 'POST', '/api/metrics/cost-rows', { box: 'hub', rows: [
    { ...base, row_hash: 'or1', line_no: 1, ts: '2026-10-01T10:00:00Z', runner: 'openrouter', cost_usd: 1.5 },
    { ...base, row_hash: 'cl1', line_no: 2, ts: '2026-10-01T11:00:00Z', runner: 'claude', cost_usd: 5 },
  ] });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return env;
}

test('W1: ?runner=openrouter returns only the openrouter row', { skip: !DatabaseSync }, async () => {
  const env = await seeded();
  const r = await call(env, 'GET', '/api/metrics/cost-rows?runner=openrouter');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.cost_rows.map((x) => x.row_hash), ['or1']);
});

test('W2: no runner param returns both rows, newest first', { skip: !DatabaseSync }, async () => {
  const env = await seeded();
  const r = await call(env, 'GET', '/api/metrics/cost-rows');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.cost_rows.map((x) => x.row_hash), ['cl1', 'or1']);
});
