import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { ensureTable } from '../src/index.js';
import { d1 } from './lib/d1-sqlite.bh-1030.js';
import { CONFIG_KINDS, configChangeStmts } from '../src/lib/config-changes.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2617 (BH-2513 contract): the config_changes audit table, its worker
// self-create mirror, and configChangeStmts, the statement builder the
// console-controls routes batch next to their own writes.

const SCHEMA = jobsSchemaSql();

async function sqlite(t) {
  try {
    return (await import('node:sqlite')).DatabaseSync;
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
}

function shape(db) {
  const cols = db.prepare('PRAGMA table_info(config_changes)').all().map((r) => ({
    name: r.name,
    type: r.type.toUpperCase(),
    notnull: Boolean(r.notnull),
    pk: r.pk,
  }));
  const idx = db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='config_changes' AND name NOT LIKE 'sqlite_%' ORDER BY name").all().map((r) => r.name);
  const idxCols = db.prepare("PRAGMA index_info('idx_config_changes_kind_name')").all().map((r) => r.name);
  return { cols, idx, idxCols };
}

const EXPECTED_COLS = [
  { name: 'id', type: 'INTEGER', notnull: false, pk: 1 },
  { name: 'kind', type: 'TEXT', notnull: true, pk: 0 },
  { name: 'name', type: 'TEXT', notnull: true, pk: 0 },
  { name: 'before_json', type: 'TEXT', notnull: false, pk: 0 },
  { name: 'after_json', type: 'TEXT', notnull: true, pk: 0 },
  { name: 'actor', type: 'TEXT', notnull: true, pk: 0 },
  { name: 'reason', type: 'TEXT', notnull: false, pk: 0 },
  { name: 'at', type: 'TEXT', notnull: true, pk: 0 },
];

test('S1: schema.sql creates config_changes and its index, re-runnably', async (t) => {
  const DatabaseSync = await sqlite(t);
  if (!DatabaseSync) return;
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  db.exec(SCHEMA);
  const s = shape(db);
  assert.deepEqual(s.cols, EXPECTED_COLS);
  assert.deepEqual(s.idx, ['idx_config_changes_kind_name']);
  assert.deepEqual(s.idxCols, ['kind', 'name', 'id']);
  assert.equal(db.prepare('SELECT count(*) AS n FROM config_changes').get().n, 0, 'ships empty');
  db.close();
});

test('S1b: CREATED_TABLES.config_changes via ensureTable (twice) gives the schema.sql shape', async (t) => {
  const DatabaseSync = await sqlite(t);
  if (!DatabaseSync) return;
  const fromSchema = new DatabaseSync(':memory:');
  fromSchema.exec(SCHEMA);
  const fresh = new DatabaseSync(':memory:');
  await ensureTable({ DB: fresh }, 'config_changes');
  await ensureTable({ DB: fresh }, 'config_changes');
  assert.deepEqual(shape(fresh), shape(fromSchema));
  assert.deepEqual(shape(fresh).cols, EXPECTED_COLS);
  fromSchema.close();
  fresh.close();
});

test('S1c: the schema.sql config_changes block carries APPEND-ONLY and NO RLS STEP', () => {
  const create = SCHEMA.indexOf('CREATE TABLE IF NOT EXISTS config_changes');
  assert.notEqual(create, -1, 'config_changes CREATE is in schema.sql');
  const header = SCHEMA.slice(SCHEMA.lastIndexOf('\n\n', create), create);
  assert.match(header, /APPEND-ONLY/);
  assert.match(header, /NO RLS STEP/);
});

// BH-2994 (BH-2992 contract) added COST_CAP, TELEGRAM_TOPIC and REGISTRY_SEED;
// BH-2375 (BH-2330.0) added SETTING and FLAG;
// BH-3155 (BH-2325.0) added MERGE_QUEUE and HELD_PAGE;
// BH-4082 added PROJECT;
// BH-8317 added PROJECT_SECRET;
// TEST-CHANGE (BH-7924): CONNECTION added (PUT /api/connections audit); no other kind changes.
test('K1: CONFIG_KINDS is exactly the fourteen kinds, frozen', () => {
  assert.deepEqual({ ...CONFIG_KINDS }, {
    REVIEW_GATE_THRESHOLD: 'review_gate_threshold',
    RULE: 'concurrency_rule',
    RETRY_POLICY: 'retry_policy',
    CONTRACT: 'phase_contract',
    COST_CAP: 'cost_cap',
    TELEGRAM_TOPIC: 'telegram_topic',
    REGISTRY_SEED: 'registry_seed',
    SETTING: 'setting',
    FLAG: 'flag',
    MERGE_QUEUE: 'merge_queue',
    HELD_PAGE: 'held_page',
    PROJECT: 'project',
    PROJECT_SECRET: 'project_secret',
    CONNECTION: 'connection',
  });
  assert.ok(Object.isFrozen(CONFIG_KINDS));
});

// A fresh DB with ONLY the config_changes table, created the way a route
// would (ensureTable), behind the d1 shim so the statement really runs.
async function freshEnv(DatabaseSync) {
  const db = new DatabaseSync(':memory:');
  const env = { DB: d1(db) };
  await ensureTable(env, 'config_changes');
  return { db, env };
}
const rows = (db) => db.prepare('SELECT * FROM config_changes ORDER BY id').all();

test('H1: an unchanged write (after String() normalisation) yields no statement', async (t) => {
  const DatabaseSync = await sqlite(t);
  if (!DatabaseSync) return;
  const { db, env } = await freshEnv(DatabaseSync);
  const kind = CONFIG_KINDS.REVIEW_GATE_THRESHOLD;
  assert.equal(configChangeStmts(env, kind, 'x', { v: 5, w: null }, { v: '5' }, ['v', 'w'], 'a', 'r', 't').length, 0);
  assert.equal(configChangeStmts(env, kind, 'x', { v: 5 }, { v: 6 }, [], 'a', 'r', 't').length, 0, 'no fields audits nothing');
  // A field missing on was but '' on after IS a change.
  assert.equal(configChangeStmts(env, kind, 'x', {}, { v: '' }, ['v'], 'a', 'r', 't').length, 1);
  db.close();
});

test('H2: a first write stores one row with before_json NULL and the picked after', async (t) => {
  const DatabaseSync = await sqlite(t);
  if (!DatabaseSync) return;
  const { db, env } = await freshEnv(DatabaseSync);
  const stmts = configChangeStmts(env, 'review_gate_threshold', 'plan', null, { v: '5', extra: 1 }, ['v', 'w'], 'operator', 'why', '2026-09-26T00:00:00Z');
  assert.equal(stmts.length, 1);
  await env.DB.batch(stmts);
  const r = rows(db);
  assert.equal(r.length, 1);
  assert.equal(r[0].before_json, null);
  assert.deepEqual(JSON.parse(r[0].after_json), { v: '5', w: null });
  assert.equal(r[0].kind, 'review_gate_threshold');
  assert.equal(r[0].name, 'plan');
  assert.equal(r[0].at, '2026-09-26T00:00:00Z');
  assert.equal(r[0].actor, 'operator');
  assert.equal(r[0].reason, 'why');
  db.close();
});

test('H2b: a changed field stores before_json of the picked was', async (t) => {
  const DatabaseSync = await sqlite(t);
  if (!DatabaseSync) return;
  const { db, env } = await freshEnv(DatabaseSync);
  const stmts = configChangeStmts(env, 'retry_policy', 'p', { v: 4, other: 'x' }, { v: 5 }, ['v'], 'a', null, 't');
  assert.equal(stmts.length, 1);
  await env.DB.batch(stmts);
  const r = rows(db);
  assert.equal(r.length, 1);
  assert.equal(r[0].before_json, '{"v":4}');
  assert.equal(r[0].after_json, '{"v":5}');
  db.close();
});

test('H3: blank reason stores NULL, absent or empty actor stores api', async (t) => {
  const DatabaseSync = await sqlite(t);
  if (!DatabaseSync) return;
  const { db, env } = await freshEnv(DatabaseSync);
  await env.DB.batch(configChangeStmts(env, 'retry_policy', 'a', null, { v: 1 }, ['v'], undefined, '  ', 't'));
  await env.DB.batch(configChangeStmts(env, 'retry_policy', 'b', null, { v: 1 }, ['v'], '', undefined, 't'));
  const r = rows(db);
  assert.deepEqual(r.map((x) => [x.actor, x.reason]), [['api', null], ['api', null]]);
  db.close();
});

test('H3b: actor is sliced to 128, reason trimmed then sliced to 512', async (t) => {
  const DatabaseSync = await sqlite(t);
  if (!DatabaseSync) return;
  const { db, env } = await freshEnv(DatabaseSync);
  const reason = '  ' + 'r'.repeat(600) + '  ';
  await env.DB.batch(configChangeStmts(env, 'retry_policy', 'a', null, { v: 1 }, ['v'], 'x'.repeat(200), reason, 't'));
  const [r] = rows(db);
  assert.equal(r.actor, 'x'.repeat(128));
  assert.equal(r.reason, 'r'.repeat(512));
  db.close();
});
