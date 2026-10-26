// BH-8317 (MKF-2): the project_secret_names fragment holds no value column, and
// each hot query of src/routes/project-secrets.js uses an index at 10,000 rows
// over 100 projects (the iron law on indexes, BH-6730).
//   E1 no column that could hold a value
//   E2 the list reads the PK range in order: no temp b-tree, no full SCAN
//   E3 the pending count uses ix_project_secret_names_project_set_at
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { plan, fullScans } from './lib/d1-volume.bh-6727.js';
import * as MOD from '../src/routes/project-secrets.js';

const SCHEMA_D = new URL('../schema.d/', import.meta.url);
const FRAGMENT = readdirSync(SCHEMA_D).find((f) => /^\d{12}-bh-8317-project-secret-names\.sql$/.test(f));

async function seeded(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  const { db } = o;
  db.exec('BEGIN');
  const ins = db.prepare('INSERT INTO project_secret_names (project, name, apps, need, set_at, set_by, digest, updated_at) VALUES (?,?,?,?,?,?,?,?)');
  for (let p = 0; p < 100; p++) {
    for (let i = 0; i < 100; i++) {
      ins.run(`proj-${p}`, `NAME_${i}`, '["pool-x"]', i % 7 ? 'required' : 'optional', i % 10 ? '2026-10-25T00:00:00Z' : null, 'fixture-op', null, '2026-10-25T00:00:00Z');
    }
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  return o;
}

test('E1 the project_secret_names fragment has no column that could hold a value', () => {
  assert.ok(FRAGMENT, 'no <stamp>-bh-8317-project-secret-names.sql fragment');
  const sql = readFileSync(new URL(FRAGMENT, SCHEMA_D), 'utf8').replace(/--.*$/gm, '');
  const m = /CREATE TABLE IF NOT EXISTS project_secret_names \(([\s\S]*?)\n\);/.exec(sql);
  assert.ok(m, 'the fragment creates project_secret_names');
  const cols = m[1].split('\n').map((l) => l.trim().split(/\s+/)[0]).filter((c) => c && c !== 'PRIMARY');
  assert.deepEqual(cols, ['project', 'name', 'apps', 'need', 'set_at', 'set_by', 'digest', 'updated_at']);
  for (const c of cols) assert.doesNotMatch(c, /^value$|secret|plaintext|token|cipher/i, c);
});

test('E2 the GET list at 10k rows reads the primary key range in order, no temp b-tree, no full scan', async (t) => {
  const o = await seeded(t); if (!o) return;
  const lines = plan(o.db, MOD.LIST_SQL, 'proj-42');
  assert.ok(lines.some((l) => /sqlite_autoindex_project_secret_names_1/.test(l)), lines.join(' | '));
  assert.ok(!lines.some((l) => /TEMP B-TREE/.test(l)), lines.join(' | '));
  assert.deepEqual(fullScans(lines, ['project_secret_names']), []);
});

test('E3 the pending count at 10k rows uses ix_project_secret_names_project_set_at', async (t) => {
  const o = await seeded(t); if (!o) return;
  const lines = plan(o.db, MOD.PENDING_SQL, 'proj-42');
  assert.ok(lines.some((l) => /ix_project_secret_names_project_set_at/.test(l)), lines.join(' | '));
  assert.deepEqual(fullScans(lines, ['project_secret_names']), []);
});
