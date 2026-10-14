import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2459: PUT /api/routing takes an optional `expected_updated_at`, the
// row's updated_at as the caller read it. Present, the write is a
// compare-and-swap: a row that moved since the read (or no longer exists)
// answers 409 with the row as it is now, and nothing is written, so a stale
// read can never revert a concurrent change. Absent (or null), the PUT is
// today's upsert. Driven through the worker's REAL fetch handler over
// node:sqlite built from schema.sql, with the same D1 shim as BH-2010.

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
    // D1's batch is one transaction: all statements land or none do.
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

// updated_at is nowIso(), stamped to the SECOND: two writes in one second
// share it and the guard cannot tell them apart. The tests age the first
// write's stamp so the concurrent write always carries a different one.
const age = (db, p) => db.exec(`UPDATE routing SET updated_at='2026-01-01T00:00:00Z' WHERE project='${p}'`);
const changes = (db) => db.prepare('SELECT * FROM routing_changes ORDER BY id ASC').all();
const rowOf = (db, p) => db.prepare('SELECT * FROM routing WHERE project=?').get(p);

test('C1: a change between the read and the guarded PUT answers 409 and is not reverted', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  assert.equal((await call(env, 'PUT', '/api/routing', { project: 'p', builder: 'pool', pool_app: 'a', halted: 0 })).status, 200);
  age(db, 'p');
  const u1 = (await call(env, 'GET', '/api/routing/p')).body.routing.updated_at;
  assert.equal((await call(env, 'PUT', '/api/routing', { project: 'p', builder: 'pool', pool_app: 'b', halted: 0, actor: 'ops' })).status, 200);
  const r = await call(env, 'PUT', '/api/routing',
    { project: 'p', builder: 'pool', pool_app: 'a', halted: 1, actor: 'console', expected_updated_at: u1 });
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'routing changed underneath you');
  assert.equal(r.body.routing.pool_app, 'b');
  const row = rowOf(db, 'p');
  assert.equal(row.pool_app, 'b');
  assert.equal(row.halted, 0);
  assert.equal(changes(db).filter((c) => c.actor === 'console').length, 0);
});

test('C2: a guard that matches the read writes, with one audit row for the sent actor', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  await call(env, 'PUT', '/api/routing', { project: 'p', builder: 'pool', pool_app: 'a', halted: 0 });
  age(db, 'p');
  const u1 = (await call(env, 'GET', '/api/routing/p')).body.routing.updated_at;
  const before = changes(db).length;
  const r = await call(env, 'PUT', '/api/routing',
    { project: 'p', builder: 'pool', pool_app: 'a', halted: 1, actor: 'console', reason: 'halt', expected_updated_at: u1 });
  assert.equal(r.status, 200);
  assert.equal(r.body.routing.halted, 1);
  assert.notEqual(r.body.routing.updated_at, u1);
  assert.equal(rowOf(db, 'p').halted, 1);
  const c = changes(db);
  assert.equal(c.length, before + 1);
  assert.equal(c.at(-1).actor, 'console');
  assert.equal(c.at(-1).before_halted, 0);
  assert.equal(c.at(-1).after_halted, 1);
});

test('C3: a guarded PUT on a project with no row answers 409 with routing:null and creates nothing', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  const r = await call(env, 'PUT', '/api/routing',
    { project: 'ghost', builder: 'local', halted: 1, expected_updated_at: '2026-09-25T00:00:00.000Z' });
  assert.equal(r.status, 409);
  assert.equal(r.body.routing, null);
  assert.equal(rowOf(db, 'ghost'), undefined);
  assert.equal(changes(db).length, 0);
});

test('C4: a malformed guard is a 400, never a silently dropped guard', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  await call(env, 'PUT', '/api/routing', { project: 'p', builder: 'pool', pool_app: 'a', halted: 0 });
  const row0 = rowOf(db, 'p');
  const n0 = changes(db).length;
  for (const bad of ['', 5, {}, 'x'.repeat(65)]) {
    const r = await call(env, 'PUT', '/api/routing',
      { project: 'p', builder: 'local', halted: 1, expected_updated_at: bad });
    assert.equal(r.status, 400, `guard ${JSON.stringify(bad)}`);
    assert.equal(r.body.error, 'expected_updated_at must be the updated_at string you read');
    assert.deepEqual(rowOf(db, 'p'), row0);
    assert.equal(changes(db).length, n0);
  }
});

test('C5: a write landing inside the worker, after its read, still answers 409', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  await call(env, 'PUT', '/api/routing', { project: 'p', builder: 'pool', pool_app: 'a', halted: 0 });
  const u1 = rowOf(db, 'p').updated_at;
  const n0 = changes(db).length;
  const batch = env.DB.batch;
  env.DB.batch = async (stmts) => {
    db.exec("UPDATE routing SET pool_app='z', updated_at='later' WHERE project='p'");
    return batch(stmts);
  };
  const r = await call(env, 'PUT', '/api/routing',
    { project: 'p', builder: 'pool', pool_app: 'a', halted: 1, actor: 'console', expected_updated_at: u1 });
  assert.equal(r.status, 409);
  assert.equal(r.body.routing.pool_app, 'z');
  const row = rowOf(db, 'p');
  assert.equal(row.pool_app, 'z');
  assert.equal(row.halted, 0);
  assert.equal(row.updated_at, 'later');
  assert.equal(changes(db).length, n0);
});

test('C6: without the field (or with null) the PUT overwrites as it always has', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  await call(env, 'PUT', '/api/routing', { project: 'p', builder: 'pool', pool_app: 'a', halted: 0 });
  db.exec("UPDATE routing SET updated_at='whatever' WHERE project='p'");
  const r1 = await call(env, 'PUT', '/api/routing', { project: 'p', builder: 'pool', pool_app: 'b', halted: 1 });
  assert.equal(r1.status, 200);
  assert.equal(rowOf(db, 'p').pool_app, 'b');
  db.exec("UPDATE routing SET updated_at='other' WHERE project='p'");
  const r2 = await call(env, 'PUT', '/api/routing', { project: 'p', builder: 'local', halted: 0, expected_updated_at: null });
  assert.equal(r2.status, 200);
  assert.equal(rowOf(db, 'p').builder, 'local');
  assert.equal(rowOf(db, 'p').pool_app, null);
  // an unguarded PUT on a new project still creates it
  assert.equal((await call(env, 'PUT', '/api/routing', { project: 'q', builder: 'fly1' })).status, 200);
  assert.equal(rowOf(db, 'q').builder, 'fly1');
});
