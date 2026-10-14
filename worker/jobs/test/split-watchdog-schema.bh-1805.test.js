import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { ensureTable } from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1805 (BH-1793.0) — the split-watchdog action ledger. schema.sql is what
// harness-sync applies at deploy, CREATED_TABLES is what the worker creates on
// a D1 that deploy never reached. The two must be the same table.

const SCHEMA = jobsSchemaSql();

function sqliteDB(db) {
  const prepare = (sql) => {
    const bindAndRun = (binds) => ({
      first: async () => db.prepare(sql).get(...binds) ?? null,
      all: async () => ({ results: db.prepare(sql).all(...binds) }),
      run: async () => {
        const r = db.prepare(sql).run(...binds);
        return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
      },
    });
    return { ...bindAndRun([]), bind: (...binds) => bindAndRun(binds) };
  };
  return { prepare };
}

async function openBareDb(t) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  return new DatabaseSync(':memory:');
}

function schemaColumns() {
  const start = SCHEMA.search(/CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+split_watchdog_actions\s*\(/is);
  assert.ok(start !== -1, 'schema.sql must contain CREATE TABLE IF NOT EXISTS split_watchdog_actions');
  const paren = start + SCHEMA.slice(start).indexOf('(');
  let depth = 0, end = -1;
  for (let i = paren; i < SCHEMA.length; i++) {
    if (SCHEMA[i] === '(') depth++;
    else if (SCHEMA[i] === ')') { depth--; if (depth === 0) { end = i; break; } }
  }
  assert.ok(end !== -1, 'no matching close paren for split_watchdog_actions');
  return SCHEMA.slice(paren + 1, end).split('\n')
    .map((s) => s.trim())
    .filter((s) => s && !s.startsWith('--') && !/^PRIMARY\s+KEY/i.test(s))
    .map((s) => {
      const parts = s.replace(/--.*/, '').replace(/,\s*$/, '').trim().split(/\s+/);
      return { name: parts[0], type: parts[1].toUpperCase(), rest: parts.slice(2).join(' ') };
    });
}

test('J1 CREATED_TABLES.split_watchdog_actions creates the same columns as schema.sql', async (t) => {
  const db = await openBareDb(t);
  if (!db) return;
  const expected = schemaColumns();
  await ensureTable({ DB: sqliteDB(db) }, 'split_watchdog_actions');
  const got = db.prepare('PRAGMA table_info(split_watchdog_actions)').all();
  assert.deepEqual(got.map((c) => c.name), expected.map((c) => c.name));
  assert.deepEqual(got.map((c) => String(c.type).toUpperCase()), expected.map((c) => c.type));
  for (let i = 0; i < expected.length; i++) {
    assert.equal(Number(got[i].notnull) === 1, /NOT\s+NULL/i.test(expected[i].rest), `NOT NULL on ${got[i].name}`);
  }
  const repeats = got.find((c) => c.name === 'repeats');
  assert.equal(String(repeats.dflt_value), '1', 'repeats defaults to 1');
  assert.deepEqual(
    expected.map((c) => c.name),
    ['project', 'family', 'child', 'step', 'reason_fp', 'reason', 'outcome', 'repeats', 'first_at', 'last_at', 'actor'],
  );
  db.close();
});

test('J2 the primary key is (project, child, step, reason_fp) in both shapes', async (t) => {
  const db = await openBareDb(t);
  if (!db) return;
  await ensureTable({ DB: sqliteDB(db) }, 'split_watchdog_actions');
  const pk = db.prepare('PRAGMA table_info(split_watchdog_actions)').all()
    .filter((c) => Number(c.pk) > 0).sort((a, b) => a.pk - b.pk).map((c) => c.name);
  assert.deepEqual(pk, ['project', 'child', 'step', 'reason_fp']);
  const ins = "INSERT INTO split_watchdog_actions (project, family, child, step, reason_fp, first_at, last_at) VALUES ('p','f','c','enqueue','fp','t','t')";
  db.prepare(ins).run();
  assert.throws(() => db.prepare(ins).run(), /UNIQUE/);
  db.close();

  const db2 = await openBareDb(t);
  db2.exec(SCHEMA);
  const pk2 = db2.prepare('PRAGMA table_info(split_watchdog_actions)').all()
    .filter((c) => Number(c.pk) > 0).sort((a, b) => a.pk - b.pk).map((c) => c.name);
  assert.deepEqual(pk2, ['project', 'child', 'step', 'reason_fp'], 'schema.sql pk');
  db2.close();
});

test('J3 both indexes exist and a second ensureTable does not throw', async (t) => {
  const db = await openBareDb(t);
  if (!db) return;
  const env = { DB: sqliteDB(db) };
  await ensureTable(env, 'split_watchdog_actions');
  await ensureTable(env, 'split_watchdog_actions');
  const idx = db.prepare('PRAGMA index_list(split_watchdog_actions)').all().map((r) => r.name);
  assert.ok(idx.includes('idx_split_watchdog_family'), `family index: ${idx}`);
  assert.ok(idx.includes('idx_split_watchdog_last'), `last index: ${idx}`);
  const cols = db.prepare('PRAGMA index_info(idx_split_watchdog_family)').all().map((r) => r.name);
  assert.deepEqual(cols, ['project', 'family', 'last_at']);
  db.close();

  const db2 = await openBareDb(t);
  db2.exec(SCHEMA);
  const idx2 = db2.prepare('PRAGMA index_list(split_watchdog_actions)').all().map((r) => r.name);
  assert.ok(idx2.includes('idx_split_watchdog_family') && idx2.includes('idx_split_watchdog_last'), `schema.sql indexes: ${idx2}`);
  db2.close();
});
