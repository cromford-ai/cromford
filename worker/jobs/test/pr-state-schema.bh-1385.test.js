import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { d1 } from './lib/d1-sqlite.bh-1030.js';
import { CREATED_TABLES, ensureTable } from '../src/lib/core.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1385 (BH-1025.0): the PR-state / PR-attempt schema chunk.
//
// TWO HALVES THAT MUST AGREE, AND ONE INCIDENT THAT SAYS WHY. schema.sql is
// what `bin/harness-sync.sh` applies statement by statement before a deploy;
// CREATED_TABLES is the belt `ensureTable(env, …)` runs at the top of a
// handler when the deploy ran ahead of the apply (BH-1000's hub_lease outage
// is the whole reason the belt exists). If the two drift, a fresh D1 and a
// belt-built D1 are different databases and the difference surfaces as a
// column that is missing only on some boxes. So this suite builds BOTH and
// compares them column for column and default for default.
//
// No clock, no network: every value is a literal.

const SCHEMA = jobsSchemaSql();
const MARK = '-- ── BH-1025.0';

async function sqlite() {
  try {
    const { DatabaseSync } = await import('node:sqlite');
    return DatabaseSync;
  } catch {
    return null;
  }
}

test('schema.sql applies onto a pre-BH-1025 database, twice, and lands the three objects', async (t) => {
  const DatabaseSync = await sqlite();
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }

  // The marker is load-bearing: without it the "pre-BH-1025 snapshot" below
  // would be the WHOLE schema and case (a) would prove nothing at all.
  const at = SCHEMA.indexOf(MARK);
  assert.notEqual(at, -1, `worker/jobs/schema.sql must carry the "${MARK}" block marker`);
  const before = SCHEMA.slice(0, at);
  assert.equal(before.includes('pr_state_events'), false,
    'the BH-1025.0 objects must all live under the marker');

  const db = new DatabaseSync(':memory:');
  db.exec(before);          // the database as it was before this ticket
  db.exec(SCHEMA);          // the upgrade
  db.exec(SCHEMA);          // and again, because harness-sync re-applies it every deploy

  const objs = new Map(
    db.prepare("SELECT name, type FROM sqlite_master").all().map((r) => [r.name, r.type]),
  );
  assert.equal(objs.get('pr_state_events'), 'table', 'pr_state_events table missing');
  assert.equal(objs.get('pr_attempts'), 'table', 'pr_attempts table missing');
  assert.equal(objs.get('pr_state'), 'view', 'pr_state view missing');
  for (const idx of ['idx_pr_state_events_dedupe', 'idx_pr_state_events_pr', 'idx_pr_state_events_state_at']) {
    assert.equal(objs.get(idx), 'index', `${idx} missing`);
  }

  // `alerted` carries a DEFAULT because the dedupe index is a plain column
  // list: a NULL in a SQLite UNIQUE index never collides, so a nullable
  // `alerted` would let the same (repo, number, state, since) insert forever.
  const cols = db.prepare('PRAGMA table_info(pr_state_events)').all();
  const alerted = cols.find((c) => c.name === 'alerted');
  assert.ok(alerted, 'pr_state_events.alerted missing');
  assert.equal(alerted.notnull, 1, 'alerted must be NOT NULL');
  assert.equal(alerted.dflt_value, "'-'", "alerted must default to '-'");

  const pk = db.prepare('PRAGMA table_info(pr_attempts)').all().filter((c) => c.pk > 0).map((c) => c.name);
  assert.deepEqual(pk.sort(), ['kind', 'number', 'repo', 'sha'],
    'pr_attempts primary key must be (repo, number, kind, sha)');

  db.close();
});

test('CREATED_TABLES builds the same tables as schema.sql, and the view answers', async (t) => {
  const DatabaseSync = await sqlite();
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }

  assert.ok(Array.isArray(CREATED_TABLES.pr_state_events), 'CREATED_TABLES.pr_state_events missing');
  assert.ok(Array.isArray(CREATED_TABLES.pr_attempts), 'CREATED_TABLES.pr_attempts missing');

  // The belt, driven through the REAL ensureTable on an EMPTY database — the
  // exact state a box is in when `wrangler deploy` beat the schema apply.
  const belt = new DatabaseSync(':memory:');
  await ensureTable({ DB: d1(belt) }, 'pr_state_events');
  await ensureTable({ DB: d1(belt) }, 'pr_attempts');
  // A second call with a FRESH wrapper really re-runs the statements (the
  // WeakMap cache is keyed on the DB object), which is the idempotence claim.
  await ensureTable({ DB: d1(belt) }, 'pr_state_events');
  await ensureTable({ DB: d1(belt) }, 'pr_attempts');

  const file = new DatabaseSync(':memory:');
  file.exec(SCHEMA);

  const info = (db, table) => db.prepare(`PRAGMA table_info(${table})`).all()
    .map((c) => `${c.name}|${c.type}|${c.notnull}|${c.dflt_value}|${c.pk}`);
  for (const table of ['pr_state_events', 'pr_attempts']) {
    assert.deepEqual(info(belt, table), info(file, table),
      `${table} differs between CREATED_TABLES and schema.sql`);
  }

  const objs = (db) => db.prepare("SELECT name FROM sqlite_master WHERE type='view' OR type='index'")
    .all().map((r) => r.name).filter((n) => n.startsWith('idx_pr_state') || n === 'pr_state').sort();
  assert.deepEqual(objs(belt), objs(file), 'the view/indexes differ between CREATED_TABLES and schema.sql');

  // The view is the latest event per PR: two events for the same (repo,
  // number) leave exactly the higher id visible.
  const ins = "INSERT INTO pr_state_events (repo,number,state,since,head,alerted,at) VALUES (?,?,?,?,?,?,?)";
  belt.prepare(ins).run('example-org/x', 12, 'BLOCKED', 'S1', 'h1', '-', 'A1');
  belt.prepare(ins).run('example-org/x', 12, 'MERGED', 'S2', 'h2', '-', 'A2');
  belt.prepare(ins).run('example-org/y', 34, 'QUEUED', 'S3', 'h3', '-', 'A3');
  // node:sqlite hands back null-prototype rows; re-shaped so deepEqual is
  // comparing the values rather than the prototypes.
  const rows = belt.prepare('SELECT repo, number, state FROM pr_state ORDER BY repo').all()
    .map((r) => ({ repo: r.repo, number: r.number, state: r.state }));
  assert.deepEqual(rows, [
    { repo: 'example-org/x', number: 12, state: 'MERGED' },
    { repo: 'example-org/y', number: 34, state: 'QUEUED' },
  ], 'pr_state must answer the MAX(id) event per (repo, number)');

  belt.close();
  file.close();
});

test('the dedupe index refuses a repeat and lets a new alert through', async (t) => {
  const DatabaseSync = await sqlite();
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }

  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const ins = "INSERT INTO pr_state_events (repo,number,state,since,alerted,at) VALUES (?,?,?,?,?,?)";
  db.prepare(ins).run('example-org/x', 12, 'BLOCKED', 'S1', '-', 'A1');
  assert.throws(
    () => db.prepare(ins).run('example-org/x', 12, 'BLOCKED', 'S1', '-', 'A2'),
    /UNIQUE constraint/i,
    'a repeat of (repo, number, state, since, alerted) must be refused',
  );
  // The SAME state, once it has been alerted, is a different row on purpose:
  // that is how "we paged about this one" is recorded without losing the
  // original sighting.
  db.prepare(ins).run('example-org/x', 12, 'BLOCKED', 'S1', '1', 'A3');
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM pr_state_events').get().n, 2);
  db.close();
});

test('the BH-1025.0 block is additive only', () => {
  const at = SCHEMA.indexOf(MARK);
  assert.notEqual(at, -1, 'block marker missing');
  const block = SCHEMA.slice(at).split('\n').filter((l) => !l.match(/^\s*--/)).join('\n');
  assert.doesNotMatch(block, /\bDROP\b/i, 'the BH-1025.0 block contains a DROP');
  assert.doesNotMatch(block, /\bALTER\b/i, 'the BH-1025.0 block contains an ALTER');
  assert.match(block, /CREATE TABLE IF NOT EXISTS pr_state_events/);
  assert.match(block, /CREATE UNIQUE INDEX IF NOT EXISTS idx_pr_state_events_dedupe/);
  assert.match(block, /CREATE VIEW IF NOT EXISTS pr_state\b/);
  assert.match(block, /CREATE TABLE IF NOT EXISTS pr_attempts/);
});
