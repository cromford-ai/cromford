import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1054: the Fly machine registry schema chunk must be additive and re-runnable.
// The worker routes are in a sibling slice; here we only prove the SQL and the
// worker-side table definition constants.

const SCHEMA = jobsSchemaSql();

// BH-1054 spells the state vocabulary out; this is that list verbatim.
const TICKET_STATES = [
  'spawned', 'created', 'starting', 'started', 'stopping', 'stopped',
  'failed', 'suspended', 'destroying', 'destroyed', 'gone', 'destroy_failed',
];

const REQUIRED_COLUMNS = [
  'machine_id', 'project', 'app', 'role', 'key', 'ticket',
  'auth_account', 'image', 'state', 'detail',
  'spawned_at', 'last_seen', 'ended_at', 'actor', 'updated_at',
];

test('schema.sql is additive and the machines table matches the contract', async (t) => {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return;
  }

  const db = new DatabaseSync(':memory:');

  // Applying twice must never error; the file is how this schema ships.
  db.exec(SCHEMA);
  db.exec(SCHEMA);

  const cols = db.prepare("PRAGMA table_info(machines)").all();
  const names = new Set(cols.map((c) => c.name));
  for (const col of REQUIRED_COLUMNS) {
    assert.ok(names.has(col), `machines table is missing column ${col}`);
  }
  assert.ok(cols.find((c) => c.name === 'machine_id' && c.pk), 'machine_id is the primary key');

  const seed = db.prepare("SELECT value, actor, note, updated_at FROM settings WHERE key='fly_machines_rows'").get();
  assert.ok(seed, 'seed row fly_machines_rows missing');
  assert.equal(seed.value, 'off', 'fly_machines_rows seed must be off');
  assert.equal(seed.actor, 'seed', 'fly_machines_rows seed actor must be seed');
  assert.match(String(seed.note), /machine registry/i, 'seed note explains the flag');
  assert.ok(seed.updated_at, 'seed has an updated_at');

  // No DROP or ALTER statements outside comments — additive only.
  const stmts = SCHEMA.split('\n')
    .filter((line) => !line.match(/^\s*--/))
    .join('\n');
  assert.doesNotMatch(stmts, /\bDROP\b/i, 'schema.sql contains a DROP statement');
  assert.doesNotMatch(stmts, /\bALTER\b/i, 'schema.sql contains an ALTER statement');

  // An operator flips the flag; a re-apply must not clobber it.
  db.prepare("UPDATE settings SET value='on', actor='box-project-3-1-1' WHERE key='fly_machines_rows'").run();
  db.exec(SCHEMA);
  const after = db.prepare("SELECT value, actor FROM settings WHERE key='fly_machines_rows'").get();
  assert.equal(after.value, 'on', 're-applying schema.sql reset an operator-set flag');
  assert.equal(after.actor, 'box-project-3-1-1', 're-applying schema.sql reset the actor');

  db.close();
});

test('worker index exports the machines table definition and state constants', async () => {
  const m = await import('../src/index.js');
  const d = m.default;
  assert.ok(d, 'default export exists');
  assert.ok(d.CREATED_TABLES, 'CREATED_TABLES exported');
  assert.ok(Array.isArray(d.CREATED_TABLES.machines), 'CREATED_TABLES.machines is an array');
  assert.ok(d.CREATED_TABLES.machines.some((s) => s.includes('CREATE TABLE IF NOT EXISTS machines')), 'machines table SQL present');
  assert.ok(d.CREATED_TABLES.machines.some((s) => s.includes('idx_machines_project')), 'idx_machines_project present');
  assert.ok(d.CREATED_TABLES.machines.some((s) => s.includes('idx_machines_key')), 'idx_machines_key present');
  assert.ok(d.MACHINE_STATES, 'MACHINE_STATES exported');
  assert.ok(d.MACHINE_STATES.has('spawned'), 'MACHINE_STATES includes spawned');
  // THE TICKET'S VOCABULARY, NAME BY NAME. A state missing from this set is a
  // `400` for every writer that sends it, and a writer that fails open cannot
  // tell that refusal from a worker outage — so the set is pinned here rather
  // than left to whoever edits the constant next.
  for (const s of TICKET_STATES) {
    assert.ok(d.MACHINE_STATES.has(s), `MACHINE_STATES is missing the contract state ${s}`);
  }
  // Fly reports these two while a machine is mid-transition. They are not in
  // the ticket's list, but a listing carrying one of them must not `400` the
  // whole observe sweep.
  assert.ok(d.MACHINE_STATES.has('replacing'), 'MACHINE_STATES is missing the Fly state replacing');
  assert.ok(d.MACHINE_STATES.has('suspending'), 'MACHINE_STATES is missing the Fly state suspending');
  assert.ok(d.MACHINE_TERMINAL, 'MACHINE_TERMINAL exported');
  assert.ok(d.MACHINE_TERMINAL.has('gone'), 'MACHINE_TERMINAL includes gone');
  assert.ok(d.MACHINE_TERMINAL.has('destroyed'), 'MACHINE_TERMINAL includes destroyed');
  // `destroy_failed` means the machine is STILL THERE and the pool sweep will
  // retry the destroy (bin/fly-pool.sh). Marking it terminal would stamp
  // ended_at on a live machine and drop it out of `live=1`.
  assert.equal(d.MACHINE_TERMINAL.has('destroy_failed'), false,
    'destroy_failed must not be terminal — the sweep retries it');
});
