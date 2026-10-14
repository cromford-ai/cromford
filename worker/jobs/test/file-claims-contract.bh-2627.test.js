import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import * as core from '../src/lib/core.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2627 (BH-2524.0) — the fleet file-claims CONTRACT slice, driven against
// the SQL that ships: the four nullable job_claims columns in schema.sql's
// CREATE (a fresh database), ADDED_COLUMNS.job_claims (the live one, whose
// table predates them), and the four bounds the sibling slices validate with.
// node:sqlite is imported at the top with no skip path, same as
// schema-deploy-queue.bh-1026.test.js: CI runs node 22.

const SCHEMA = jobsSchemaSql();

const OLD_COLS = ['job_id', 'lane', 'attempts', 'max_attempts', 'next_attempt_at',
  'escalate_allowed', 'reason', 'updated_at'];
const NEW_COLS = ['planned_files', 'files_claimed_at', 'files_expires_at', 'overlap_not_before'];

// The job_claims CREATE exactly as it stood before BH-2627: the shape the live
// D1 table has, which only an ALTER can widen.
const PRE_CHANGE_CREATE = `CREATE TABLE job_claims (
  job_id TEXT PRIMARY KEY,
  lane TEXT,
  attempts INTEGER NOT NULL DEFAULT 1,
  max_attempts INTEGER,
  next_attempt_at TEXT,
  escalate_allowed INTEGER,
  reason TEXT,
  updated_at TEXT NOT NULL
);`;

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
    return { ...bindAndRun([]), bind: (...binds) => bindAndRun(binds) };
  };
  return { prepare };
}

const tableInfo = (db) => db.prepare('PRAGMA table_info(job_claims)').all();

test('W1a: the shipped job_claims CREATE carries the four new columns, nullable TEXT, plus the original eight', () => {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const info = tableInfo(db);
  const byName = new Map(info.map((c) => [c.name, c]));
  for (const c of OLD_COLS) assert.ok(byName.has(c), `original column ${c} missing`);
  for (const c of NEW_COLS) {
    const col = byName.get(c);
    assert.ok(col, `new column ${c} missing from the CREATE`);
    assert.equal(col.type, 'TEXT', `${c} type`);
    assert.equal(col.notnull, 0, `${c} must be nullable`);
    assert.equal(col.dflt_value, null, `${c} must have no default (never backfilled)`);
  }
  assert.equal(info.length, OLD_COLS.length + NEW_COLS.length);
});

test('W1b: ADDED_COLUMNS.job_claims names exactly the columns the CREATE added', () => {
  assert.deepEqual(core.ADDED_COLUMNS.job_claims, [
    ['planned_files', 'TEXT'], ['files_claimed_at', 'TEXT'],
    ['files_expires_at', 'TEXT'], ['overlap_not_before', 'TEXT'],
  ]);
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const added = tableInfo(db).map((c) => c.name).filter((n) => !OLD_COLS.includes(n)).sort();
  assert.deepEqual((core.ADDED_COLUMNS.job_claims || []).map(([n]) => n).sort(), added);
});

test('W1c: a pre-change job_claims gains the four columns through ensureColumns, twice is a no-op, old rows read NULL', async () => {
  const db = new DatabaseSync(':memory:');
  db.exec(PRE_CHANGE_CREATE);
  db.prepare("INSERT INTO job_claims (job_id, lane, updated_at) VALUES ('j-old','build/cromford/hub','2026-09-26T00:00:00Z')").run();
  const DB = sqliteDB(db);
  await core.ensureColumns({ DB }, 'job_claims');
  core.addedColumnsReady.delete(DB);           // force a real second pass, not the cache
  await core.ensureColumns({ DB }, 'job_claims');
  const names = tableInfo(db).map((c) => c.name);
  assert.deepEqual(names, [...OLD_COLS, ...NEW_COLS]);
  const row = db.prepare("SELECT * FROM job_claims WHERE job_id='j-old'").get();
  assert.equal(row.lane, 'build/cromford/hub');
  for (const c of NEW_COLS) assert.equal(row[c], null, `${c} on a pre-ALTER row`);
});

test('W1d: the file-claim bounds are exported with the ticket values', () => {
  assert.equal(core.FILE_CLAIM_TTL_MIN_S, 60);
  assert.equal(core.FILE_CLAIM_TTL_MAX_S, 86400);
  assert.equal(core.OVERLAP_NB_MAX_S, 86400);
  assert.equal(core.FILE_CLAIM_LIST_MAX, 200);
});

test('W1e: schema.sql re-applies clean on a fresh database (additive only)', () => {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  assert.doesNotThrow(() => db.exec(SCHEMA));
  assert.equal(tableInfo(db).length, OLD_COLS.length + NEW_COLS.length);
});
