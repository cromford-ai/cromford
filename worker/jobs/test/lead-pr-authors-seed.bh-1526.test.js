import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1526: WHO THE LEAD IS lives in a settings row, not in code (#1511).
// bin/lib/ticket-ownership.sh reads `lead_pr_authors` to exempt the lead's PR
// from the merge-time HOLD and to let it win one-PR-per-ticket over a pool PR.
// Applied, not grepped: the row must exist after the file is applied, and a
// re-apply (every deploy) must not reset an operator's edit of it.

const SCHEMA = jobsSchemaSql();

test('schema.sql seeds lead_pr_authors and a re-apply keeps an operator edit', async (t) => {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return;
  }
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const seed = db.prepare("SELECT value, actor, note FROM settings WHERE key='lead_pr_authors'").get();
  assert.ok(seed, 'the file applied but seeded no lead_pr_authors row');
  assert.equal(seed.value, 'operator');
  assert.equal(seed.actor, 'seed');
  assert.match(String(seed.note), /BH-1526/);

  db.prepare("UPDATE settings SET value='operator,another-lead', actor='console' WHERE key='lead_pr_authors'").run();
  db.exec(SCHEMA);
  const after = db.prepare("SELECT value FROM settings WHERE key='lead_pr_authors'").get();
  assert.equal(after.value, 'operator,another-lead', 're-applying schema.sql reset the lead row');
  // One PR per ticket is OPT-IN per project (the MC_TICKET_DEDUPE knob defaults
  // off): cromford is the only project seeded on, and no fleet-wide row.
  const on = db.prepare("SELECT value FROM settings WHERE key='lane.merge-conductor.cromford.mc_ticket_dedupe'").get();
  assert.ok(on, 'cromford must be seeded into the one-PR-per-ticket rule');
  assert.equal(on.value, '1');
  const others = db.prepare("SELECT key FROM settings WHERE key LIKE 'lane.merge-conductor.%mc_ticket_dedupe' AND key != 'lane.merge-conductor.cromford.mc_ticket_dedupe'").all();
  assert.equal(others.length, 0, 'no other project (and no fleet-wide row) is opted in by the seed');
  db.close();
});
