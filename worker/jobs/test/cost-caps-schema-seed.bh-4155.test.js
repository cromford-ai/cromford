// BH-4155 (BH-4141.3): schema.sql seeds every cost/lane cap as a
// `registry-seed` settings row, the DB copy of catalog/cost-caps.conf and
// catalog/lane-caps.conf that bin/lib/cost-budget.sh and bin/lib/lane-caps.sh
// read above the file.
//
// WHAT IS PINNED, on a REAL schema.sql database behind the node:sqlite shim and
// the real route table (worker.fetch):
//   W1 the seed rows are there, each a fleet cap key whose value passes the
//      same grammar PUT /api/cost-caps enforces
//   W2 POST /api/cost-caps/seed with exactly those rows changes and prunes
//      nothing: the operator-run seed tool and the schema agree
//   W3 an operator edit survives a re-apply of schema.sql (INSERT OR IGNORE)
//   W4 GET /api/settings serves them under actor registry-seed, the actor a
//      box's settings cache sorts into `seeded`
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { capFleetKey, validateCapValue } from '../src/lib/cost-caps.js';
import { REGISTRY_SEED_ACTOR } from '../src/lib/core.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

const call = (DB, path, { method = 'GET', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};

const capRows = (db) => db.prepare(
  "SELECT key, value, actor FROM settings WHERE key LIKE 'conf.cost-caps.%' OR key LIKE 'conf.lane-caps.%' ORDER BY key",
).all();

async function withDb(t, fn) {
  const opened = await openDb();
  if (opened === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }
  await fn(opened);
}

test('W1 schema.sql seeds every cap as a registry-seed row the cap grammar accepts', (t) => withDb(t, async ({ db }) => {
  const rows = capRows(db);
  assert.ok(rows.length >= 16, `expected >= 16 cap seed rows, got ${rows.length}`);
  for (const r of rows) {
    assert.equal(r.actor, REGISTRY_SEED_ACTOR, r.key);
    const cap = capFleetKey(r.key);
    assert.ok(cap, `${r.key} is a fleet cap key`);
    assert.equal(validateCapValue(cap, r.value), null, `${r.key}=${r.value}`);
  }
  const byKey = Object.fromEntries(rows.map((r) => [r.key, r.value]));
  assert.equal(byKey['conf.cost-caps.ceiling'], '4000');
  assert.equal(byKey['conf.lane-caps.lane.responder'], '150 60000');
}));

test('W2 the seed route with the same rows changes and prunes nothing', (t) => withDb(t, async ({ db, DB }) => {
  const rows = capRows(db).map(({ key, value }) => ({ key, value }));
  const r = await call(DB, '/api/cost-caps/seed', { method: 'POST', body: { rows } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.changed_keys, []);
  assert.deepEqual(r.body.pruned_keys, []);
  assert.equal(capRows(db).length, rows.length);
}));

test('W3 an operator edit survives a re-apply of schema.sql', (t) => withDb(t, async ({ db, DB }) => {
  const K = 'conf.cost-caps.budget.project-5';
  const r = await call(DB, '/api/cost-caps', { method: 'PUT', body: { key: K, value: '20 3', reason: 'w3', actor: 'console' } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  db.exec(SCHEMA);
  const row = db.prepare('SELECT value, actor FROM settings WHERE key=?').get(K);
  assert.equal(row.value, '20 3');
  assert.notEqual(row.actor, REGISTRY_SEED_ACTOR);
}));

test('W4 GET /api/settings serves the cap seeds under the registry-seed actor', (t) => withDb(t, async ({ DB }) => {
  const r = await call(DB, '/api/settings');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const s = r.body.settings.find((x) => x.key === 'conf.cost-caps.default');
  assert.ok(s, 'conf.cost-caps.default is served');
  assert.equal(s.value, '100 5');
  assert.equal(s.actor, REGISTRY_SEED_ACTOR);
}));
