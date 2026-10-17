import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-7258 (BH-7244.1) — the product.pm hub route is seeded from product.prd
// rung 0, so the PM agent runs the model the PRD stage runs and no model
// literal enters the fragment. Driven against THE SQL THAT SHIPS.
const SCHEMA = jobsSchemaSql();
const openDb = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return db; };
const rungs = (db, role) => db.prepare(
  'SELECT position, model, runner, scope FROM model_routes WHERE role = ? AND project IS NULL ORDER BY position'
).all(role).map((r) => ({ ...r }));

test('W1: product.pm rung 0 equals product.prd rung 0', () => {
  const db = openDb();
  const prd = rungs(db, 'product.prd');
  const pm = rungs(db, 'product.pm');
  assert.ok(prd.length > 0, 'product.prd has a seed row');
  assert.equal(pm.length, 1);
  assert.equal(pm[0].position, 0);
  assert.equal(pm[0].scope, 'hub');
  assert.equal(pm[0].model, prd[0].model);
  assert.equal(pm[0].runner, prd[0].runner);
});

test('W1b: the seed follows product.prd, not a literal', () => {
  const db = new DatabaseSync(':memory:');
  const fixture = 'fixture-model-bh7258';
  // Change the prd seed before the PM fragment runs: the pm row must follow it.
  const sql = SCHEMA.replace(
    /('hub', NULL, 'product\.prd', 0, )'[^']+'/,
    `$1'${fixture}'`,
  );
  assert.notEqual(sql, SCHEMA, 'the product.prd seed row was found in the schema');
  db.exec(sql);
  assert.equal(rungs(db, 'product.pm')[0]?.model, fixture);
});

test('W2: a second exec of the schema leaves exactly one product.pm row', () => {
  const db = openDb();
  db.exec(SCHEMA);
  assert.equal(rungs(db, 'product.pm').length, 1);
});

test('W3: an operator cut (a model_route_changes row) is never seeded back', () => {
  const db = openDb();
  db.prepare(
    `INSERT INTO model_route_changes (scope, project, role, position, before_model, before_runner, after_model, after_runner, actor, reason, at)
     VALUES ('hub', NULL, 'product.pm', 0, 'x', 'claude', NULL, NULL, 'op-test', 'cut', '2026-10-17T00:00:00Z')`
  ).run();
  db.prepare("DELETE FROM model_routes WHERE role = 'product.pm' AND project IS NULL").run();
  db.exec(SCHEMA);
  assert.equal(rungs(db, 'product.pm').length, 0);
});
