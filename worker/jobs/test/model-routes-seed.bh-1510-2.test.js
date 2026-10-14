import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1510.2 — the roles the non-build lanes read once their literals are gone.
// Each value is the literal the lane carried on main (50380e9b) before #1510.2
// deleted it; schema.sql names the file:line on every row. Driven against THE
// SQL THAT SHIPS, the same idiom as model-routes.bh-1510.test.js.
const SCHEMA = jobsSchemaSql();
const openDb = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return db; };
const ladder = (db, role) => db.prepare(
  'SELECT position, model, runner, project, updated_by FROM model_routes WHERE role=? ORDER BY position').all(role);

// BH-1908 moved the rung-0 values to the live hub ladders; the rung-1s it
// added are pinned in model-routes-seed.bh-1908.test.js, so this checks rung 0.
const EXPECT = {
  'product.map': 'claude-opus-5-5',
  'product.signals': 'claude-opus-5-5',
  'product.ideate': 'claude-opus-5-5',
  'product.synth': 'claude-sonnet-5',
  'product.prd': 'claude-opus-5-5',
  'product.mockup': 'claude-opus-5-5',
  'product.revise': 'claude-opus-5-5',
  'greenfield.signals': 'claude-opus-5-5',
  'greenfield.ideate': 'claude-opus-5-5',
  'greenfield.synth': 'claude-sonnet-5',
  'greenfield.mockup': 'claude-opus-5-5',
  'greenfield.deck': 'claude-opus-5-5',
  'responder': 'claude-opus-5-5',
  'remediate': 'claude-sonnet-5',
  'rule.miner': 'claude-opus-5-5',
  'lander': 'claude-opus-5-5',
};

test('every role a #1510.2 lane reads is seeded, at hub scope, with today\'s value', () => {
  const db = openDb();
  for (const [role, model] of Object.entries(EXPECT)) {
    assert.deepEqual(ladder(db, role).slice(0, 1).map(({ position, model: m, runner, project, updated_by }) =>
      ({ position, model: m, runner, project, updated_by })),
      [{ position: 0, model, runner: 'claude', project: null, updated_by: 'seed' }], `seed for ${role}`);
  }
  assert.deepEqual(ladder(db, 'openrouter.default').map((r) => [r.position, r.model, r.runner]),
    [[0, 'anthropic/claude-opus-5.5', 'openrouter'], [1, 'anthropic/claude-fable-5.1', 'openrouter']]);
  db.close();
});

test('the housekeeping floor is a two-rung ladder: the floor lane, then the claude fallback', () => {
  const db = openDb();
  assert.deepEqual(ladder(db, 'housekeeping.floor').map((r) => [r.position, r.model, r.runner]), [
    [0, 'accounts/fireworks/models/deepseek-v4-flash-0731', 'fireworks'],
    [1, 'claude-sonnet-5', 'claude'],
  ]);
  db.close();
});

test('re-applying schema.sql never overwrites an operator\'s edit to a #1510.2 role', () => {
  const db = openDb();
  db.prepare("UPDATE model_routes SET model='operator-pick', updated_by='hub' WHERE role='responder' AND position=0 AND project IS NULL").run();
  db.prepare("UPDATE model_routes SET model='operator-floor' WHERE role='housekeeping.floor' AND position=1").run();
  db.exec(SCHEMA);
  assert.equal(ladder(db, 'responder')[0].model, 'operator-pick');
  assert.equal(ladder(db, 'housekeeping.floor')[1].model, 'operator-floor');
  // Two rungs since BH-1908 (the live ladder); the re-apply adds none.
  assert.equal(db.prepare("SELECT COUNT(*) n FROM model_routes WHERE role='responder'").get().n, 2);
  db.close();
});

test('an operator who cut the floor ladder to one rung keeps it: re-applying schema.sql never re-adds rung 1', () => {
  const db = openDb();
  // What PUT /api/model-routes does for a one-rung ladder: delete the trailing rung, audit it.
  db.prepare("DELETE FROM model_routes WHERE role='housekeeping.floor' AND project IS NULL AND position=1").run();
  db.prepare(`INSERT INTO model_route_changes (scope, project, role, position, before_model, before_runner, after_model, after_runner, actor, reason, at)
              VALUES ('hub', NULL, 'housekeeping.floor', 1, 'claude-sonnet-5', 'claude', NULL, NULL, 'op', 'one rung', '2026-09-23T00:00:00Z')`).run();
  db.exec(SCHEMA);
  assert.deepEqual(ladder(db, 'housekeeping.floor').map((r) => r.position), [0]);
  db.close();
});
