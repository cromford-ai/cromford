import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1510.4 — the bootstrap smoke turn (bin/bootstrap-machine.sh, the
// `# >>> smoke model` block) reads its model from the bootstrap.smoke role. The
// seed carries the exact id the script passed before #1510.4 deleted the
// literal, so deploying it changes nothing. Driven against THE SQL THAT SHIPS.
const SCHEMA = jobsSchemaSql();
const openDb = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return db; };
const ladder = (db, role) => db.prepare(
  'SELECT position, model, runner, project, scope, updated_by FROM model_routes WHERE role=? ORDER BY position').all(role);

test('bootstrap.smoke is seeded at hub scope with the model the smoke turn used before', () => {
  const db = openDb();
  assert.deepEqual(ladder(db, 'bootstrap.smoke').map((r) => ({ ...r })), [
    { position: 0, model: 'claude-haiku-4-5-20251001', runner: 'claude', project: null, scope: 'hub', updated_by: 'seed' },
  ]);
  db.close();
});

test('re-applying schema.sql never overwrites an operator\'s edit to bootstrap.smoke', () => {
  const db = openDb();
  db.prepare("UPDATE model_routes SET model='operator-pick', updated_by='hub' WHERE role='bootstrap.smoke' AND project IS NULL").run();
  db.exec(SCHEMA);
  db.exec(SCHEMA);
  assert.deepEqual(ladder(db, 'bootstrap.smoke').map((r) => [r.position, r.model, r.updated_by]),
    [[0, 'operator-pick', 'hub']]);
  db.close();
});
