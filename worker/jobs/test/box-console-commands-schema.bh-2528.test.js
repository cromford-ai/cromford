import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2653 (BH-2528.0): the box_console_commands table, its index and its two
// settings seeds, checked on schema.sql APPLIED through node:sqlite (sqlite3 is
// not installed on the boxes, same as settings-schema.test.js).

const SCHEMA = jobsSchemaSql();
const TTL_KEY = 'lane.box-console-commands.box_console_commands_ttl_s';
const LIMIT_KEY = 'lane.box-console-commands.box_console_commands_claim_limit';

async function openDb(t) {
  try {
    const { DatabaseSync } = await import('node:sqlite');
    return new DatabaseSync(':memory:');
  } catch {
    // Visible in TAP as a skip, never a silent pass.
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
}

const row = (id) => ({
  command_id: id, box: 'box-a', type: 'run-lane', payload: '{"lane":"x"}', status: 'queued',
  created_at: '2026-09-26T00:00:00Z', updated_at: '2026-09-26T00:00:00Z',
});
const insert = (db, r) => db.prepare(
  'INSERT INTO box_console_commands (command_id,box,type,payload,status,created_at,updated_at) VALUES (?,?,?,?,?,?,?)',
).run(r.command_id, r.box, r.type, r.payload, r.status, r.created_at, r.updated_at);

test('S1-S7: box_console_commands applies twice, keeps rows and operator-set seeds', async (t) => {
  const db = await openDb(t);
  if (!db) return;

  // S1: the whole file applies, twice.
  db.exec(SCHEMA);
  db.exec(SCHEMA);

  // S2: exactly the 14 columns, command_id the PK, the NOT NULLs.
  const cols = db.prepare('PRAGMA table_info(box_console_commands)').all();
  assert.deepEqual(cols.map((c) => c.name), [
    'command_id', 'box', 'type', 'project', 'payload', 'status', 'ok', 'result', 'body',
    'claimed_at', 'finished_at', 'actor', 'created_at', 'updated_at',
  ]);
  const by = Object.fromEntries(cols.map((c) => [c.name, c]));
  assert.equal(by.command_id.pk, 1);
  assert.equal(cols.filter((c) => c.pk).length, 1);
  const notNull = cols.filter((c) => c.notnull).map((c) => c.name).sort();
  assert.deepEqual(notNull, ['box', 'created_at', 'payload', 'status', 'type', 'updated_at']);

  // S3: the index, on (box, status, created_at) in that order.
  const idx = db.prepare('PRAGMA index_list(box_console_commands)').all();
  assert.ok(idx.some((i) => i.name === 'idx_box_console_commands_box'), 'idx_box_console_commands_box missing');
  const idxCols = db.prepare('PRAGMA index_info(idx_box_console_commands_box)').all()
    .sort((a, b) => a.seqno - b.seqno).map((c) => c.name);
  assert.deepEqual(idxCols, ['box', 'status', 'created_at']);

  // S4: both seeds, as TEXT, from the seed actor.
  const seed = (k) => db.prepare('SELECT value, actor FROM settings WHERE key=?').get(k);
  assert.deepEqual({ ...seed(TTL_KEY) }, { value: '300', actor: 'seed' });
  assert.deepEqual({ ...seed(LIMIT_KEY) }, { value: '10', actor: 'seed' });

  // S5 + S6: an operator edit and an existing row both survive a re-apply.
  db.prepare("UPDATE settings SET value='600', actor='op' WHERE key=?").run(TTL_KEY);
  insert(db, row('c-1'));
  db.exec(SCHEMA);
  assert.deepEqual({ ...seed(TTL_KEY) }, { value: '600', actor: 'op' });
  const kept = db.prepare('SELECT command_id, payload FROM box_console_commands').all();
  assert.deepEqual(kept.map((r) => ({ ...r })), [{ command_id: 'c-1', payload: '{"lane":"x"}' }]);

  // S7: command_id is the dedupe key.
  assert.throws(() => insert(db, row('c-1')), /UNIQUE|PRIMARY/i);
  // and a NOT NULL column refuses a missing value.
  assert.throws(() => db.prepare(
    "INSERT INTO box_console_commands (command_id,box,type,payload,status,created_at,updated_at) VALUES ('c-2','b','t',NULL,'queued','x','x')",
  ).run());

  db.close();
});
