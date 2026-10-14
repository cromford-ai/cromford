import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-4489: the budget.* hard-cap defaults ride schema.sql as INSERT OR IGNORE
// rows, so bin/harness-sync.sh applies them before deploy and an operator's (or
// the self-host installer's) value is never reset by a re-apply.

const SCHEMA = jobsSchemaSql();

async function freshDb(t) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  db.exec(SCHEMA);
  return db;
}

const budgetRows = (db) => db.prepare("SELECT key, value, note, actor FROM settings WHERE key LIKE 'budget.%' ORDER BY key").all();

test('W1 the _default rows and the main build stages are seeded, by seed, citing BH-4489', async (t) => {
  const db = await freshDb(t);
  if (!db) return;
  const rows = budgetRows(db);
  const keys = new Set(rows.map((r) => r.key));
  for (const k of [
    'budget.stage._default.max_calls', 'budget.stage._default.max_usd', 'budget.stage._default.max_tokens',
    'budget.stage._default.day_usd', 'budget.stage._default.day_calls', 'budget.project._default.day_usd',
    'budget.stage.plan.max_usd', 'budget.stage.execute.max_usd', 'budget.stage.review.max_usd',
    'budget.stage.fix.max_usd', 'budget.stage.triage.day_usd',
  ]) assert.ok(keys.has(k), `missing seed ${k}`);
  for (const r of rows) {
    assert.equal(r.actor, 'seed', `${r.key} actor`);
    assert.match(r.note, /BH-4489/, `${r.key} note`);
  }
});

test('W2 every budget.* value parses on its axis', async (t) => {
  const db = await freshDb(t);
  if (!db) return;
  const rows = budgetRows(db);
  assert.ok(rows.length > 0);
  for (const { key, value } of rows) {
    assert.match(key, /^[a-z0-9_.-]{1,64}$/, `illegal key ${key}`);
    if (/_(calls|tokens)$/.test(key)) {
      assert.match(value, /^[0-9]+$/, `${key}=${value}`);
      assert.ok(Number(value) > 0, `${key}=${value} must be positive`);
    } else if (/_usd$/.test(key)) {
      assert.match(value, /^[0-9]+(\.[0-9]+)?$/, `${key}=${value}`);
      assert.ok(Number(value) > 0, `${key}=${value} must be positive`);
    } else {
      assert.fail(`${key} is not a known budget axis`);
    }
  }
});

test('W3 a re-apply keeps the operator value', async (t) => {
  const db = await freshDb(t);
  if (!db) return;
  db.prepare("UPDATE settings SET value='7', actor='operator' WHERE key='budget.stage._default.max_calls'").run();
  db.exec(SCHEMA);
  const r = db.prepare("SELECT value, actor FROM settings WHERE key='budget.stage._default.max_calls'").get();
  assert.equal(r.value, '7');
  assert.equal(r.actor, 'operator');
});
