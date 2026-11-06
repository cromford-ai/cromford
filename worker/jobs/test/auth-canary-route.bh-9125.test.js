import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-9125 (slice C3 of BH-9064) — the auth canary runs on model_routes role
// `auth.canary`. The seed copies bootstrap.smoke rung 0 (a Haiku-class model),
// so no model id is written in the fragment, and its two NOT EXISTS guards keep
// an operator's edit (an existing row) or delete (a model_route_changes
// tombstone) when the schema is applied again on a later deploy.
// The suite runs against THE SQL THAT SHIPS (the composed schema.d/).
const SCHEMA = jobsSchemaSql();
const SCHEMA_D = fileURLToPath(new URL('../schema.d/', import.meta.url));
const FRAGMENT = readdirSync(SCHEMA_D).find((n) => /-bh-9125-auth-canary-route\.sql$/.test(n));

const openDb = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return db; };
const ladder = (db, role) => db.prepare(
  'SELECT position, model, runner FROM model_routes WHERE project IS NULL AND role = ? ORDER BY position',
).all(role).map((r) => `${r.position}:${r.model}:${r.runner}`);

test('R0: the fragment exists and names no model id', () => {
  assert.ok(FRAGMENT, 'worker/jobs/schema.d/<stamp>-bh-9125-auth-canary-route.sql');
  const sql = readFileSync(`${SCHEMA_D}${FRAGMENT}`, 'utf8');
  assert.doesNotMatch(sql, /claude-[a-z]+-\d/, 'the route is a copy, never a literal model id');
});

test('R1: a fresh DB seeds auth.canary as exactly bootstrap.smoke rung 0 (claude)', () => {
  const db = openDb();
  const smoke0 = ladder(db, 'bootstrap.smoke').find((r) => r.startsWith('0:') && r.endsWith(':claude'));
  assert.ok(smoke0, 'bootstrap.smoke has a claude rung 0 to copy');
  assert.deepEqual(ladder(db, 'auth.canary'), [smoke0]);
  db.close();
});

test('R2a: an operator row already present is never overwritten by a re-apply', () => {
  const db = openDb();
  db.prepare("UPDATE model_routes SET model = 'op-picked-model', updated_by = 'op' WHERE project IS NULL AND role = 'auth.canary'").run();
  db.exec(SCHEMA);
  assert.deepEqual(ladder(db, 'auth.canary'), ['0:op-picked-model:claude']);
  db.close();
});

test('R2b: a model_route_changes tombstone keeps a deleted route deleted on a re-apply', () => {
  const db = openDb();
  db.prepare("DELETE FROM model_routes WHERE project IS NULL AND role = 'auth.canary'").run();
  db.prepare(`INSERT INTO model_route_changes (scope, project, role, position, before_model, before_runner, actor, reason, at)
              VALUES ('hub', NULL, 'auth.canary', 0, 'x', 'claude', 'op', 'removed by hand', '2026-11-06T01:00:00Z')`).run();
  db.exec(SCHEMA);
  assert.deepEqual(ladder(db, 'auth.canary'), []);
  db.close();
});

test('R2c: with no row and no tombstone, a re-apply seeds the row again (a live hub gets it)', () => {
  const db = openDb();
  const want = ladder(db, 'auth.canary');
  db.prepare("DELETE FROM model_routes WHERE project IS NULL AND role = 'auth.canary'").run();
  db.exec(SCHEMA);
  assert.deepEqual(ladder(db, 'auth.canary'), want);
  db.close();
});
