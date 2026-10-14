import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaFile } from './lib/jobs-schema.js';

// BH-2371 (BH-2329.0): the main_red detail table, the main_red_events audit
// table and their two indexes, applied from the real schema.sql. The routes
// that write them are a sibling slice; here we only prove the SQL.

const SCHEMA_PATH = jobsSchemaFile();
const REPO_ROOT = fileURLToPath(new URL('../../../', import.meta.url));

const MAIN_RED_COLUMNS = [
  'name', 'slug', 'project', 'active', 'sha', 'workflow', 'job', 'run_url',
  'since', 'reason', 'cleared_sha', 'cleared_at', 'cleared_by', 'clear_reason',
  'updated_at',
];
const EVENTS_COLUMNS = ['id', 'name', 'action', 'sha', 'actor', 'reason', 'at'];
const T0 = '2026-09-25T00:00:00Z';

async function open(t) {
  const h = await openDb();
  if (!h) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  return h.db;
}

function indexColumns(db, index) {
  return db.prepare(`PRAGMA index_info(${index})`).all()
    .sort((a, b) => a.seqno - b.seqno).map((r) => r.name);
}

test('main_red has the contract columns, name is the pk, active/updated_at NOT NULL', async (t) => {
  const db = await open(t);
  if (!db) return;
  const cols = db.prepare('PRAGMA table_info(main_red)').all();
  assert.deepEqual(cols.map((c) => c.name), MAIN_RED_COLUMNS);
  assert.equal(cols.find((c) => c.name === 'name').pk, 1);
  for (const c of cols) {
    const want = c.name === 'active' || c.name === 'updated_at' ? 1 : 0;
    assert.equal(c.notnull, want, `${c.name} notnull=${want}`);
  }
});

test('main_red_events has the contract columns, id is the pk, name/action/actor/at NOT NULL', async (t) => {
  const db = await open(t);
  if (!db) return;
  const cols = db.prepare('PRAGMA table_info(main_red_events)').all();
  assert.deepEqual(cols.map((c) => c.name), EVENTS_COLUMNS);
  assert.equal(cols.find((c) => c.name === 'id').pk, 1);
  const required = new Set(['name', 'action', 'actor', 'at']);
  for (const c of cols) {
    if (c.name === 'id') continue;
    assert.equal(c.notnull, required.has(c.name) ? 1 : 0, `${c.name} notnull`);
  }
});

test('main_red_project indexes project; main_red_events_name indexes (name, id)', async (t) => {
  const db = await open(t);
  if (!db) return;
  const redIdx = db.prepare('PRAGMA index_list(main_red)').all().map((r) => r.name);
  assert.ok(redIdx.includes('main_red_project'), `main_red indexes: ${redIdx}`);
  assert.deepEqual(indexColumns(db, 'main_red_project'), ['project']);
  const evIdx = db.prepare('PRAGMA index_list(main_red_events)').all().map((r) => r.name);
  assert.ok(evIdx.includes('main_red_events_name'), `main_red_events indexes: ${evIdx}`);
  assert.deepEqual(indexColumns(db, 'main_red_events_name'), ['name', 'id']);
});

test('main_red_events.action CHECK takes the four actions and rejects anything else', async (t) => {
  const db = await open(t);
  if (!db) return;
  const ins = db.prepare(
    `INSERT INTO main_red_events (name, action, sha, actor, reason, at) VALUES (?, ?, NULL, 'detector', NULL, ?)`,
  );
  for (const a of ['raise', 'new_sha', 'green', 'clear']) ins.run('main-red-example-org-cromford', a, T0);
  for (const bad of ['bogus', 'Raise', '']) {
    assert.throws(() => ins.run('main-red-example-org-cromford', bad, T0), /CHECK constraint failed/, `action=${JSON.stringify(bad)}`);
  }
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM main_red_events').get().n, 4);
});

test('applying schema.sql a second time is a no-op that keeps existing rows', async (t) => {
  const db = await open(t);
  if (!db) return;
  db.prepare(`INSERT INTO main_red (name, active, sha, updated_at) VALUES (?, 1, 'abc123', ?)`)
    .run('main-red-example-org-cromford', T0);
  db.exec(readFileSync(SCHEMA_PATH, 'utf8'));
  const row = db.prepare('SELECT name, active, sha, updated_at FROM main_red').all();
  assert.deepEqual(row.map((r) => ({ ...r })), [
    { name: 'main-red-example-org-cromford', active: 1, sha: 'abc123', updated_at: T0 },
  ]);
});

test('the harness-sync splitter emits the main_red CREATE as one whole statement', (t) => {
  const r = spawnSync('bash', ['-c', '. bin/lib/d1-schema.sh && d1_schema_statements "$1"', '_', jobsSchemaFile()], {
    cwd: REPO_ROOT, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024,
  });
  if (r.error && r.error.code === 'ENOENT') { t.skip('bash unavailable'); return; }
  assert.equal(r.status, 0, r.stderr);
  const stmts = r.stdout.split('\0').map((s) => s.trim()).filter(Boolean);
  const table = stmts.filter((s) => s.startsWith('CREATE TABLE IF NOT EXISTS main_red ('));
  assert.equal(table.length, 1, 'exactly one main_red CREATE');
  assert.match(table[0], /updated_at TEXT NOT NULL\s*\);?$/);
  assert.ok(!stmts.some((s) => s.startsWith('NULL when')), 'the inline "; NULL" comment did not split the statement');
  for (const want of [
    'CREATE INDEX IF NOT EXISTS main_red_project ON main_red(project)',
    'CREATE INDEX IF NOT EXISTS main_red_events_name ON main_red_events(name, id)',
  ]) assert.ok(stmts.some((s) => s.startsWith(want)), want);
  assert.equal(stmts.filter((s) => s.startsWith('CREATE TABLE IF NOT EXISTS main_red_events (')).length, 1);
});
