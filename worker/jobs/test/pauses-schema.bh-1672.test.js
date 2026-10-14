import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1681 (BH-1672.0): the pauses table, its one-live-row index and the three
// pause_* settings seeds, applied from the real schema.sql. The routes that
// write pauses are a sibling slice; here we only prove the SQL.

const SCHEMA = jobsSchemaSql();

const COLUMNS = [
  'id', 'scope', 'what', 'reason', 'actor',
  'created_at', 'expires_at', 'ended_at', 'end_reason',
];

// pause_flags is the BH-1370 flag-file cache contract; this slice must not move it.
// TEST-CHANGE BH-5635: pause_flags gains the nullable `value` column (the flag
// file's content); the full ordered list stays pinned.
const PAUSE_FLAGS_COLUMNS = ['name', 'active', 'actor', 'reason', 'updated_at', 'value'];

const T0 = '2026-09-24T00:00:00Z';
const T1 = '2026-09-25T00:00:00Z';

async function openDb(t) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  const db = new DatabaseSync(':memory:');
  // Applying twice must never error; the file is how this schema ships.
  db.exec(SCHEMA);
  db.exec(SCHEMA);
  return db;
}

function insert(db, scope, what, endedAt = null) {
  db.prepare(
    `INSERT INTO pauses (scope, what, reason, actor, created_at, expires_at, ended_at, end_reason)
     VALUES (?, ?, 'r', 'a', ?, ?, ?, ?)`,
  ).run(scope, what, T0, T1, endedAt, endedAt ? 'resumed' : null);
}

test('pauses table has the contract columns and id is the pk', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  const cols = db.prepare('PRAGMA table_info(pauses)').all();
  assert.deepEqual(cols.map((c) => c.name), COLUMNS);
  assert.equal(cols.find((c) => c.name === 'id').pk, 1);
  for (const n of ['scope', 'what', 'reason', 'actor', 'created_at', 'expires_at']) {
    assert.equal(cols.find((c) => c.name === n).notnull, 1, `${n} NOT NULL`);
  }
  for (const n of ['ended_at', 'end_reason']) {
    assert.equal(cols.find((c) => c.name === n).notnull, 0, `${n} nullable`);
  }
});

test('pauses_live index exists on pauses', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  const idx = db.prepare("SELECT tbl_name, sql FROM sqlite_master WHERE type='index' AND name='pauses_live'").get();
  assert.ok(idx, 'pauses_live index present');
  assert.equal(idx.tbl_name, 'pauses');
});

test('a second live (scope, what) insert fails', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  insert(db, 'fleet', 'merges');
  assert.throws(() => insert(db, 'fleet', 'merges'), /UNIQUE/);
  // A different scope or a different what is its own pause.
  insert(db, 'projA', 'merges');
  insert(db, 'fleet', 'reviews');
});

test('a live row plus ended rows for the same pair are all allowed', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  insert(db, 'projA', 'builds', T0);
  insert(db, 'projA', 'builds', T0);
  insert(db, 'projA', 'builds');
  const n = db.prepare("SELECT COUNT(*) AS n FROM pauses WHERE scope='projA' AND what='builds'").get().n;
  assert.equal(n, 3);
});

test('what outside the four lanes is refused', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  assert.throws(() => insert(db, 'fleet', 'bogus'), /CHECK/);
  for (const w of ['reviews', 'merges', 'builds', 'triage']) insert(db, 'fleet', w);
});

test('the three pause_* settings are seeded and a re-apply keeps an operator value', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  const get = (k) => db.prepare('SELECT value, actor FROM settings WHERE key = ?').get(k);
  assert.deepEqual({ ...get('pause_default_ttl_s') }, { value: '86400', actor: 'seed' });
  assert.deepEqual({ ...get('pause_env_review_cap_below') }, { value: '5', actor: 'seed' });
  assert.deepEqual({ ...get('pause_env_laneoff_age_s') }, { value: '86400', actor: 'seed' });
  db.prepare("UPDATE settings SET value='7' WHERE key='pause_env_review_cap_below'").run();
  db.exec(SCHEMA);
  assert.equal(get('pause_env_review_cap_below').value, '7');
});

test('pause_flags is untouched', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  const cols = db.prepare('PRAGMA table_info(pause_flags)').all();
  assert.deepEqual(cols.map((c) => c.name), PAUSE_FLAGS_COLUMNS);
});
