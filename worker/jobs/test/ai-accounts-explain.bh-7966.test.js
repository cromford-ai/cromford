// BH-7966 (BH-7937.2): the ai_accounts fragment holds no token column, and
// each hot query of src/routes/ai-accounts.js uses an index at volume: 5,000
// accounts and 50,000 envelope events (the iron law on indexes, BH-6730).
//   E1 no token-like column      X1 duplicate lookup on ux_ai_accounts_vendor_label
//   X2 events join on ix_secret_envelope_events_env
//   X3 status newest event on ix_secret_envelope_events_env
//   X4 the list ORDER BY needs no temp b-tree; no bare SCAN of either table
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import * as MOD from '../src/routes/ai-accounts.js';

const SCHEMA_D = new URL('../schema.d/', import.meta.url);
const FRAGMENT = readdirSync(SCHEMA_D).find((f) => /^\d{12}-bh-7966-ai-accounts\.sql$/.test(f));
const VENDORS = ['claude', 'codex', 'openrouter', 'fireworks', 'xai'];
const TABLES = ['ai_accounts', 'secret_envelope_events', 'secret_envelopes'];

async function seeded(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  const { db } = o;
  db.exec('BEGIN');
  const acc = db.prepare('INSERT INTO ai_accounts (id, vendor, label, plan, use_kind, envelope_id, created_by, created_at, revoked_at) VALUES (?,?,?,?,?,?,?,?,?)');
  const ev = db.prepare("INSERT INTO secret_envelope_events (envelope_id, scope, event, detail, at) VALUES (?, 'ai-account:x', ?, NULL, '2026-10-23T00:00:00Z')");
  for (let i = 0; i < 5000; i++) {
    const env = `env-${i}`;
    acc.run(`acc-${i}`, VENDORS[i % 5], `label-${i}`, null, 'pool', env, 'api', '2026-10-23T00:00:00Z', i % 50 === 0 ? '2026-10-23T01:00:00Z' : null);
    for (let k = 0; k < 10; k++) ev.run(env, ['stored', 'consumed', 'applied', 'apply_failed', 'expired'][k % 5]);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  return o;
}

test('E1 the ai_accounts fragment has no column that could hold a token', () => {
  assert.ok(FRAGMENT, 'no <stamp>-bh-7966-ai-accounts.sql fragment');
  const sql = readFileSync(new URL(FRAGMENT, SCHEMA_D), 'utf8').replace(/--.*$/gm, '');
  const m = /CREATE TABLE IF NOT EXISTS ai_accounts \(([\s\S]*?)\n\);/.exec(sql);
  assert.ok(m, 'the fragment creates ai_accounts');
  const cols = m[1].split('\n').map((l) => l.trim().split(/\s+/)[0]).filter(Boolean);
  assert.deepEqual(cols, ['id', 'vendor', 'label', 'plan', 'use_kind', 'envelope_id', 'created_by', 'created_at', 'revoked_at']);
  for (const c of cols) assert.doesNotMatch(c, /token|secret|key_value|api_key|cipher|state/i, c);
});

test('X1 the duplicate lookup and the insert conflict target use ux_ai_accounts_vendor_label', async (t) => {
  const o = await seeded(t); if (!o) return;
  const lines = plan(o.db, 'SELECT id FROM ai_accounts WHERE vendor=?1 AND label=?2', 'claude', 'label-5');
  assert.ok(lines.some((l) => /ux_ai_accounts_vendor_label/.test(l)), lines.join(' | '));
  assert.deepEqual(fullScans(lines, TABLES), []);
});

test('X2 the list events join reads ix_secret_envelope_events_env per account, never a full scan of the events', async (t) => {
  const o = await seeded(t); if (!o) return;
  const lines = plan(o.db, MOD.LIST_EVENTS_SQL);
  assert.ok(lines.some((l) => /^SEARCH e USING (COVERING )?INDEX ix_secret_envelope_events_env/.test(l)), lines.join(' | '));
  assert.ok(!lines.some((l) => /^SCAN e\b/.test(l)), lines.join(' | '));
  assert.deepEqual(fullScans(lines, ['secret_envelope_events']), []);
});

test('X3 the status read (newest event of one envelope) uses ix_secret_envelope_events_env', async (t) => {
  const o = await seeded(t); if (!o) return;
  const lines = plan(o.db, MOD.NEWEST_EVENT_SQL, 'env-7');
  assert.ok(lines.some((l) => /ix_secret_envelope_events_env/.test(l)), lines.join(' | '));
  assert.deepEqual(fullScans(lines, TABLES), []);
  const stored = plan(o.db, MOD.STORED_SCOPE_SQL, 'env-7');
  assert.ok(stored.some((l) => /ix_secret_envelope_events_env/.test(l)), stored.join(' | '));
  assert.deepEqual(fullScans(stored, TABLES), []);
});

test('X4 the list is read in ux order (no temp b-tree); the cost and registry joins use their indexes', async (t) => {
  const o = await seeded(t); if (!o) return;
  const lines = plan(o.db, MOD.LIST_SQL);
  assert.ok(lines.some((l) => /ux_ai_accounts_vendor_label/.test(l)), lines.join(' | '));
  assert.ok(!lines.some((l) => /TEMP B-TREE/.test(l)), lines.join(' | '));
  const costLines = plan(o.db, MOD.TODAY_COST_SQL, '2026-10-23T00:00:00Z');
  assert.deepEqual(fullScans(costLines, ['cost_rows']), [], costLines.join(' | '));
  assert.ok(costLines.some((l) => /cost_rows .*idx_cost_rows_(ts|account)/.test(l)), costLines.join(' | '));
  const boxLines = plan(o.db, MOD.BOXES_SQL);
  assert.deepEqual(fullScans(boxLines, ['registry_box_accounts']), [], boxLines.join(' | '));
  const setLines = plan(o.db, MOD.ACCOUNT_SETTINGS_SQL);
  assert.deepEqual(fullScans(setLines, ['settings']), [], setLines.join(' | '));
});
