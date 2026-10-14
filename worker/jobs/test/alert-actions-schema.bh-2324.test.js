import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker, { ensureTable, ROUTES } from '../src/index.js';
import { matchRoute } from '../src/lib/router.js';
import { ALERT_ID_RE, ALERT_ACTOR_RE, alertKnobs } from '../src/routes/alerts.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2368 (BH-2324 contract): the alert_actions audit table, its worker
// self-create mirror, the three alerts.js exports the sibling imports, and the
// two routes, whose handlers were filled in by BH-2369.

const SCHEMA = jobsSchemaSql();

async function sqlite(t) {
  try {
    return (await import('node:sqlite')).DatabaseSync;
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
}

function shape(db) {
  const cols = db.prepare('PRAGMA table_info(alert_actions)').all().map((r) => ({
    name: r.name,
    type: r.type.toUpperCase(),
    notnull: Boolean(r.notnull),
    pk: r.pk,
  }));
  const idx = db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='alert_actions' AND name NOT LIKE 'sqlite_%' ORDER BY name").all().map((r) => r.name);
  const idxCols = db.prepare("PRAGMA index_info('idx_alert_actions_alert')").all().map((r) => r.name);
  return { cols, idx, idxCols };
}

const EXPECTED_COLS = [
  { name: 'id', type: 'INTEGER', notnull: false, pk: 1 },
  { name: 'alert_id', type: 'TEXT', notnull: true, pk: 0 },
  { name: 'action', type: 'TEXT', notnull: true, pk: 0 },
  { name: 'actor', type: 'TEXT', notnull: true, pk: 0 },
  { name: 'note', type: 'TEXT', notnull: false, pk: 0 },
  { name: 'before_state', type: 'TEXT', notnull: false, pk: 0 },
  { name: 'after_state', type: 'TEXT', notnull: false, pk: 0 },
  { name: 'until', type: 'TEXT', notnull: false, pk: 0 },
  { name: 'outcome', type: 'TEXT', notnull: true, pk: 0 },
  { name: 'at', type: 'TEXT', notnull: true, pk: 0 },
];

test('schema.sql creates alert_actions and its index, re-runnably', async (t) => {
  const DatabaseSync = await sqlite(t);
  if (!DatabaseSync) return;
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  db.exec(SCHEMA);
  const s = shape(db);
  assert.deepEqual(s.cols, EXPECTED_COLS);
  assert.deepEqual(s.idx, ['idx_alert_actions_alert']);
  assert.deepEqual(s.idxCols, ['alert_id', 'at']);
  assert.equal(db.prepare('SELECT count(*) AS n FROM alert_actions').get().n, 0, 'ships empty');
  db.close();
});

test('CREATED_TABLES.alert_actions creates the same shape as schema.sql', async (t) => {
  const DatabaseSync = await sqlite(t);
  if (!DatabaseSync) return;
  const fromSchema = new DatabaseSync(':memory:');
  fromSchema.exec(SCHEMA);
  const fresh = new DatabaseSync(':memory:');
  await ensureTable({ DB: fresh }, 'alert_actions');
  await ensureTable({ DB: fresh }, 'alert_actions'); // idempotent
  assert.deepEqual(shape(fresh), shape(fromSchema));
  fromSchema.close();
  fresh.close();
});

test('the schema.sql alert_actions block carries the NO RLS STEP note', () => {
  const create = SCHEMA.indexOf('CREATE TABLE IF NOT EXISTS alert_actions');
  assert.notEqual(create, -1, 'alert_actions CREATE is in schema.sql');
  // The comment block directly above the CREATE: from the previous blank line.
  const header = SCHEMA.slice(SCHEMA.lastIndexOf('\n\n', create), create);
  assert.match(header, /NO RLS STEP/);
  assert.match(header, /APPEND-ONLY/);
});

test('alerts.js exports the id/actor classes and the knob reader unchanged', async () => {
  assert.ok(ALERT_ID_RE.test('abc-1.2'));
  assert.ok(!ALERT_ID_RE.test('a b'));
  assert.ok(ALERT_ACTOR_RE.test('medic@hub'));
  assert.ok(!ALERT_ACTOR_RE.test('a b'));
  const env = { DB: { prepare: () => ({ all: async () => ({ results: [] }) }) } };
  assert.deepEqual(await alertKnobs(env), { flush_ttl_s: 2700, claim_lease_s: 900 });
});

// A DB that throws on any touch: an invalid request must be refused before
// the handler reads or writes a row.
const NO_DB = new Proxy({}, { get() { throw new Error('handler touched the DB'); } });

for (const method of ['POST', 'GET']) {
  test(`${method} /api/alerts/actions is routed and refuses a bad request before the DB`, async () => {
    const hit = matchRoute(ROUTES, method, '/api/alerts/actions');
    assert.ok(hit, 'a route matches');
    const url = new URL('https://jobs.example/api/alerts/actions');
    const res = await hit.handler({ env: { DB: NO_DB }, body: {}, url, path: '/api/alerts/actions' });
    assert.equal(res.status, 400);
  });

  test(`${method} /api/alerts/actions through the worker's fetch is behind the bearer`, async () => {
    const env = { DB: NO_DB, HARNESS_SECRET: 's3cret' };
    const init = { method, headers: { authorization: 'Bearer s3cret', 'content-type': 'application/json' } };
    // POST: no action, no actor. GET: no id. Both are a 400 with no DB touch.
    if (method === 'POST') init.body = JSON.stringify({ id: 'a1' });
    const res = await worker.fetch(new Request('https://jobs.example/api/alerts/actions', init), env);
    assert.equal(res.status, 400);
    assert.match((await res.json()).error, method === 'POST' ? /^action must be one of/ : /^id must match/);
    const anon = await worker.fetch(new Request('https://jobs.example/api/alerts/actions', { method }), env);
    assert.equal(anon.status, 401);
  });
}
