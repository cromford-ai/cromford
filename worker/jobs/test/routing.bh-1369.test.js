import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1369 (BH-1027.0): the routing table and its three routes, driven through
// the worker's REAL fetch handler over a node:sqlite database built from
// schema.sql, so a missing registration or a bad column fails here.

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
  // BH-2010: PUT /api/routing writes the row and its audit row in one D1 batch
  // (one transaction), so the shim has D1's batch too.
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

async function call(env, method, path, body, opts = {}) {
  const headers = {};
  if (opts.auth !== false) headers.authorization = 'Bearer ' + SECRET;
  const init = { method, headers };
  if (body !== undefined) { headers['content-type'] = 'application/json'; init.body = JSON.stringify(body); }
  const res = await worker.fetch(new Request('https://jobs.test' + path, init), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}

const count = (db) => Number(db.prepare('SELECT count(*) AS n FROM routing').get().n);

test('schema.sql applies twice and routing has exactly the five contract columns', { skip: !DatabaseSync }, () => {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  db.exec(SCHEMA);
  const cols = db.prepare('PRAGMA table_info(routing)').all().map((c) => c.name);
  assert.deepEqual(cols, ['project', 'builder', 'pool_app', 'halted', 'updated_at']);
  // The knob is seeded off (so the console lists it), and re-apply keeps an operator's flip.
  assert.equal(db.prepare("SELECT value FROM settings WHERE key='routing_rows'").get().value, 'off');
  db.prepare("UPDATE settings SET value='on' WHERE key='routing_rows'").run();
  db.exec(SCHEMA);
  assert.equal(db.prepare("SELECT value FROM settings WHERE key='routing_rows'").get().value, 'on');
});

test('PUT then GET round-trips a row; list is ordered by project', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  const put = await call(env, 'PUT', '/api/routing', { project: 'project-3', builder: 'pool', pool_app: 'pool-project-3', halted: true });
  assert.equal(put.status, 200);
  assert.equal(put.body.routing.builder, 'pool');
  const got = await call(env, 'GET', '/api/routing/project-3');
  assert.equal(got.status, 200);
  assert.deepEqual(Object.keys(got.body.routing).sort(), ['builder', 'halted', 'pool_app', 'project', 'updated_at']);
  assert.equal(got.body.routing.pool_app, 'pool-project-3');
  assert.equal(got.body.routing.halted, 1);
  await call(env, 'PUT', '/api/routing', { project: 'alpha', builder: 'local', halted: 'yes' });
  const alpha = await call(env, 'GET', '/api/routing/alpha');
  assert.equal(alpha.body.routing.pool_app, null);
  assert.equal(alpha.body.routing.halted, 0);
  const list = await call(env, 'GET', '/api/routing');
  assert.equal(list.status, 200);
  assert.deepEqual(list.body.routing.map((r) => r.project), ['alpha', 'project-3']);
  const again = await call(env, 'PUT', '/api/routing', { project: 'project-3', builder: 'fly1' });
  assert.equal(again.body.routing.builder, 'fly1');
  assert.equal(again.body.routing.pool_app, null);
});

test('invalid PUTs are 400 and write nothing', { skip: !DatabaseSync }, async () => {
  const { db, env } = fresh();
  const bads = [
    { project: 'x', builder: 'banana' }, { project: 'x', builder: '' }, { project: 'x', builder: 'Local' },
    { project: 'x', builder: 'POOL' }, { project: 'x', builder: 'fly' }, { project: 'x', builder: 'fly2' },
    { project: '', builder: 'local' }, { project: 'a/b', builder: 'local' },
    { project: 'x', builder: 'pool', pool_app: 'a/b' }, { project: 'x', builder: 'pool', pool_app: '../x' },
    { project: 'x', builder: 'pool', pool_app: 'x y' },
    // `.` and `..` pass the character class but name the flags/ dir itself or
    // its parent; the client (_routing_name_ok) refuses them, so must the worker.
    { project: '.', builder: 'local' }, { project: '..', builder: 'local' },
    { project: 'x', builder: 'pool', pool_app: '.' }, { project: 'x', builder: 'pool', pool_app: '..' },
  ];
  for (const b of bads) {
    const r = await call(env, 'PUT', '/api/routing', b);
    assert.equal(r.status, 400, JSON.stringify(b));
  }
  assert.equal(count(db), 0);
});

test('pool_app is stored only for builder=pool; local and fly1 rows store NULL', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  for (const builder of ['local', 'fly1']) {
    const put = await call(env, 'PUT', '/api/routing', { project: 'z-' + builder, builder, pool_app: 'pool-z' });
    assert.equal(put.status, 200, builder);
    assert.equal(put.body.routing.pool_app, null, builder);
  }
  const pool = await call(env, 'PUT', '/api/routing', { project: 'z-pool', builder: 'pool', pool_app: 'pool-z' });
  assert.equal(pool.body.routing.pool_app, 'pool-z');
});

test('a torn percent-escape in the prefix GET is a 400, never a 500', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  const r = await call(env, 'GET', '/api/routing/%E0%A4%A');
  assert.equal(r.status, 400);
});

test('prefix GET is exact: project-3 never answers project-3; miss is 404; bearer required', { skip: !DatabaseSync }, async () => {
  const { env } = fresh();
  await call(env, 'PUT', '/api/routing', { project: 'project-3', builder: 'fly1' });
  // Positive half first, so the 404s below cannot pass on a worker with no route.
  const hit = await call(env, 'GET', '/api/routing/project-3');
  assert.equal(hit.status, 200);
  assert.equal(hit.body.routing.project, 'project-3');
  assert.equal((await call(env, 'GET', '/api/routing/project-3')).status, 404);
  assert.equal((await call(env, 'GET', '/api/routing/nope')).status, 404);
  assert.equal((await call(env, 'GET', '/api/routing', undefined, { auth: false })).status, 401);
  assert.equal((await call(env, 'PUT', '/api/routing', { project: 'y', builder: 'local' }, { auth: false })).status, 401);
});
