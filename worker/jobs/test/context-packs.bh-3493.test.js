import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker, { CREATED_TABLES } from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-3493 (BH-3478.1) — the hub side of the split-child context-pack wire:
// the context_packs table, POST/GET /api/context-packs, the stage.plan.child
// route seed and the two child-plan settings seeds. Driven against THE SQL
// THAT SHIPS, through worker.fetch, the same idiom as
// model-routes-seed.bh-1908.test.js.
const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

// Copied from model-routes-seed.bh-1908.test.js (test files stay independent).
function sqliteDB(db) {
  const prepare = (sql) => {
    const bindAndRun = (binds) => ({
      first: async () => db.prepare(sql).get(...binds) ?? null,
      all: async () => ({ results: db.prepare(sql).all(...binds) }),
      run: async () => {
        const r = db.prepare(sql).run(...binds);
        return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
      },
    });
    return { ...bindAndRun([]), bind: (...binds) => { const s = bindAndRun(binds); s._sql = sql; s._binds = binds; return s; } };
  };
  return {
    prepare,
    batch: async (xs) => xs.map((x) => {
      const r = db.prepare(x._sql).run(...(x._binds || []));
      return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
    }),
  };
}

const openDb = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return db; };

const call = (DB, path, { method = 'GET', body, auth = true } = {}) => {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  const req = new Request(`https://jobs.test${path}`, {
    method, headers,
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const post = (DB, body, opts = {}) => call(DB, '/api/context-packs', { method: 'POST', body, ...opts });
const get = (DB, qs, opts = {}) => call(DB, `/api/context-packs?${qs}`, opts);
const rows = (db) => db.prepare('SELECT count(*) AS n FROM context_packs').get().n;

const CONTRACT_KEYS = ['base_sha', 'box', 'bytes', 'created_at', 'pack_md', 'parent_key', 'project', 'ticket_key', 'updated_at'];
const good = (over = {}) => ({
  project: 'cromford', ticket_key: 'BH-9001', parent_key: 'BH-9000',
  base_sha: 'ABCDEF1', pack_md: '# map\nx', box: 'hub', ...over,
});

test('R1 round trip: POST answers the row without pack_md, GET answers exactly the contract keys', async () => {
  const db = openDb(); const DB = sqliteDB(db);
  const p = await post(DB, good());
  assert.equal(p.status, 200, JSON.stringify(p.body));
  assert.equal(p.body.context_pack.bytes, 7);
  assert.equal(p.body.context_pack.parent_key, 'BH-9000');
  assert.ok(!('pack_md' in p.body.context_pack), 'POST answer must not echo pack_md');
  const g = await get(DB, 'project=cromford&key=BH-9001');
  assert.equal(g.status, 200, JSON.stringify(g.body));
  assert.deepEqual(Object.keys(g.body.context_pack).sort(), CONTRACT_KEYS);
  assert.equal(g.body.context_pack.pack_md, '# map\nx');
  assert.equal(g.body.context_pack.base_sha, 'abcdef1');
  assert.equal(g.body.context_pack.box, 'hub');
  assert.equal(g.body.context_pack.project, 'cromford');
  assert.equal(g.body.context_pack.ticket_key, 'BH-9001');
  assert.ok(g.body.as_of, 'as_of present');
});

test('R2 413 over 64000 BYTES, nothing stored; exactly 64000 is stored', async () => {
  const db = openDb(); const DB = sqliteDB(db);
  const big = await post(DB, good({ pack_md: 'a'.repeat(64001) }));
  assert.equal(big.status, 413);
  assert.equal(big.body.bytes, 64001);
  assert.equal(big.body.max, 64000);
  assert.equal((await get(DB, 'project=cromford&key=BH-9001')).status, 404);
  const euro = await post(DB, good({ pack_md: '€'.repeat(21334) }));
  assert.equal(euro.status, 413, 'multi-byte text is measured in bytes, not .length');
  assert.equal(rows(db), 0);
  const edge = await post(DB, good({ pack_md: 'b'.repeat(64000) }));
  assert.equal(edge.status, 200);
  const g = await get(DB, 'project=cromford&key=BH-9001');
  assert.equal(g.body.context_pack.pack_md.length, 64000, 'stored whole, never sliced');
  assert.equal(g.body.context_pack.bytes, 64000);
});

test('R3 a 413 does not clobber an existing good pack', async () => {
  const db = openDb(); const DB = sqliteDB(db);
  assert.equal((await post(DB, good({ pack_md: 'original' }))).status, 200);
  assert.equal((await post(DB, good({ pack_md: 'z'.repeat(64001) }))).status, 413);
  const g = await get(DB, 'project=cromford&key=BH-9001');
  assert.equal(g.status, 200);
  assert.equal(g.body.context_pack.pack_md, 'original');
});

test('R4 400 on self-parent, bad keys, empty/whitespace/non-string pack_md; nothing stored', async () => {
  const db = openDb(); const DB = sqliteDB(db);
  const cases = {
    'self-parent': good({ parent_key: 'BH-9001' }),
    'bad project': good({ project: 'a b' }),
    'bad ticket_key': good({ ticket_key: '' }),
    'bad parent_key': good({ parent_key: 'x/y' }),
    'empty pack_md': good({ pack_md: '' }),
    'whitespace pack_md': good({ pack_md: '  \n' }),
    'non-string pack_md': good({ pack_md: 42 }),
  };
  for (const [name, body] of Object.entries(cases)) {
    const r = await post(DB, body);
    assert.equal(r.status, 400, `${name}: ${JSON.stringify(r.body)}`);
  }
  assert.equal(rows(db), 0);
});

test('R5 upsert replaces the pack, keeps created_at and a box the second POST omits', async () => {
  const db = openDb(); const DB = sqliteDB(db);
  assert.equal((await post(DB, good({ pack_md: 'first', parent_key: 'BH-9000' }))).status, 200);
  const first = (await get(DB, 'project=cromford&key=BH-9001')).body.context_pack;
  await new Promise((r) => setTimeout(r, 1100));
  const second = good({ pack_md: 'second pack', parent_key: 'BH-8999', base_sha: 'fedcba9' });
  delete second.box;
  assert.equal((await post(DB, second)).status, 200);
  const g = (await get(DB, 'project=cromford&key=BH-9001')).body.context_pack;
  assert.equal(g.pack_md, 'second pack');
  assert.equal(g.parent_key, 'BH-8999');
  assert.equal(g.base_sha, 'fedcba9');
  assert.equal(g.bytes, 11);
  assert.equal(g.box, 'hub');
  assert.equal(g.created_at, first.created_at);
  assert.ok(g.updated_at > g.created_at, `${g.updated_at} > ${g.created_at}`);
  assert.equal(rows(db), 1);
});

test('R6 404 on a miss, and 404 (not 500) on a D1 without the table', async () => {
  const db = openDb(); const DB = sqliteDB(db);
  const miss = await get(DB, 'project=cromford&key=BH-0000-nope');
  assert.equal(miss.status, 404);
  assert.equal(miss.body.error, 'no such context pack');
  const bare = openDb();
  bare.exec('DROP TABLE context_packs');
  const g = await get(sqliteDB(bare), 'project=cromford&key=BH-9001');
  assert.equal(g.status, 404, JSON.stringify(g.body));
  const bare2 = openDb();
  bare2.exec('DROP TABLE context_packs');
  assert.equal((await post(sqliteDB(bare2), good())).status, 200, 'POST self-creates the table too');
});

test('R7 401 without a bearer, and nothing written', async () => {
  const db = openDb(); const DB = sqliteDB(db);
  assert.equal((await post(DB, good(), { auth: false })).status, 401);
  assert.equal((await get(DB, 'project=cromford&key=BH-9001', { auth: false })).status, 401);
  assert.equal(rows(db), 0);
});

test('R8 GET 400 without project or without key', async () => {
  const DB = sqliteDB(openDb());
  assert.equal((await get(DB, 'key=BH-9001')).status, 400);
  assert.equal((await get(DB, 'project=cromford')).status, 400);
});

test('R9 a refused POST never touches D1', async () => {
  const calls = [];
  const DB = { prepare: (sql) => { calls.push(sql); throw new Error('no DB expected'); }, batch: async () => [] };
  assert.equal((await post(DB, good({ parent_key: 'BH-9001' }))).status, 400);
  assert.equal((await post(DB, good({ pack_md: 'q'.repeat(64001) }))).status, 413);
  assert.deepEqual(calls, []);
});

const childRoute = (db) => db.prepare(
  "SELECT position, model, runner, updated_by FROM model_routes WHERE project IS NULL AND role='stage.plan.child'"
).all();

test('S1 stage.plan.child seeds a rung 0 equal to the plan rung 0', () => {
  const db = openDb();
  const plan = db.prepare(
    "SELECT model, runner FROM model_routes WHERE project IS NULL AND role='plan' AND position=0"
  ).get();
  assert.ok(plan, 'plan rung 0 exists in the seed');
  const got = childRoute(db);
  assert.equal(got.length, 1);
  assert.equal(got[0].position, 0);
  assert.equal(got[0].updated_by, 'seed');
  assert.equal(got[0].model, plan.model);
  assert.equal(got[0].runner, plan.runner);
});

test('S2 a model_route_changes tombstone stops the re-seed', () => {
  const db = openDb();
  assert.equal(childRoute(db).length, 1, 'seeded before the operator removes it');
  db.exec("DELETE FROM model_routes WHERE project IS NULL AND role='stage.plan.child'");
  db.prepare(
    `INSERT INTO model_route_changes (scope, project, role, position, actor, at)
     VALUES ('hub', NULL, 'stage.plan.child', 0, 'op', '2026-09-29T01:00:00Z')`
  ).run();
  db.exec(SCHEMA);
  assert.equal(childRoute(db).length, 0);
});

test('S3 re-applying schema.sql three times keeps one stage.plan.child row', () => {
  const db = openDb();
  db.exec(SCHEMA); db.exec(SCHEMA);
  assert.equal(childRoute(db).length, 1);
});

test('S4 both settings rows seed, and a re-apply never resets an operator value', () => {
  const db = openDb();
  const s = (k) => db.prepare('SELECT value, actor, note FROM settings WHERE key=?').get(k);
  const pct = s('child_plan_tripwire_pct');
  const delta = s('child_preplan_delta_tokens');
  assert.equal(pct?.value, '50');
  assert.equal(delta?.value, '150000');
  for (const r of [pct, delta]) {
    assert.equal(r.actor, 'seed');
    assert.ok(r.note.startsWith('BH-3478'), r.note);
  }
  db.exec("UPDATE settings SET value='70' WHERE key='child_plan_tripwire_pct'");
  db.exec(SCHEMA);
  assert.equal(s('child_plan_tripwire_pct').value, '70');
});

test('S5 CREATED_TABLES.context_packs matches the schema.sql DDL', () => {
  const ddl = SCHEMA.match(/CREATE TABLE IF NOT EXISTS context_packs \([\s\S]*?\n\);/);
  assert.ok(ddl, 'schema.sql carries the context_packs DDL');
  assert.ok(CREATED_TABLES.context_packs?.[0], 'CREATED_TABLES.context_packs exists');
  const cols = (sql) => {
    const db = new DatabaseSync(':memory:');
    db.exec(sql);
    return db.prepare('PRAGMA table_info(context_packs)').all()
      .map((c) => `${c.name}:${c.type}:${c.notnull}:${c.pk}`);
  };
  const a = cols(ddl[0]);
  assert.equal(a.length, 9);
  assert.deepEqual(cols(CREATED_TABLES.context_packs[0]), a);
});
