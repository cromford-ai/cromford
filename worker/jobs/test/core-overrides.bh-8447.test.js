// BH-8447: the first 16 tables of CREATED_TABLE_OVERRIDES moved from the
// core.js literal into one core.d/0000-<table>.js fragment each.
//
// S1  each of the 16 fragments exists, exports only CREATED_TABLE_OVERRIDES,
//     and names exactly its own table; no other 0000-* file exports overrides
// S2  each moved array equals the pre-split fixture, string for string
// S3  the real core.js CREATED_TABLE_OVERRIDES equals the fixture (35 tables),
//     and CREATED_TABLES uses each override
// S4  the node loader holds exactly the 16 moved tables; a table left in both
//     the literal and a fragment cannot load
// S5  the real ensureTable creates the moved tables with their extra objects
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { mergeTableLists } from '../src/lib/core-registries.js';
import { d1 } from './lib/d1-sqlite.bh-1030.js';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const FRAG_DIR = join(HERE, '..', 'src', 'lib', 'core.d');
const FIXTURE = JSON.parse(readFileSync(join(HERE, 'fixtures', 'core-overrides-pre-split.bh-8447.json'), 'utf8'));

const MOVED = [
  'merge_trains', 'verdict_history', 'wakes', 'wake_claims', 'pr_state_events', 'pr_attempts',
  'model_routes', 'routing_changes', 'cost_cap_changes', 'config_changes', 'harness_flags',
  'model_route_changes', 'verdicts', 'lead_protected_paths', 'setting_sigs', 'lead_review_requests',
];
const fileOf = (table) => `0000-${table.replaceAll('_', '-')}.js`;
const load = (file) => import(new URL(file, new URL('../src/lib/core.d/', import.meta.url)));

test('S1 one fragment per moved table, exporting only its own override', async () => {
  for (const table of MOVED) {
    const file = fileOf(table);
    assert.ok(existsSync(join(FRAG_DIR, file)), `core.d/${file} exists`);
    const mod = await load(file);
    assert.deepEqual(Object.keys(mod), ['CREATED_TABLE_OVERRIDES'], `${file} exports only CREATED_TABLE_OVERRIDES`);
    assert.deepEqual(Object.keys(mod.CREATED_TABLE_OVERRIDES), [table], `${file} names only ${table}`);
  }
  const want = new Set(MOVED.map(fileOf));
  for (const file of readdirSync(FRAG_DIR).filter((f) => f.startsWith('0000-'))) {
    if (want.has(file)) continue;
    const mod = await load(file);
    assert.ok(!('CREATED_TABLE_OVERRIDES' in mod), `${file} is not a moved table and must not export CREATED_TABLE_OVERRIDES`);
  }
});

test('S2 each moved array equals the pre-split fixture', async () => {
  for (const table of MOVED) {
    const { CREATED_TABLE_OVERRIDES: o } = await load(fileOf(table));
    assert.deepEqual(o[table], FIXTURE[table], `${table} moved byte for byte`);
  }
});

test('S3 core.js CREATED_TABLE_OVERRIDES equals the fixture and CREATED_TABLES uses it', async () => {
  const { CREATED_TABLE_OVERRIDES: o, CREATED_TABLES } = await import('../src/lib/core.js');
  assert.equal(Object.keys(FIXTURE).length, 35);
  assert.deepEqual(Object.keys(o).sort(), Object.keys(FIXTURE).sort());
  for (const [k, items] of Object.entries(FIXTURE)) {
    assert.deepEqual(o[k], items, `CREATED_TABLE_OVERRIDES.${k}`);
    assert.equal(CREATED_TABLES[k], o[k], `CREATED_TABLES.${k} is the override`);
  }
});

test('S4 the node loader holds exactly the moved tables; a table in both places throws', async () => {
  const { CREATED_TABLE_OVERRIDES: frag } = await import('../src/lib/core-registries.node.js');
  assert.deepEqual(Object.keys(frag).sort(), [...MOVED].sort());
  assert.throws(() => mergeTableLists({ verdicts: FIXTURE.verdicts }, { verdicts: FIXTURE.verdicts }),
    (e) => e.message.includes('verdicts') && e.message.includes('twice'));
});

test('S5 the real ensureTable creates moved tables with their triggers, view, index and backfill', async () => {
  const { ensureTable } = await import('../src/lib/core.js');
  const db = new DatabaseSync(':memory:');
  const env = { DB: d1(db) };
  await ensureTable(env, 'pause_flags');
  db.exec("INSERT INTO pause_flags (name, active, actor, reason, updated_at) VALUES ('paused-x', 1, 't', 'r', '2026-10-26T00:00:00Z')");
  for (const t of ['verdicts', 'setting_sigs', 'pr_state_events', 'harness_flags', 'wakes']) await ensureTable(env, t);
  const objs = (type) => db.prepare('SELECT name, tbl_name FROM sqlite_master WHERE type = ?').all(type);
  const tables = objs('table').map((r) => r.name);
  for (const t of ['verdicts', 'setting_sigs', 'pr_state_events', 'harness_flags', 'wakes']) assert.ok(tables.includes(t), `${t} created`);
  const triggerTables = new Set(objs('trigger').map((r) => r.tbl_name));
  assert.ok(triggerTables.has('verdicts'), 'a verdicts trigger exists');
  assert.ok(triggerTables.has('setting_sigs'), 'a setting_sigs trigger exists');
  assert.ok(objs('view').some((r) => r.name === 'pr_state'), 'the pr_state view exists');
  assert.ok(objs('index').some((r) => r.name === 'idx_wakes_at'), 'idx_wakes_at exists');
  const flags = db.prepare("SELECT scope, name, cleared_at FROM harness_flags WHERE name = 'paused-x'").all();
  assert.deepEqual(flags.map((r) => [r.scope, r.name, r.cleared_at]), [['fleet', 'paused-x', null]]);
});
