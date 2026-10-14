import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker, { CREATED_TABLES } from '../src/index.js';
import { clearCapSeeds } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2563 (BH-2511.0): the cost-caps CONTRACT the BH-2511 siblings build on.
// The cost_cap_changes table exists in schema.sql and in CREATED_TABLES with
// identical shape; the three routes answer through the worker's REAL fetch
// handler, behind the bearer. BH-2564 filled the stubs in: R1-R3 pin the real
// shapes, and worker/jobs/test/cost-caps.bh-2564.test.js owns the behaviour.

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
    batch: async (stmts) => stmts.map((s) => exec(s._sql, s._binds)),
  };
}

function fresh() {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  clearCapSeeds(db); // BH-4155: start from a table with no cap row
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}

async function call(env, method, path, body, { bearer = true } = {}) {
  const headers = {};
  if (bearer) headers.authorization = 'Bearer ' + SECRET;
  const init = { method, headers };
  if (body !== undefined) { headers['content-type'] = 'application/json'; init.body = JSON.stringify(body); }
  const res = await worker.fetch(new Request('https://jobs.test' + path, init), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}

const shape = (db) => ({
  cols: db.prepare('PRAGMA table_info(cost_cap_changes)').all()
    .map((c) => [c.name, c.type, Number(c.notnull), Number(c.pk)]),
  indexes: db.prepare('PRAGMA index_list(cost_cap_changes)').all().map((i) => i.name).sort(),
  keyIdx: db.prepare('PRAGMA index_info(idx_cost_cap_changes_key)').all().map((c) => c.name),
});

const WANT_COLS = [
  ['id', 'INTEGER', 0, 1],
  ['key', 'TEXT', 1, 0],
  ['before_value', 'TEXT', 0, 0],
  ['after_value', 'TEXT', 1, 0],
  ['actor', 'TEXT', 1, 0],
  ['reason', 'TEXT', 0, 0],
  ['at', 'TEXT', 1, 0],
];

test('C1: schema.sql applies twice; cost_cap_changes has the contract columns and the (key, at) index', { skip: !DatabaseSync }, () => {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  db.exec(SCHEMA);
  const s = shape(db);
  assert.deepEqual(s.cols, WANT_COLS);
  assert.deepEqual(s.keyIdx, ['key', 'at']);
  assert.ok(s.indexes.includes('idx_cost_cap_changes_key'));
});

test('C2: CREATED_TABLES.cost_cap_changes alone builds the same table as schema.sql', { skip: !DatabaseSync }, () => {
  assert.ok(Array.isArray(CREATED_TABLES.cost_cap_changes), 'CREATED_TABLES has no cost_cap_changes entry');
  const fromCore = new DatabaseSync(':memory:');
  for (const sql of CREATED_TABLES.cost_cap_changes) fromCore.exec(sql);
  const fromSchema = new DatabaseSync(':memory:');
  fromSchema.exec(SCHEMA);
  assert.deepEqual(shape(fromCore), shape(fromSchema));
  assert.deepEqual(shape(fromCore).cols, WANT_COLS);
});

test('R1: GET /api/cost-cap-changes answers an empty list on a fresh table, with or without a query', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  for (const path of ['/api/cost-cap-changes', '/api/cost-cap-changes?key=conf.cost-caps.default&limit=5']) {
    const r = await call(env, 'GET', path);
    assert.equal(r.status, 200, path);
    assert.deepEqual(r.body.changes, [], path);
    assert.equal(r.body.truncated, false, path);
  }
});

test('R2: PUT /api/cost-caps with a reason writes the row and one audit row', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  const r = await call(env, 'PUT', '/api/cost-caps',
    { key: 'conf.cost-caps.default', value: '100 5', reason: 'r', actor: 'console' });
  assert.equal(r.status, 200);
  assert.equal(r.body.setting.value, '100 5');
  assert.equal(r.body.unchanged, false);
  assert.equal(db.prepare('SELECT count(*) AS n FROM cost_cap_changes').get().n, 1);
});

test('R3: POST /api/cost-caps/seed writes the row under the seed actor', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  const r = await call(env, 'POST', '/api/cost-caps/seed', { rows: [{ key: 'conf.cost-caps.default', value: '100 5' }] });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.changed_keys, ['conf.cost-caps.default']);
  assert.equal(r.body.actor, 'registry-seed');
});

test('R4: the routes stay behind the bearer', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  const r = await call(env, 'GET', '/api/cost-cap-changes', undefined, { bearer: false });
  assert.equal(r.status, 401);
  const p = await call(env, 'PUT', '/api/cost-caps', { key: 'k', value: 'v' }, { bearer: false });
  assert.equal(p.status, 401);
});
