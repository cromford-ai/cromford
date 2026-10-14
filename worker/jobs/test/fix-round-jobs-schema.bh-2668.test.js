import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { CREATED_TABLES } from '../src/lib/core.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2668 (BH-2530.0): the fix_round_jobs table and its two indexes, applied
// from the real schema.sql, and the CREATED_TABLES twin that self-creates it.
// The routes that write it are a sibling slice; here we only prove the SQL.

const SCHEMA = jobsSchemaSql();
const T0 = '2026-09-26T00:00:00Z';

// name, notnull, default — the ticket's 17 columns in order.
const COLUMNS = [
  ['id', 0, null], ['project', 1, null], ['cap_key', 1, null], ['box', 1, null],
  ['args', 1, null], ['record_in', 0, null], ['hotfix', 1, '0'], ['status', 1, null],
  ['attempt', 1, '0'], ['claimed_by', 0, null], ['claimed_at', 0, null], ['result', 0, null],
  ['record_out', 0, null], ['enqueued_at', 1, null], ['finished_at', 0, null],
  ['adopted_at', 0, null], ['updated_at', 1, null],
];

const norm = (s) => s.replace(/\s+/g, ' ').replace(/\( /g, '(').replace(/ \)/g, ')').replace(/;$/, '').trim();

async function open(t) {
  const h = await openDb();
  if (!h) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  return h.db;
}

async function openEmpty(t) {
  let DatabaseSync;
  try { ({ DatabaseSync } = await import('node:sqlite')); } catch { t.skip('node:sqlite unavailable'); return null; }
  return new DatabaseSync(':memory:');
}

function indexColumns(db, index) {
  return db.prepare(`PRAGMA index_info(${index})`).all()
    .sort((a, b) => a.seqno - b.seqno).map((r) => r.name);
}

function shape(db) {
  return db.prepare('PRAGMA table_info(fix_round_jobs)').all()
    .map((c) => [c.name, c.notnull, c.dflt_value]);
}

function insert(db, ck, status) {
  return db.prepare(
    `INSERT INTO fix_round_jobs (project, cap_key, box, args, status, enqueued_at, updated_at)
     VALUES ('cromford', ?, 'box1', '[]', ?, ?, ?)`,
  ).run(ck, status, T0, T0);
}

test('A1: fix_round_jobs has the 17 contract columns, NOT NULLs and defaults', async (t) => {
  const db = await open(t);
  if (!db) return;
  assert.deepEqual(shape(db), COLUMNS);
  const id = db.prepare('PRAGMA table_info(fix_round_jobs)').all().find((c) => c.name === 'id');
  assert.equal(id.pk, 1);
  assert.match(SCHEMA, /id INTEGER PRIMARY KEY AUTOINCREMENT/);
});

test('A2: fix_round_jobs_open allows one un-adopted round per (project, cap_key)', async (t) => {
  const db = await open(t);
  if (!db) return;
  const first = insert(db, 'ck1', 'queued');
  assert.throws(() => insert(db, 'ck1', 'queued'), /UNIQUE constraint failed/);
  assert.throws(() => insert(db, 'ck1', 'claimed'), /UNIQUE constraint failed/);
  // Another park is independent.
  insert(db, 'ck2', 'queued');
  // Once adopted, the row leaves the index and the next park may queue.
  db.prepare(`UPDATE fix_round_jobs SET status='adopted' WHERE id=?`).run(first.lastInsertRowid);
  insert(db, 'ck1', 'queued');
  insert(db, 'ck1-hist', 'adopted');
  insert(db, 'ck1-hist', 'adopted');
  // done still holds the slot.
  insert(db, 'ck3', 'done');
  assert.throws(() => insert(db, 'ck3', 'queued'), /UNIQUE constraint failed/);
  const idx = db.prepare('PRAGMA index_list(fix_round_jobs)').all().find((r) => r.name === 'fix_round_jobs_open');
  assert.ok(idx, 'fix_round_jobs_open exists');
  assert.equal(idx.unique, 1);
  assert.equal(idx.partial, 1);
  assert.deepEqual(indexColumns(db, 'fix_round_jobs_open'), ['project', 'cap_key']);
});

test('A3: fix_round_jobs_box indexes (box, status)', async (t) => {
  const db = await open(t);
  if (!db) return;
  assert.deepEqual(indexColumns(db, 'fix_round_jobs_box'), ['box', 'status']);
});

test('A4: CREATED_TABLES.fix_round_jobs is schema.sql\'s DDL and self-creates idempotently', async (t) => {
  const stmts = CREATED_TABLES.fix_round_jobs;
  assert.ok(Array.isArray(stmts) && stmts.length === 3, 'three statements');
  const table = SCHEMA.match(/^CREATE TABLE IF NOT EXISTS fix_round_jobs \([\s\S]*?\n\);/m);
  assert.ok(table, 'schema.sql has the fix_round_jobs CREATE');
  assert.equal(norm(stmts[0]), norm(table[0]));
  for (const name of ['fix_round_jobs_open', 'fix_round_jobs_box']) {
    const m = SCHEMA.match(new RegExp(`^CREATE (UNIQUE )?INDEX IF NOT EXISTS ${name} [^\\n]*;`, 'm'));
    assert.ok(m, `schema.sql has ${name}`);
    assert.ok(stmts.some((s) => norm(s) === norm(m[0])), `CREATED_TABLES carries ${name}`);
  }
  const db = await openEmpty(t);
  if (!db) return;
  for (let pass = 0; pass < 2; pass++) for (const s of stmts) db.exec(s);
  assert.deepEqual(shape(db), COLUMNS);
  insert(db, 'ck1', 'queued');
  assert.throws(() => insert(db, 'ck1', 'done'), /UNIQUE constraint failed/);
  assert.deepEqual(indexColumns(db, 'fix_round_jobs_box'), ['box', 'status']);
});
