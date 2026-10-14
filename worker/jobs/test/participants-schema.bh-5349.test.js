import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { CREATED_TABLES, ADDED_COLUMNS, ensureTable, ensureColumns } from '../src/lib/core.js';
import { d1 } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-5349 (BH-5348.0): the participant_machines table, its self-create copy,
// the sibling columns that arrive by ensureColumns and the claim-staleness seed.
// Every check runs real SQLite over THE SQL THAT SHIPS (schema.sql).
const SCHEMA = jobsSchemaSql();

const cols = (db, t) => db.prepare(`PRAGMA table_info(${t})`).all()
  .map(({ name, type, notnull, dflt_value, pk }) => ({ name, type, notnull, dflt_value, pk }));
const idx = (db, t) => db.prepare(`SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=? AND name NOT LIKE 'sqlite_autoindex%' ORDER BY name`).all(t).map((r) => r.name);

const CONTRACT = ['id', 'name', 'owner', 'requested_roles', 'granted_roles', 'token_sha256', 'billing_account',
  'status', 'requested_at', 'decided_by', 'decided_at', 'revoked_by', 'revoked_at', 'last_seen_at', 'knobs'];

test('1. CREATED_TABLES.participant_machines alone builds the contract columns and the status index', () => {
  assert.ok(Array.isArray(CREATED_TABLES.participant_machines), 'CREATED_TABLES has no participant_machines key');
  const db = new DatabaseSync(':memory:');
  for (const s of CREATED_TABLES.participant_machines) db.exec(s);
  const c = cols(db, 'participant_machines');
  assert.deepEqual(c.map((x) => x.name), CONTRACT);
  const by = Object.fromEntries(c.map((x) => [x.name, x]));
  assert.equal(by.id.pk, 1);
  for (const n of ['name', 'requested_roles', 'token_sha256', 'status', 'requested_at']) assert.equal(by[n].notnull, 1, n);
  for (const n of ['owner', 'granted_roles', 'billing_account', 'decided_by', 'last_seen_at', 'knobs']) assert.equal(by[n].notnull, 0, n);
  assert.equal(by.status.dflt_value, "'pending'");
  assert.deepEqual(idx(db, 'participant_machines'), ['idx_participant_machines_status']);
  // name and token_sha256 are UNIQUE; status is CHECKed
  const ins = db.prepare("INSERT INTO participant_machines (id,name,requested_roles,token_sha256,status,requested_at) VALUES (?,?,?,?,?,?)");
  ins.run('a', 'n', '[]', 'h1', 'pending', 't');
  assert.throws(() => ins.run('b', 'n', '[]', 'h2', 'pending', 't'), /UNIQUE/);
  assert.throws(() => ins.run('c', 'm', '[]', 'h1', 'pending', 't'), /UNIQUE/);
  assert.throws(() => ins.run('d', 'o', '[]', 'h3', 'admin', 't'), /CHECK/);
});

test('2. schema.sql and CREATED_TABLES build the same participant_machines table and indexes', () => {
  const block = SCHEMA.match(/CREATE TABLE IF NOT EXISTS participant_machines[\s\S]*?\);\s*CREATE INDEX IF NOT EXISTS idx_participant_machines_status[^;]*;/);
  assert.ok(block, 'schema.sql has no participant_machines block');
  const a = new DatabaseSync(':memory:');
  a.exec(block[0]);
  const b = new DatabaseSync(':memory:');
  for (const s of CREATED_TABLES.participant_machines) b.exec(s);
  assert.deepEqual(cols(b, 'participant_machines'), cols(a, 'participant_machines'));
  assert.deepEqual(idx(b, 'participant_machines'), idx(a, 'participant_machines'));
  const sql = (db) => db.prepare("SELECT sql FROM sqlite_master WHERE name='participant_machines'").get().sql;
  for (const frag of [/name TEXT NOT NULL UNIQUE/, /token_sha256 TEXT NOT NULL UNIQUE/, /CHECK \(status IN \('pending','approved','denied','revoked'\)\)/]) {
    assert.match(sql(a), frag);
    assert.match(sql(b), frag);
  }
});

test('3. schema.sql applies twice cleanly; lead_review_claim_stale_s is seeded 900 exactly once', () => {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  db.exec(SCHEMA);
  const rows = db.prepare("SELECT value FROM settings WHERE key='lead_review_claim_stale_s'").all();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].value, '900');
});

test('4. the sibling columns: lead_review_requests gains three by ensureColumns; cost_rows carries participant both ways', async () => {
  // TEST-CHANGE (merge with main's BH-5400): reset_count / reset_at sit
  // between priority and the three sibling columns; the list is pinned whole.
  // TEST-CHANGE (BH-5779): stale_reclaims follows the three sibling columns.
  assert.deepEqual(ADDED_COLUMNS.lead_review_requests,
    [['priority', 'INTEGER'], ['reset_count', 'INTEGER'], ['reset_at', 'TEXT'],
     ['heartbeat_at', 'TEXT'], ['participant', 'TEXT'], ['head_authors', 'TEXT'],
     ['stale_reclaims', 'INTEGER']]);
  assert.ok(ADDED_COLUMNS.cost_rows.some(([c, t]) => c === 'participant' && t === 'TEXT'));

  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const lr = () => cols(db, 'lead_review_requests').map((c) => c.name);
  for (const c of ['heartbeat_at', 'participant', 'head_authors']) assert.ok(!lr().includes(c), `schema.sql CREATE already has ${c}`);
  await ensureColumns({ DB: d1(db) }, 'lead_review_requests');
  for (const c of ['heartbeat_at', 'participant', 'head_authors']) {
    const col = cols(db, 'lead_review_requests').find((x) => x.name === c);
    assert.ok(col, `ensureColumns did not add ${c}`);
    assert.equal(col.type, 'TEXT');
    assert.equal(col.notnull, 0);
  }
  assert.ok(cols(db, 'cost_rows').some((c) => c.name === 'participant' && c.type === 'TEXT'), 'schema.sql cost_rows has no participant');

  // a live cost_rows built before this change: the CREATE minus participant
  const old = SCHEMA.match(/CREATE TABLE IF NOT EXISTS cost_rows \([\s\S]*?\n\);/)[0].replace(/^\s*participant TEXT,.*$/m, '');
  const live = new DatabaseSync(':memory:');
  live.exec(old);
  assert.ok(!cols(live, 'cost_rows').some((c) => c.name === 'participant'), 'fixture still has participant');
  await ensureColumns({ DB: d1(live) }, 'cost_rows');
  assert.ok(cols(live, 'cost_rows').some((c) => c.name === 'participant' && c.type === 'TEXT'), 'ensureColumns did not add cost_rows.participant');
});

test('5. ensureTable self-creates participant_machines on an empty database', async () => {
  const db = new DatabaseSync(':memory:');
  await ensureTable({ DB: d1(db) }, 'participant_machines');
  assert.deepEqual(cols(db, 'participant_machines').map((c) => c.name), CONTRACT);
  assert.deepEqual(idx(db, 'participant_machines'), ['idx_participant_machines_status']);
});
