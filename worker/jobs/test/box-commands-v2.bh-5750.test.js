import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-5750 S1: box_commands_v2 (schema.d/0014) takes the five BH-2518 types and
// the nine Mission Control types, refuses any other, and its one-time copy keeps
// every box_commands history row with its id. Run on the REAL fragment bytes
// over the REAL box_commands definition from the jobs schema, in the order the D1
// apply runs them: the old table exists with rows, then the fragment lands.

const SCHEMA = jobsSchemaSql();
const FRAG = readFileSync(fileURLToPath(new URL('../schema.d/0014-bh-5750-box-commands-v2.sql', import.meta.url)), 'utf8');
const NEW = ['orgo_restart', 'orgo_stop', 'orgo_resize_quote', 'orgo_resize', 'orgo_retire',
  'orgo_launch_quote', 'orgo_launch', 'fly_pool_cap', 'fly_onboard'];
const OLD = ['backup_now', 'fly_machine_stop', 'fly_machine_destroy', 'harness_sync', 'cli_update'];

async function oldDb(t) {
  let DatabaseSync;
  try { ({ DatabaseSync } = await import('node:sqlite')); } catch { t.skip('node:sqlite unavailable'); return null; }
  const db = new DatabaseSync(':memory:');
  const m = /CREATE TABLE IF NOT EXISTS box_commands \([\s\S]*?\n\);/.exec(SCHEMA);
  assert.ok(m, 'the jobs schema still defines box_commands');
  db.exec(m[0]);
  return db;
}
const ins = (db, table, type, status = 'ok', id = null) => db.prepare(
  `INSERT INTO ${table} (id,box,type,target,args,reason,status,requested_by,requested_at) VALUES (?,?,?,?,?,?,?,?,?)`,
).run(id, 'hub', type, type.startsWith('orgo') ? 'project-3' : '', null, 'r', status, 'console', '2026-10-10T00:00:00Z');

test('S1: the history copy keeps ids, a re-apply adds nothing, and new ids continue after the copied ones', async (t) => {
  const db = await oldDb(t); if (!db) return;
  ins(db, 'box_commands', 'backup_now', 'ok', 7);
  ins(db, 'box_commands', 'cli_update', 'requested', 9);
  db.exec(FRAG);
  db.exec(FRAG);
  const rows = db.prepare('SELECT id, type, status FROM box_commands_v2 ORDER BY id').all();
  assert.deepEqual(rows.map((r) => [r.id, r.type, r.status]), [[7, 'backup_now', 'ok'], [9, 'cli_update', 'requested']]);
  const n = ins(db, 'box_commands_v2', 'orgo_restart', 'requested');
  assert.equal(Number(n.lastInsertRowid), 10);
  assert.equal(db.prepare('SELECT count(*) AS c FROM box_commands').get().c, 2, 'the old table is left as it was');
});

test('S1: the v2 CHECK takes all fourteen types and refuses any other; the old table still refuses the new ones', async (t) => {
  const db = await oldDb(t); if (!db) return;
  db.exec(FRAG);
  for (const type of [...OLD, ...NEW]) ins(db, 'box_commands_v2', type, 'ok');
  assert.equal(db.prepare('SELECT count(*) AS c FROM box_commands_v2').get().c, 14);
  assert.throws(() => ins(db, 'box_commands_v2', 'bogus'), /CHECK constraint failed/);
  assert.throws(() => ins(db, 'box_commands', 'orgo_resize'), /CHECK constraint failed/);
  // One open row per (box, type, target), as on the old table.
  ins(db, 'box_commands_v2', 'orgo_stop', 'requested');
  assert.throws(() => ins(db, 'box_commands_v2', 'orgo_stop', 'claimed'), /UNIQUE constraint failed/);
});
