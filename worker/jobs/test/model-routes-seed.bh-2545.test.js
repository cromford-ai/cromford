import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2545 — a docs/lock/tests-only diff under the line cap is reviewed by the
// review.trivial role when REVIEW_TRIVIAL_MODE=route and the class is in
// REVIEW_TRIVIAL_ROUTE_CLASSES (bin/lib/review-saving.sh
// review_trivial_pick). The model is this seed row, never a literal in the lane.
// Driven against THE SQL THAT SHIPS.
const SCHEMA = jobsSchemaSql();
const openDb = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return db; };
const ladder = (db, role) => db.prepare(
  'SELECT position, model, runner, project, scope, updated_by FROM model_routes WHERE role=? ORDER BY position').all(role);

test('S1: a fresh DB seeds review.trivial at hub scope, one Haiku rung on the claude runner', () => {
  const db = openDb();
  assert.deepEqual(ladder(db, 'review.trivial').map((r) => ({ ...r })), [
    { position: 0, model: 'claude-haiku-4-5-20251001', runner: 'claude', project: null, scope: 'hub', updated_by: 'seed' },
  ]);
  db.close();
});

test('S2: re-applying schema.sql never overwrites an operator\'s edit to review.trivial', () => {
  const db = openDb();
  db.prepare("UPDATE model_routes SET model='operator-pick', updated_by='hub' WHERE role='review.trivial' AND project IS NULL").run();
  db.exec(SCHEMA);
  db.exec(SCHEMA);
  assert.deepEqual(ladder(db, 'review.trivial').map((r) => [r.position, r.model, r.updated_by]),
    [[0, 'operator-pick', 'hub']]);
  db.close();
});

test('S3: an operator who removed review.trivial (a model_route_changes tombstone) does not get it back', () => {
  const db = openDb();
  db.prepare("DELETE FROM model_routes WHERE role='review.trivial' AND project IS NULL").run();
  db.prepare("INSERT INTO model_route_changes (scope, project, role, position, before_model, before_runner, actor, reason, at) VALUES ('hub', NULL, 'review.trivial', 0, 'claude-haiku-4-5-20251001', 'claude', 'hub', 'removed', '2026-09-26T01:00:00Z')").run();
  db.exec(SCHEMA);
  assert.deepEqual(ladder(db, 'review.trivial'), []);
  db.close();
});
