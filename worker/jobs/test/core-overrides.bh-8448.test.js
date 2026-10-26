// BH-8448: the last 19 tables of CREATED_TABLE_OVERRIDES moved from the core.js
// literal into one core.d/0000-<table>.js fragment each, and the literal is gone.
//
// S1  each of the 19 fragments exists, exports only CREATED_TABLE_OVERRIDES,
//     and names exactly its own table
// S2  each moved array equals the pre-split fixture, string for string (so the
//     DQW_CLASS_SQL interpolation in the two dequeue fragments is byte-equal)
// S3  the node loader and the real core.js hold exactly the 35 fixture tables,
//     every array equal to the fixture, and CREATED_TABLES uses each override
// S4  core.js holds no literal entry: every override is the loader's own array
// S5  the real ensureTable creates moved tables; the dequeue CHECKs still refuse
//     an unknown class
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { d1 } from './lib/d1-sqlite.bh-1030.js';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const FRAG_DIR = join(HERE, '..', 'src', 'lib', 'core.d');
const FIXTURE = JSON.parse(readFileSync(join(HERE, 'fixtures', 'core-overrides-pre-split.bh-8447.json'), 'utf8'));

const MOVED = [
  'risk_tiers', 'jev_risk_calls', 'queue_risk_scores', 'route_rules', 'route_rule_changes',
  'route_shadow', 'triage_state', 'alert_family_scripts', 'dequeue_events', 'dequeue_actions',
  'projects', 'pool_spawns', 'pool_terminals', 'pool_holds', 'conflict_hotspots',
  'conflict_hotspot_runs', 'participant_machines', 'suite_results', 'suite_reuse_runs',
];
const fileOf = (table) => `0000-${table.replaceAll('_', '-')}.js`;
const load = (file) => import(new URL(file, new URL('../src/lib/core.d/', import.meta.url)));

test('S1 one fragment per moved table, exporting only its own override', async () => {
  assert.equal(MOVED.length, 19);
  for (const table of MOVED) {
    const file = fileOf(table);
    assert.ok(existsSync(join(FRAG_DIR, file)), `core.d/${file} exists`);
    const mod = await load(file);
    assert.deepEqual(Object.keys(mod), ['CREATED_TABLE_OVERRIDES'], `${file} exports only CREATED_TABLE_OVERRIDES`);
    assert.deepEqual(Object.keys(mod.CREATED_TABLE_OVERRIDES), [table], `${file} names only ${table}`);
  }
});

test('S2 each moved array equals the pre-split fixture', async () => {
  for (const table of MOVED) {
    const { CREATED_TABLE_OVERRIDES: o } = await load(fileOf(table));
    assert.deepEqual(o[table], FIXTURE[table], `${table} moved byte for byte`);
  }
});

test('S3 the loader and core.js hold the 35 fixture tables; CREATED_TABLES uses them', async () => {
  const { CREATED_TABLE_OVERRIDES: frag } = await import('../src/lib/core-registries.node.js');
  const { CREATED_TABLE_OVERRIDES: o, CREATED_TABLES } = await import('../src/lib/core.js');
  assert.equal(Object.keys(FIXTURE).length, 35);
  assert.deepEqual(Object.keys(frag).sort(), Object.keys(FIXTURE).sort(), 'the node loader holds all 35 tables');
  assert.deepEqual(Object.keys(o).sort(), Object.keys(FIXTURE).sort(), 'core.js exports all 35 tables');
  for (const [k, items] of Object.entries(FIXTURE)) {
    assert.deepEqual(frag[k], items, `loader ${k}`);
    assert.deepEqual(o[k], items, `CREATED_TABLE_OVERRIDES.${k}`);
    assert.equal(CREATED_TABLES[k], o[k], `CREATED_TABLES.${k} is the override`);
  }
});

test('S4 core.js holds no literal entry: each override is the loader array itself', async () => {
  const { CREATED_TABLE_OVERRIDES: frag } = await import('../src/lib/core-registries.node.js');
  const { CREATED_TABLE_OVERRIDES: o } = await import('../src/lib/core.js');
  for (const k of Object.keys(o)) {
    assert.ok(k in frag, `${k} comes from a core.d/ fragment`);
    assert.equal(o[k], frag[k], `${k} is the fragment's own array, not a core.js copy`);
  }
});

test('S5 the real ensureTable creates moved tables and keeps the dequeue CHECKs', async () => {
  const { ensureTable } = await import('../src/lib/core.js');
  const db = new DatabaseSync(':memory:');
  const env = { DB: d1(db) };
  for (const t of ['dequeue_events', 'dequeue_actions', 'suite_reuse_runs', 'risk_tiers']) await ensureTable(env, t);
  const names = (type) => db.prepare('SELECT name FROM sqlite_master WHERE type = ?').all(type).map((r) => r.name);
  for (const t of ['dequeue_events', 'dequeue_actions', 'suite_reuse_runs', 'risk_tiers']) assert.ok(names('table').includes(t), `${t} created`);
  assert.ok(names('index').includes('idx_suite_reuse_runs_created'), 'idx_suite_reuse_runs_created exists');
  const T = "'2026-10-26T00:00:00Z'";
  const ins = {
    dequeue_events: (head, cls) => `INSERT INTO dequeue_events (repo, pr, head, run_id, project, class, created_at, updated_at)
      VALUES ('r', 1, '${head}', 'run', 'p', '${cls}', ${T}, ${T})`,
    dequeue_actions: (head, cls) => `INSERT INTO dequeue_actions (repo, pr, head, class, action, project, created_at, updated_at)
      VALUES ('r', 1, '${head}', '${cls}', 'observe', 'p', ${T}, ${T})`,
  };
  const row = (t, cls) => db.exec(ins[t](`h-${cls}`, cls));
  for (const t of ['dequeue_events', 'dequeue_actions']) {
    assert.doesNotThrow(() => row(t, 'flake'), `${t} takes class flake`);
    assert.throws(() => row(t, 'not-a-class'), /CHECK constraint/, `${t} refuses an unknown class`);
  }
});
