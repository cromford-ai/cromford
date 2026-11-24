// BH-9075 (BH-9067.3): EXPLAIN QUERY PLAN of the parks statements at volume.
// 5,000 rows over 3 projects, every state, then ANALYZE. The SQL is read from
// src/routes/parks.js, so the plan is of the shipped statements, not a copy.
//   X1 CHANGED_SQL uses idx_parks_project_updated, no SCAN parks, no temp b-tree
//   X2 HOTFIX_SQL uses idx_parks_state_updated, no SCAN parks
//   X3 PRUNE_IDS_SQL uses idx_parks_state_updated, no SCAN parks
import test from 'node:test';
import assert from 'node:assert/strict';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';

const PROJECTS = ['x-alpha', 'x-bravo', 'x-charlie'];
const STATES = ['parked', 'parked', 'parked', 'done', 'done', 'done', 'done', 'done', 'done', 'hotfix'];

async function seeded(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  const ins = o.db.prepare(`INSERT INTO parks (project, ck, source, state, head, reason, url, rec, ticket, updated_at, writer, parked_at)
                            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`);
  o.db.exec('BEGIN');
  for (let i = 0; i < 5000; i++) {
    const state = STATES[i % STATES.length];
    ins.run(PROJECTS[i % 3], `ck-${i}`, 'queue', state, 'h', 'r', 'u', 'rec', `T-${i}`, 1_700_000_000 + i * 60, 'fly-pool', 1_700_000_000 + i * 60 - 5);
  }
  o.db.exec('COMMIT');
  o.db.exec('ANALYZE');
  return o;
}

test('X1 CHANGED_SQL: idx_parks_project_updated, no SCAN parks, no USE TEMP B-TREE', async (t) => {
  const o = await seeded(t); if (!o) return;
  const { CHANGED_SQL } = await import('../src/routes/parks.js');
  for (const binds of [['x-bravo', 1_700_100_000, null, 1000], ['x-bravo', 1_700_100_000, 'ck-1700', 25]]) {
    const p = plan(o.db, CHANGED_SQL, ...binds);
    assert.ok(p.some((l) => /idx_parks_project_updated/.test(l)), p.join(' | '));
    assert.deepEqual(fullScans(p, ['parks']), [], p.join(' | '));
    assert.ok(!p.some((l) => /USE TEMP B-TREE/.test(l)), p.join(' | '));
  }
});

test('X2 HOTFIX_SQL: idx_parks_state_updated, no SCAN parks', async (t) => {
  const o = await seeded(t); if (!o) return;
  const { HOTFIX_SQL } = await import('../src/routes/parks.js');
  const p = plan(o.db, HOTFIX_SQL, 'x-alpha', 50);
  assert.ok(p.some((l) => /idx_parks_state_updated/.test(l)), p.join(' | '));
  assert.deepEqual(fullScans(p, ['parks']), [], p.join(' | '));
});

test('X3 PRUNE_IDS_SQL: idx_parks_state_updated, no SCAN parks', async (t) => {
  const o = await seeded(t); if (!o) return;
  const { PRUNE_IDS_SQL } = await import('../src/routes/parks.js');
  const p = plan(o.db, PRUNE_IDS_SQL, 1_700_200_000, 500);
  assert.ok(p.some((l) => /idx_parks_state_updated/.test(l)), p.join(' | '));
  assert.deepEqual(fullScans(p, ['parks']), [], p.join(' | '));
});
