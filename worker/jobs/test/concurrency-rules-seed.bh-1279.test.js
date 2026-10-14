import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1279: the 2026-09-14 NO-CAPS order (PR #343) deleted the
// `concurrency_rules` rows repo/*/build and box/*/build from the live D1 — the
// fleet default is "no row = unlimited". BH-1000's deploy-time schema re-apply
// runs this file's INSERT OR IGNORE seed on every deploy, and INSERT OR IGNORE
// protects a RAISED row but resurrects a DELETED one: the first deploy after
// BH-1000 silently restored both rows and the fleet dropped to one build per
// repo/box, twice (2026-09-20 and again 2026-09-21 20:40Z per the ticket's
// second comment). This test pins the fix: the seed must never carry a repo or
// box concurrency_rules row again, so a re-apply can never resurrect one an
// operator deleted.

const SCHEMA = jobsSchemaSql();

test('schema.sql seed: no repo or box concurrency_rules row (no row = unlimited is the default)', async (t) => {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return;
  }

  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);

  const rows = db.prepare('SELECT scope, selector, kind, max_concurrent FROM concurrency_rules ORDER BY scope, selector, kind').all();
  const scopes = rows.map((r) => r.scope);

  assert.ok(!scopes.includes('repo'), `seed must not carry a repo concurrency_rules row, found: ${JSON.stringify(rows)}`);
  assert.ok(!scopes.includes('box'), `seed must not carry a box concurrency_rules row, found: ${JSON.stringify(rows)}`);

  // The ticket scope is the TK-66/67 double-build guard, not part of the
  // 9/14 NO-CAPS order, and stays seeded.
  const ticketRow = rows.find((r) => r.scope === 'ticket' && r.selector === '*' && r.kind === '*');
  assert.ok(ticketRow, 'the ticket/*/* double-build guard row must still be seeded');
  assert.equal(ticketRow.max_concurrent, 1);

  db.close();
});

test('schema.sql seed: applying twice after an operator deletes repo/box rows leaves them deleted', async (t) => {
  // This is the exact failure shape from the ticket: an operator (or the
  // 9/14 NO-CAPS order) DELETEs the rows, a redeploy re-applies schema.sql,
  // and INSERT OR IGNORE must not bring a deleted row back.
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return;
  }

  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  db.exec("DELETE FROM concurrency_rules WHERE scope IN ('repo','box')");

  // Simulate the redeploy's schema re-apply (BH-1000: the whole file, every
  // statement IF NOT EXISTS / INSERT OR IGNORE).
  db.exec(SCHEMA);
  db.exec(SCHEMA);

  const rows = db.prepare("SELECT scope FROM concurrency_rules WHERE scope IN ('repo','box')").all();
  assert.equal(rows.length, 0, `a re-applied schema must not resurrect a deleted repo/box row, found: ${JSON.stringify(rows)}`);

  db.close();
});
