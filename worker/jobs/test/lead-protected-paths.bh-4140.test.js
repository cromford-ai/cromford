import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker, { CREATED_TABLES } from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-4146 (BH-4140.1) — the protected-path globs as rows. Driven through
// worker.fetch (the bearer gate and the ROUTES table included) against THE SQL
// THAT SHIPS, so the one-live-row rule is the partial unique index's, not a
// stub's.
const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

function sqliteDB(db) {
  const bindAndRun = (sql, binds) => ({
    first: async () => db.prepare(sql).get(...binds) ?? null,
    all: async () => ({ results: db.prepare(sql).all(...binds) }),
    run: async () => {
      const r = db.prepare(sql).run(...binds);
      return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
    },
  });
  return {
    prepare: (sql) => ({ ...bindAndRun(sql, []), bind: (...b) => bindAndRun(sql, b.map((v) => (v === undefined ? null : v))) }),
  };
}

const openDb = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return db; };
const fresh = () => { const raw = openDb(); return { raw, DB: sqliteDB(raw) }; };
const count = (raw) => Number(raw.prepare('SELECT COUNT(*) AS n FROM lead_protected_paths').get().n);

const call = (DB, path, { method = 'GET', body, secret = SECRET } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { ...(secret ? { authorization: `Bearer ${secret}` } : {}), 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const put = (DB, body, opts = {}) => call(DB, '/api/lead-protected-paths', { method: 'PUT', body, ...opts });
const get = (DB, qs) => call(DB, `/api/lead-protected-paths?${qs}`);

const ADD = { repo: 'example-org/cromford', glob: 'tmp/**', op: 'add', added_by: 't' };
const REMOVE = { repo: 'example-org/cromford', glob: 'tmp/**', op: 'remove' };

test('1. the schema applies twice, and the self-create copy over it, with no error', () => {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  db.exec(SCHEMA);
  assert.ok(Array.isArray(CREATED_TABLES.lead_protected_paths) && CREATED_TABLES.lead_protected_paths.length === 2);
  for (const sql of CREATED_TABLES.lead_protected_paths) db.prepare(sql).run();
  for (const sql of CREATED_TABLES.lead_protected_paths) db.prepare(sql).run();
  const idx = db.prepare("SELECT sql FROM sqlite_master WHERE type='index' AND name='lpp_live'").get();
  assert.match(idx.sql, /UNIQUE INDEX lpp_live ON lead_protected_paths\(repo, glob\) WHERE removed_at IS NULL/);
});

test('1b. ensureTable alone creates the table (schema apply skipped)', async () => {
  const raw = new DatabaseSync(':memory:');
  const r = await call(sqliteDB(raw), '/api/lead-protected-paths?repo=example-org/cromford');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { rows: [] });
});

test('2. no bearer (and a wrong bearer) gives 401 on GET and PUT, and writes nothing', async () => {
  const { raw, DB } = fresh();
  for (const secret of [null, 'wrong']) {
    assert.equal((await put(DB, ADD, { secret })).status, 401);
    assert.equal((await call(DB, '/api/lead-protected-paths?repo=example-org/cromford', { secret })).status, 401);
  }
  assert.equal(count(raw), 0);
});

test('3. add then GET shows the row, in the ticket shape (no id)', async () => {
  const { DB } = fresh();
  const a = await put(DB, ADD);
  assert.equal(a.status, 201);
  assert.equal(a.body.created, true);
  const g = await get(DB, 'repo=example-org/cromford');
  assert.equal(g.status, 200);
  assert.equal(g.body.rows.length, 1);
  const row = g.body.rows[0];
  assert.deepEqual(Object.keys(row).sort(), ['added_at', 'added_by', 'glob', 'removed_at', 'repo']);
  assert.equal(row.glob, 'tmp/**');
  assert.equal(row.repo, 'example-org/cromford');
  assert.equal(row.added_by, 't');
  assert.equal(row.removed_at, null);
  assert.match(row.added_at, /^\d{4}-\d\d-\d\dT/);
});

test('4. a duplicate add answers 200 created:false and creates no second row', async () => {
  const { raw, DB } = fresh();
  assert.equal((await put(DB, ADD)).status, 201);
  const d = await put(DB, { ...ADD, added_by: 'someone-else' });
  assert.equal(d.status, 200);
  assert.equal(d.body.created, false);
  assert.equal(d.body.row.added_by, 't', 'the existing live row is answered, not the request');
  assert.equal(count(raw), 1);
});

test('5. remove hides the row from the live list; ?all=1 keeps it; a re-add is a new row', async () => {
  const { raw, DB } = fresh();
  await put(DB, ADD);
  const r = await put(DB, REMOVE);
  assert.equal(r.status, 200);
  assert.equal(r.body.removed, true);
  assert.notEqual(r.body.row.removed_at, null);
  assert.equal((await get(DB, 'repo=example-org/cromford')).body.rows.length, 0);
  const all = await get(DB, 'repo=example-org/cromford&all=1');
  assert.equal(all.body.rows.length, 1);
  assert.notEqual(all.body.rows[0].removed_at, null);
  assert.equal((await put(DB, ADD)).status, 201);
  const all2 = await get(DB, 'repo=example-org/cromford&all=1');
  assert.equal(all2.body.rows.length, 2);
  assert.notEqual(all2.body.rows[0].removed_at, null);
  assert.equal(all2.body.rows[1].removed_at, null);
  assert.equal((await get(DB, 'repo=example-org/cromford')).body.rows.length, 1);
  assert.equal(count(raw), 2, 'no row was DELETEd');
});

test('6. a bad glob gives 400 and writes nothing; 200 chars is the boundary', async () => {
  const { raw, DB } = fresh();
  for (const glob of [' tmp', 'tmp ', 'a b', 'a\tb', 'tmp/**\n', '', 'x'.repeat(201), 123, null, undefined]) {
    const r = await put(DB, { ...ADD, glob });
    assert.equal(r.status, 400, `glob ${JSON.stringify(glob)}`);
    assert.match(r.body.error, /glob/);
  }
  assert.equal(count(raw), 0);
  assert.equal((await put(DB, { ...ADD, glob: 'x'.repeat(200) })).status, 201);
  assert.equal(count(raw), 1);
});

test('7. a remove of a non-live row gives 404, the first time and the second', async () => {
  const { raw, DB } = fresh();
  const never = await put(DB, { ...REMOVE, glob: 'never/**' });
  assert.equal(never.status, 404);
  assert.equal(never.body.error, 'not live');
  await put(DB, ADD);
  assert.equal((await put(DB, REMOVE)).status, 200);
  assert.equal((await put(DB, REMOVE)).status, 404);
  assert.equal(count(raw), 1);
});

test('8. a mixed-case repo is stored lowercased and found by any case; the glob keeps its case', async () => {
  const { raw, DB } = fresh();
  assert.equal((await put(DB, { ...ADD, repo: 'example-org/Cromford', glob: 'Docs/X.md' })).status, 201);
  const row = raw.prepare('SELECT repo, glob FROM lead_protected_paths').get();
  assert.equal(row.repo, 'example-org/cromford');
  assert.equal(row.glob, 'Docs/X.md');
  const g = await get(DB, 'repo=example-org/cromford');
  assert.equal(g.body.rows.length, 1);
  assert.equal((await put(DB, { ...ADD, repo: 'example-org/cromford', glob: 'Docs/X.md' })).status, 200);
  assert.equal(count(raw), 1);
  assert.equal((await put(DB, { ...REMOVE, repo: 'example-org/cromford', glob: 'Docs/X.md' })).status, 200);
  assert.equal((await put(DB, { ...ADD, glob: 'docs/x.md' })).status, 201, 'globs are case-sensitive');
});

test('9. bad repo, bad op, add without added_by, GET without repo: each 400, nothing written', async () => {
  const { raw, DB } = fresh();
  for (const repo of ['cromford', 'a/b/c', '', undefined]) {
    const r = await put(DB, { ...ADD, repo });
    assert.equal(r.status, 400, `repo ${JSON.stringify(repo)}`);
    assert.match(r.body.error, /repo/);
  }
  for (const op of ['ADD', 'delete', undefined]) {
    const r = await put(DB, { ...ADD, op });
    assert.equal(r.status, 400, `op ${JSON.stringify(op)}`);
    assert.match(r.body.error, /op/);
  }
  for (const added_by of [undefined, '', 7, 'x'.repeat(129)]) {
    const r = await put(DB, { ...ADD, added_by });
    assert.equal(r.status, 400, `added_by ${JSON.stringify(added_by)}`);
    assert.match(r.body.error, /added_by/);
  }
  assert.equal(count(raw), 0);
  assert.equal((await call(DB, '/api/lead-protected-paths')).status, 400);
  assert.equal((await get(DB, 'repo=nope')).status, 400);
});

test('a missing table that cannot be created answers 503 naming the table, never a 404', async () => {
  const DB = { prepare: () => { throw new Error('D1_ERROR: no such table: lead_protected_paths'); } };
  const r = await put(DB, ADD);
  assert.equal(r.status, 503);
  assert.match(r.body.error, /^lead_protected_paths /);
});
