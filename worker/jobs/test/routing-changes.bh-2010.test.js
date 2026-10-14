import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2010 (BH-1627 follow-up 1): a routing row carries an AUDIT TRAIL, the way
// model_routes does. Every PUT /api/routing that changes a row appends one
// routing_changes row (actor, reason, before -> after) in the SAME batch as the
// upsert; an unchanged PUT is not a decision and writes none; GET
// /api/routing-changes reads the history newest first. Driven through the
// worker's REAL fetch handler over node:sqlite built from schema.sql.

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

const changes = (db) => db.prepare('SELECT * FROM routing_changes ORDER BY id ASC').all();

test('schema.sql applies twice and routing_changes has the audit columns', { skip: !DatabaseSync }, () => {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  db.exec(SCHEMA);
  const cols = db.prepare('PRAGMA table_info(routing_changes)').all().map((c) => c.name);
  assert.deepEqual(cols, ['id', 'project', 'before_builder', 'before_pool_app', 'before_halted',
    'after_builder', 'after_pool_app', 'after_halted', 'actor', 'reason', 'at']);
});

test('a first PUT audits before=NULL -> after, with the actor and reason sent', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  const r = await call(env, 'PUT', '/api/routing',
    { project: 'x', builder: 'pool', pool_app: 'harness-pool-x', halted: 1, actor: 'routing-seed', reason: 'BH-1627 seed from hub flags' });
  assert.equal(r.status, 200);
  const c = changes(db);
  assert.equal(c.length, 1);
  assert.equal(c[0].project, 'x');
  assert.equal(c[0].before_builder, null);
  assert.equal(c[0].before_halted, null);
  assert.equal(c[0].after_builder, 'pool');
  assert.equal(c[0].after_pool_app, 'harness-pool-x');
  assert.equal(c[0].after_halted, 1);
  assert.equal(c[0].actor, 'routing-seed');
  assert.equal(c[0].reason, 'BH-1627 seed from hub flags');
  assert.ok(c[0].at);
});

test('a change audits before -> after; an unchanged PUT writes no audit row', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  await call(env, 'PUT', '/api/routing', { project: 'x', builder: 'pool', pool_app: 'a1', halted: 1, actor: 'seed' });
  const same = await call(env, 'PUT', '/api/routing', { project: 'x', builder: 'pool', pool_app: 'a1', halted: 1, actor: 'seed' });
  assert.equal(same.status, 200);
  assert.equal(changes(db).length, 1, 'an unchanged row is not a decision');
  await call(env, 'PUT', '/api/routing', { project: 'x', builder: 'pool', pool_app: 'a1', halted: 0, actor: 'harness-sync', reason: 'deploy voids pool-halt' });
  const c = changes(db);
  assert.equal(c.length, 2);
  assert.equal(c[1].before_halted, 1);
  assert.equal(c[1].after_halted, 0);
  assert.equal(c[1].before_builder, 'pool');
  assert.equal(c[1].after_builder, 'pool');
  assert.equal(c[1].actor, 'harness-sync');
});

test('no actor is recorded as "api"; actor and reason are bounded', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  await call(env, 'PUT', '/api/routing', { project: 'y', builder: 'fly1', reason: 'r'.repeat(900), actor: 'a'.repeat(300) });
  await call(env, 'PUT', '/api/routing', { project: 'z', builder: 'local' });
  const c = changes(db);
  assert.equal(c[0].actor.length, 128);
  assert.equal(c[0].reason.length, 512);
  assert.equal(c[1].actor, 'api');
  assert.equal(c[1].reason, null);
});

test('an invalid PUT writes neither the row nor an audit row', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  const r = await call(env, 'PUT', '/api/routing', { project: '..', builder: 'pool', actor: 'x' });
  assert.equal(r.status, 400);
  assert.equal(changes(db).length, 0);
});

test('GET /api/routing-changes: newest first, ?project filters, limit + truncated', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  await call(env, 'PUT', '/api/routing', { project: 'x', builder: 'local', actor: 'a' });
  await call(env, 'PUT', '/api/routing', { project: 'y', builder: 'fly1', actor: 'b' });
  await call(env, 'PUT', '/api/routing', { project: 'x', builder: 'fly1', actor: 'c' });
  const all = await call(env, 'GET', '/api/routing-changes');
  assert.equal(all.status, 200);
  assert.deepEqual(all.body.changes.map((c) => c.actor), ['c', 'b', 'a']);
  const x = await call(env, 'GET', '/api/routing-changes?project=x');
  assert.deepEqual(x.body.changes.map((c) => c.actor), ['c', 'a']);
  const one = await call(env, 'GET', '/api/routing-changes?limit=1');
  assert.equal(one.body.changes.length, 1);
  assert.equal(one.body.truncated, true);
  const bad = await call(env, 'GET', '/api/routing-changes?project=..');
  assert.equal(bad.status, 400);
});
