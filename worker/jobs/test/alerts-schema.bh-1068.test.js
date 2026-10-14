import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { ensureTable, CREATED_TABLES } from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1068: the alerts table and its worker self-create mirror are the contract
// every other slice of BH-1030 imports. This test proves schema.sql is
// idempotent, carries the expected indexes and seeds, and that the in-worker
// CREATED_TABLES.alerts entry creates the same shape.

const SCHEMA = jobsSchemaSql();

function parseAlertsTable(sql) {
  const start = sql.search(/CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+alerts\s*\(/is);
  assert.ok(start !== -1, 'schema.sql must contain CREATE TABLE IF NOT EXISTS alerts');
  let paren = start + sql.slice(start).indexOf('(');
  let depth = 0;
  let end = -1;
  for (let i = paren; i < sql.length; i++) {
    if (sql[i] === '(') depth++;
    else if (sql[i] === ')') { depth--; if (depth === 0) { end = i; break; } }
  }
  assert.ok(end !== -1, 'could not find matching close paren in alerts table');
  return sql.slice(paren + 1, end).split('\n')
    .map((s) => s.trim())
    .filter((s) => s && !s.startsWith('--'))
    .map((s) => {
      s = s.replace(/,\s*$/, '');
      const parts = s.split(/\s+/);
      const name = parts[0];
      const type = parts.slice(1).join(' ').replace(/--.*/, '').replace(/,\s*$/, '').trim();
      return { name, type };
    });
}

function pragmaColumns(db) {
  const rows = db.prepare('PRAGMA table_info(alerts)').all();
  return rows.map((r) => ({
    name: r.name,
    type: r.type,
    notnull: Boolean(r.notnull),
    dflt_value: r.dflt_value,
  }));
}

test('schema.sql: alerts table, indexes and settings seeds', async (t) => {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return;
  }

  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);

  // Re-runnable additive DDL.
  db.exec(SCHEMA);

  const count = db.prepare('SELECT count(*) AS n FROM alerts').get().n;
  assert.equal(count, 0, 'alerts table ships empty');

  const indexes = db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='alerts' ORDER BY name").all();
  const names = indexes.map((r) => r.name);
  assert.ok(names.includes('idx_alerts_state'), 'missing idx_alerts_state');
  assert.ok(names.includes('idx_alerts_family'), 'missing idx_alerts_family');

  const flush = db.prepare("SELECT value, actor, note FROM settings WHERE key='alert_flush_ttl_s'").get();
  assert.ok(flush, 'missing alert_flush_ttl_s seed');
  assert.equal(flush.value, '2700');
  assert.equal(flush.actor, 'seed');
  assert.match(String(flush.note), /BH-1030/);

  const lease = db.prepare("SELECT value, actor, note FROM settings WHERE key='alert_claim_lease_s'").get();
  assert.ok(lease, 'missing alert_claim_lease_s seed');
  assert.equal(lease.value, '900');
  assert.equal(lease.actor, 'seed');
  assert.match(String(lease.note), /BH-1030/);

  db.close();
});

test('CREATED_TABLES.alerts creates the same columns as schema.sql', async (t) => {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return;
  }

  const expected = parseAlertsTable(SCHEMA);
  const db = new DatabaseSync(':memory:');
  const env = { DB: db };
  await ensureTable(env, 'alerts');
  await ensureTable(env, 'alerts'); // idempotent

  const got = pragmaColumns(db);
  assert.equal(got.length, expected.length, `column count: ${got.map((c) => c.name).join(',')}`);
  for (let i = 0; i < expected.length; i++) {
    assert.equal(got[i].name, expected[i].name, `column ${i}`);
    assert.equal(got[i].type.toUpperCase(), expected[i].type.split(/\s+/)[0].toUpperCase(), `type for ${got[i].name}`);
  }

  // Defaults that the worker compare-and-swap relies on.
  const countCol = got.find((c) => c.name === 'count');
  assert.ok(countCol, 'count column exists');
  assert.equal(String(countCol.dflt_value), '1', 'count defaults to 1');
  const stateCol = got.find((c) => c.name === 'state');
  assert.ok(stateCol, 'state column exists');
  assert.equal(String(stateCol.dflt_value), "'new'", "state defaults to 'new'");

  db.close();
});
