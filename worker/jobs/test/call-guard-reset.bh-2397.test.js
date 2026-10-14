import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2397 item 1: a RESET must supersede the refusals before it. The GET
// roll-up keeps `refused` (every refusal in the window, what the box CLI
// reads) and adds `refused_since_reset` and `reset_at`, so the console's CAP
// HIT can follow only the refusals that came AFTER the operator's reset.
// Driven through the real worker.fetch against schema.sql in node:sqlite, the
// k3 suite's harness. "After" is insertion order (rowid): the route stamps `at`
// to the second, and these tests never read a clock (docs/TEST-DETERMINISM.md).

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

function sqliteDB(db) {
  const prepare = (sql) => {
    const bindAndRun = (binds) => ({
      first: async () => db.prepare(sql).get(...binds.map((v) => (v === undefined ? null : v))) ?? null,
      all: async () => ({ results: db.prepare(sql).all(...binds.map((v) => (v === undefined ? null : v))) }),
      run: async () => {
        const r = db.prepare(sql).run(...binds.map((v) => (v === undefined ? null : v)));
        return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
      },
    });
    return { ...bindAndRun([]), bind: (...binds) => bindAndRun(binds) };
  };
  return { prepare };
}

async function openDb(t) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return db;
}

const call = (db, path, { method = 'POST', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return worker.fetch(req, { DB: sqliteDB(db), HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const KEY = { project: 'project-5', stage: 'review', fp: 'review-prs:acme/app#229@553a9e0' };
const claim = (db, id, key = KEY) => call(db, '/api/call-guard/claim', { body: { ...key, call_id: id, max: 2 } });
const reset = (db, key = KEY) => call(db,
  `/api/call-guard?project=${encodeURIComponent(key.project)}&stage=${key.stage}&fp=${encodeURIComponent(key.fp)}&actor=console&reason=loop`,
  { method: 'DELETE' });
const rollup = async (db) => {
  const r = await call(db, '/api/call-guard?hours=24', { method: 'GET' });
  assert.equal(r.status, 200);
  return r.body.rows;
};
const rowFor = (rows, key = KEY) => rows.find((r) => r.project === key.project && r.stage === key.stage && r.fp === key.fp);

test('a reset supersedes the refusals before it; a refusal after it counts again', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  await claim(db, 'c1');
  await claim(db, 'c2');
  const refused = await claim(db, 'c3');
  assert.equal(refused.body.allowed, false, 'setup: the third claim is refused at max 2');

  let row = rowFor(await rollup(db));
  assert.equal(Number(row.refused), 1);
  assert.equal(Number(row.refused_since_reset), 1, 'before any reset every refusal counts');
  assert.equal(row.reset_at, null);

  const r = await reset(db);
  assert.equal(r.status, 200);
  assert.equal(r.body.reset, 2);

  row = rowFor(await rollup(db));
  assert.equal(Number(row.refused), 1, '`refused` keeps its meaning: every refusal in the window');
  assert.equal(Number(row.refused_since_reset), 0, 'the reset supersedes the refusal before it');
  assert.equal(typeof row.reset_at, 'string');
  assert.match(row.reset_at, /^\d{4}-\d{2}-\d{2}T/);

  // Claim to the ceiling again, then one more: a NEW refusal lights it again.
  assert.equal((await claim(db, 'c4')).body.allowed, true);
  assert.equal((await claim(db, 'c5')).body.allowed, true);
  assert.equal((await claim(db, 'c6')).body.allowed, false);
  row = rowFor(await rollup(db));
  assert.equal(Number(row.refused), 2);
  assert.equal(Number(row.refused_since_reset), 1, 'only the refusal after the reset counts');
  assert.equal(typeof row.reset_at, 'string');
});

test('two resets: the newest governs', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  await claim(db, 'a1'); await claim(db, 'a2'); await claim(db, 'a3');
  await reset(db);
  await claim(db, 'a4'); await claim(db, 'a5'); await claim(db, 'a6');
  let row = rowFor(await rollup(db));
  assert.equal(Number(row.refused_since_reset), 1);
  await reset(db);
  row = rowFor(await rollup(db));
  assert.equal(Number(row.refused), 2);
  assert.equal(Number(row.refused_since_reset), 0, 'the second reset supersedes the refusal between them');
});

test('a key with no reset: refused_since_reset equals refused, reset_at null; resets are per key', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  const OTHER = { ...KEY, fp: 'other-fp' };
  for (const id of ['k1', 'k2', 'k3', 'k4']) await claim(db, id);
  for (const id of ['o1', 'o2', 'o3']) await claim(db, id, OTHER);
  await reset(db, OTHER);
  const rows = await rollup(db);
  const row = rowFor(rows);
  assert.equal(Number(row.refused), 2);
  assert.equal(Number(row.refused_since_reset), 2);
  assert.equal(row.reset_at, null, "another key's reset is not this key's");
  const other = rowFor(rows, OTHER);
  assert.equal(Number(other.refused_since_reset), 0);
  assert.equal(typeof other.reset_at, 'string');
  // ORDER BY refused DESC is unchanged: the un-reset key with 2 refusals first.
  assert.equal(rows[0].fp, KEY.fp);
});
