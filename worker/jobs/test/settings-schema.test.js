import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// schema.sql, APPLIED — not read as text.
//
// The ticket's acceptance line is `sqlite3 :memory: < worker/jobs/schema.sql`,
// and `sqlite3` is not installed on the boxes, so the same check runs through
// Node's built-in SQLite (Node 22 in CI, harness-ci.yml). The property is the
// one that matters for a knob table an operator edits: re-applying this file is
// how the schema ships, so a second apply must neither error nor put the seed
// back over a number somebody deliberately changed. INSERT OR IGNORE is the
// whole defence, and a regex over the file would pass on a plain INSERT too.

const SCHEMA = jobsSchemaSql();

test('schema.sql applies twice and the settings seed never overwrites an operator edit', async (t) => {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    // Visible in TAP as a skip. A silent pass here would be the worst of both
    // worlds: the one check that proves the file is appliable, quietly absent.
    t.skip('node:sqlite unavailable on this runtime');
    return;
  }

  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);

  const seed = db.prepare("SELECT value, actor, note FROM settings WHERE key='gh_budget_min_remaining'").get();
  assert.ok(seed, 'the file applied but seeded no gh_budget_min_remaining row');
  assert.equal(seed.value, '800');
  assert.equal(seed.actor, 'seed');
  assert.match(String(seed.note), /GitHub/i);
  assert.equal(typeof seed.value, 'string', 'value is TEXT: the consumer parses it');

  // An operator raises the floor at 3am, and then the file is applied again by
  // the next deploy. Their number must survive it.
  db.prepare("UPDATE settings SET value='900', actor='box-small' WHERE key='gh_budget_min_remaining'").run();
  db.exec(SCHEMA);   // throws if the file is not idempotent

  const after = db.prepare("SELECT value, actor FROM settings WHERE key='gh_budget_min_remaining'").get();
  assert.equal(after.value, '900', 're-applying schema.sql reset an operator-set threshold');
  assert.equal(after.actor, 'box-small');

  // value is NOT NULL and key is the natural unique key — a second row for the
  // same knob is a second answer, and a consumer would read whichever it got.
  assert.throws(() => db.prepare("INSERT INTO settings (key,value,updated_at) VALUES ('gh_budget_min_remaining','1','t')").run());
  assert.throws(() => db.prepare("INSERT INTO settings (key,value,updated_at) VALUES ('other',NULL,'t')").run());

  db.close();
});
