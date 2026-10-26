// BH-7977 (BH-7939.3): the one statement of GET /api/fleet/first-run uses an
// index at volume: 5,000 ai_accounts rows (5 vendors, 1 in 50 revoked) and
// 3,000 settings rows (the iron law on indexes, BH-6730).
//   X1 each ai_accounts sub-select (one per vendor) is a SEARCH on
//      ux_ai_accounts_vendor_label
//   X2 no full SCAN of ai_accounts or settings
import test from 'node:test';
import assert from 'node:assert/strict';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import { FIRST_RUN_SQL } from '../src/routes/fleet-first-run.js';

const VENDORS = ['claude', 'codex', 'openrouter', 'fireworks', 'xai'];

async function seeded(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  const { db } = o;
  db.exec('BEGIN');
  const acc = db.prepare("INSERT INTO ai_accounts (id, vendor, label, plan, use_kind, envelope_id, created_by, created_at, revoked_at) VALUES (?,?,?,NULL,'pool',NULL,'api','2026-10-25T00:00:00Z',?)");
  for (let i = 0; i < 5000; i++) acc.run(`acc-${i}`, VENDORS[i % 5], `label-${i}`, i % 50 === 0 ? '2026-10-25T01:00:00Z' : null);
  const set = db.prepare("INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-10-25T00:00:00Z')");
  for (let i = 0; i < 3000; i++) set.run(`fixture.knob.${i}`, String(i));
  db.exec('COMMIT');
  db.exec('ANALYZE');
  return o;
}

test('X1 each ai_accounts EXISTS is a SEARCH on ux_ai_accounts_vendor_label; each settings EXISTS is a PK search', async (t) => {
  const o = await seeded(t); if (!o) return;
  const lines = plan(o.db, FIRST_RUN_SQL);
  const acct = lines.filter((l) => /\bai_accounts\b/.test(l));
  assert.equal(acct.length, 5, `one SEARCH per vendor: ${lines.join(' | ')}`);
  for (const l of acct) assert.match(l, /^SEARCH ai_accounts USING (COVERING )?INDEX ux_ai_accounts_vendor_label \(vendor=\?\)$/, lines.join(' | '));
  const sets = lines.filter((l) => /\bsettings\b/.test(l));
  assert.equal(sets.length, 4, lines.join(' | '));
  for (const l of sets) assert.match(l, /^SEARCH settings USING INDEX sqlite_autoindex_settings_1 \(key=\?\)$/, lines.join(' | '));
});

test('X2 no full SCAN of ai_accounts or settings', async (t) => {
  const o = await seeded(t); if (!o) return;
  const lines = plan(o.db, FIRST_RUN_SQL);
  assert.deepEqual(fullScans(lines, ['ai_accounts', 'settings']), [], lines.join(' | '));
  assert.ok(!lines.some((l) => /^SCAN /.test(l) && l !== 'SCAN CONSTANT ROW'), lines.join(' | '));
});
