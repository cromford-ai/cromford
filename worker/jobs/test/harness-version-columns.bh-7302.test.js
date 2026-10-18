import test from 'node:test';
import assert from 'node:assert/strict';
import { ensureColumns } from '../src/lib/core.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-7302 (BH-7191.0): the fleet version check's columns and its one index
// reach D1 through ensureColumns, never schema.sql. No route names them in
// this slice; the siblings do. The plans below are node:sqlite's.

const SCHEMA = jobsSchemaSql();
let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }

function d1(db) {
  const exec = (sql, binds) => {
    const stmt = db.prepare(sql);
    if (/^\s*(SELECT|PRAGMA)\b/i.test(sql)) return { results: stmt.all(...binds), meta: { changes: 0 } };
    const r = stmt.run(...binds);
    return { results: [], meta: { changes: Number(r.changes) } };
  };
  const make = (sql, binds) => ({
    bind: (...b) => make(sql, b),
    run: async () => exec(sql, binds),
    first: async () => { const r = exec(sql, binds); return r.results.length ? r.results[0] : null; },
    all: async () => exec(sql, binds),
  });
  return { prepare: (sql) => make(sql, []) };
}
function fresh() {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return { db, env: { DB: d1(db) } };
}
const cols = (db, t) => new Map(db.prepare(`PRAGMA table_info(${t})`).all().map((r) => [r.name, r]));

const NEW = {
  box_status: [['harness_synced_at', 'TEXT'], ['sync_timer', 'INTEGER'], ['harness_lag_min', 'INTEGER'], ['lag_checked_at', 'TEXT']],
  build_queue: [['harness_commit', 'TEXT']],
  registry_boxes: [['role', 'TEXT']],
  lane_runs: [['harness_commit', 'TEXT']],
  lane_machines: [['harness_commit', 'TEXT']],
};

test('C1: ensureColumns adds each new column, nullable, with no default', { skip: !DatabaseSync && 'node:sqlite missing' }, async () => {
  const { db, env } = fresh();
  for (const [table, want] of Object.entries(NEW)) {
    const before = cols(db, table);
    for (const [c] of want) assert.equal(before.has(c), false, `${table}.${c} is in schema.sql; it must come from ADDED_COLUMNS`);
    await ensureColumns(env, table);
    const after = cols(db, table);
    for (const [c, type] of want) {
      const r = after.get(c);
      assert.ok(r, `${table}.${c} was not added`);
      assert.equal(r.type, type, `${table}.${c} type`);
      assert.equal(r.notnull, 0, `${table}.${c} must be nullable`);
      assert.equal(r.dflt_value, null, `${table}.${c} must have no default`);
    }
  }
});

test('C2: ensureColumns(lane_ticks) creates idx_lane_ticks_box on (box, last_tick_at)', { skip: !DatabaseSync && 'node:sqlite missing' }, async () => {
  const { db, env } = fresh();
  const names = () => db.prepare('PRAGMA index_list(lane_ticks)').all().map((r) => r.name);
  assert.equal(names().includes('idx_lane_ticks_box'), false);
  await ensureColumns(env, 'lane_ticks');
  assert.ok(names().includes('idx_lane_ticks_box'), names().join(','));
  const keys = db.prepare('PRAGMA index_info(idx_lane_ticks_box)').all().map((r) => r.name);
  assert.deepEqual(keys, ['box', 'last_tick_at']);
});

test('C3: the newest tick per box uses idx_lane_ticks_box at 5000 rows over 40 boxes', { skip: !DatabaseSync && 'node:sqlite missing' }, async () => {
  const { db, env } = fresh();
  await ensureColumns(env, 'lane_ticks');
  const ins = db.prepare('INSERT INTO lane_ticks (lane, project, box, last_tick_at, last_outcome, updated_at) VALUES (?,?,?,?,?,?)');
  db.exec('BEGIN');
  for (let i = 0; i < 5000; i++) {
    const ts = new Date(Date.UTC(2026, 9, 1) + i * 60000).toISOString();
    ins.run(`lane-${i}`, `p${i % 4}`, `box-${i % 40}`, ts, 'ran', ts);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const plan = db.prepare('EXPLAIN QUERY PLAN SELECT last_tick_at FROM lane_ticks WHERE box=?1 ORDER BY last_tick_at DESC LIMIT 1')
    .all('box-7').map((p) => p.detail).join(' | ');
  assert.match(plan, /idx_lane_ticks_box/, plan);
  assert.doesNotMatch(plan, /SCAN lane_ticks\b(?! USING)/, plan);
  const row = db.prepare('SELECT last_tick_at FROM lane_ticks WHERE box=?1 ORDER BY last_tick_at DESC LIMIT 1').get('box-7');
  assert.equal(row.last_tick_at, new Date(Date.UTC(2026, 9, 1) + 4967 * 60000).toISOString());
});
