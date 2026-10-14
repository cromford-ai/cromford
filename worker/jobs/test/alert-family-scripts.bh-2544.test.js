import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker, { CREATED_TABLES } from '../src/index.js';
import { d1 } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-2575 (BH-2544.3): the bearer-gated route over alert_family_scripts.
// Every request goes through worker.fetch — the production entry point — so a
// case goes red if the route is dropped from ROUTES, not only if its handler
// changes. The DB is node:sqlite behind the D1 shim, so the real SQL runs.

const SCHEMA = jobsSchemaSql();
const SECRET = 's3cret';
const BASE = 'https://jobs.example/api/alert-family-scripts';

async function sqlite(t) {
  try {
    return (await import('node:sqlite')).DatabaseSync;
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
}

// A BARE database: no schema.sql, so the table exists only if the route's
// self-create made it.
async function bare(t) {
  const DatabaseSync = await sqlite(t);
  if (!DatabaseSync) return null;
  const db = new DatabaseSync(':memory:');
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}

function call(env, method, path = '', body, auth = true) {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  const init = { method, headers };
  if (body !== undefined) init.body = JSON.stringify(body);
  return worker.fetch(new Request(BASE + path, init), env);
}

function tableExists(db) {
  return Boolean(db.prepare("SELECT 1 AS x FROM sqlite_master WHERE type='table' AND name='alert_family_scripts'").get());
}
function count(db) {
  return tableExists(db) ? db.prepare('SELECT count(*) AS n FROM alert_family_scripts').get().n : 0;
}

function shape(db) {
  const cols = db.prepare('PRAGMA table_info(alert_family_scripts)').all().map((r) => ({ ...r }));
  const idx = db.prepare("PRAGMA index_list('alert_family_scripts')").all()
    .map((r) => ({ name: r.name, unique: r.unique, origin: r.origin }))
    .sort((a, b) => a.name.localeCompare(b.name));
  const idxCols = Object.fromEntries(idx.map((i) => [i.name, db.prepare(`PRAGMA index_info('${i.name}')`).all().map((r) => r.name)]));
  return { cols, idx, idxCols };
}

const GOOD = { match_kind: 'akey_prefix', match: 'disk:', verify: 'disk-full', actor: 'console' };

test('1. CREATED_TABLES.alert_family_scripts builds the same table as schema.sql', async (t) => {
  const DatabaseSync = await sqlite(t);
  if (!DatabaseSync) return;
  assert.ok(Array.isArray(CREATED_TABLES.alert_family_scripts), 'CREATED_TABLES has an alert_family_scripts entry');
  const fromSchema = new DatabaseSync(':memory:');
  fromSchema.exec(SCHEMA);
  const fresh = new DatabaseSync(':memory:');
  for (const sql of CREATED_TABLES.alert_family_scripts) fresh.exec(sql);
  const want = shape(fromSchema);
  assert.ok(want.cols.length > 0, 'schema.sql has the table');
  assert.deepEqual(shape(fresh), want);
  assert.ok(want.idx.some((i) => i.name === 'idx_alert_family_scripts_enabled_priority'));
  assert.throws(() => fresh.prepare(
    "INSERT INTO alert_family_scripts (id, match_kind, match, updated_at) VALUES ('x','nope','m','2026-01-01T00:00:00Z')",
  ).run(), /CHECK/);
  fromSchema.close();
  fresh.close();
});

test('2. GET on a bare DB self-creates the table and answers {rows:[], as_of}', async (t) => {
  const h = await bare(t);
  if (!h) return;
  assert.equal(tableExists(h.db), false);
  const res = await call(h.env, 'GET');
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.deepEqual(body.rows, []);
  assert.match(body.as_of, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
  assert.equal(tableExists(h.db), true);
});

test('3. PUT then GET round-trips one row with the schema defaults, actor and updated_at', async (t) => {
  const h = await bare(t);
  if (!h) return;
  assert.deepEqual((await (await call(h.env, 'GET')).json()).rows, []);
  const res = await call(h.env, 'PUT', '/disk-full', GOOD);
  assert.equal(res.status, 200);
  const { row, as_of } = await res.json();
  assert.deepEqual(row, {
    id: 'disk-full', match_kind: 'akey_prefix', match: 'disk:', verify: 'disk-full',
    on_clear: 'settle', on_repro: 'model', enabled: 1, priority: 100, note: null,
    actor: 'console', updated_at: as_of,
  });
  const got = await (await call(h.env, 'GET')).json();
  assert.deepEqual(got.rows, [row]);
});

test('4. PUT on an existing id updates it in place (one row)', async (t) => {
  const h = await bare(t);
  if (!h) return;
  assert.equal((await call(h.env, 'PUT', '/disk-full', GOOD)).status, 200);
  const res = await call(h.env, 'PUT', '/disk-full', { ...GOOD, priority: 5, on_repro: 'park', enabled: 0, note: 'quiet', actor: 'medic@hub' });
  assert.equal(res.status, 200);
  const { row } = await res.json();
  assert.equal(count(h.db), 1);
  assert.equal(row.priority, 5);
  assert.equal(row.on_repro, 'park');
  assert.equal(row.enabled, 0);
  assert.equal(row.note, 'quiet');
  assert.equal(row.actor, 'medic@hub');
  const stored = h.db.prepare("SELECT priority, on_repro, enabled FROM alert_family_scripts WHERE id='disk-full'").get();
  assert.deepEqual({ ...stored }, { priority: 5, on_repro: 'park', enabled: 0 });
});

test('5. GET orders by priority then id, and includes disabled rows', async (t) => {
  const h = await bare(t);
  if (!h) return;
  assert.equal((await call(h.env, 'PUT', '/b', { ...GOOD, verify: null, priority: 5 })).status, 200);
  assert.equal((await call(h.env, 'PUT', '/a', { ...GOOD, verify: null, priority: 5, enabled: 0 })).status, 200);
  assert.equal((await call(h.env, 'PUT', '/z', { ...GOOD, verify: null, priority: 1 })).status, 200);
  const { rows } = await (await call(h.env, 'GET')).json();
  assert.deepEqual(rows.map((r) => r.id), ['z', 'a', 'b']);
  assert.equal(rows.find((r) => r.id === 'a').enabled, 0);
  assert.equal(rows.find((r) => r.id === 'z').verify, null);
});

const REFUSED = [
  ['id Bad_ID', '/Bad_ID', GOOD, /^id /],
  ['id 49 chars', '/' + 'a'.repeat(49), GOOD, /^id /],
  ['id a%2Fb (decodes to a/b)', '/a%2Fb', GOOD, /^id /],
  ['id x%20y (decodes to x y)', '/x%20y', GOOD, /^id /],
  ['id a.b', '/a.b', GOOD, /^id /],
  ['verify ../x', '/ok', { ...GOOD, verify: '../x' }, /^verify /],
  ['verify a;rm -rf /', '/ok', { ...GOOD, verify: 'a;rm -rf /' }, /^verify /],
  ['verify x.sh', '/ok', { ...GOOD, verify: 'x.sh' }, /^verify /],
  ['verify $(id)', '/ok', { ...GOOD, verify: '$(id)' }, /^verify /],
  ['verify empty', '/ok', { ...GOOD, verify: '' }, /^verify /],
  ['verify 49 chars', '/ok', { ...GOOD, verify: 'v'.repeat(49) }, /^verify /],
  ['on_repro drop', '/ok', { ...GOOD, on_repro: 'drop' }, /^on_repro /],
  ['on_clear x', '/ok', { ...GOOD, on_clear: 'x' }, /^on_clear /],
  ['match_kind glob', '/ok', { ...GOOD, match_kind: 'glob' }, /^match_kind /],
  ['match empty', '/ok', { ...GOOD, match: '' }, /^match /],
  ['match blank', '/ok', { ...GOOD, match: '   ' }, /^match /],
  ['line_regex (', '/ok', { ...GOOD, match_kind: 'line_regex', match: '(' }, /^match /],
  ['enabled 2', '/ok', { ...GOOD, enabled: 2 }, /^enabled /],
  ['enabled true', '/ok', { ...GOOD, enabled: true }, /^enabled /],
  ['priority 1.5', '/ok', { ...GOOD, priority: 1.5 }, /^priority /],
  ['priority abc', '/ok', { ...GOOD, priority: 'abc' }, /^priority /],
  ['missing actor', '/ok', { ...GOOD, actor: undefined }, /^actor /],
  ['bad actor', '/ok', { ...GOOD, actor: 'a b' }, /^actor /],
];

test('6. every invalid PUT is a 400 naming the field, and writes no row', async (t) => {
  const h = await bare(t);
  if (!h) return;
  for (const [name, path, body, re] of REFUSED) {
    const res = await call(h.env, 'PUT', path, body);
    assert.equal(res.status, 400, name);
    assert.match((await res.json()).error, re, name);
    assert.equal(count(h.db), 0, `${name}: no row written`);
  }
});

// %2e%2e never reaches the route: the URL parser folds it to `..` and resolves
// the path to /api/, which is the worker's 404. Either way nothing is written.
test('6b. an id of %2e%2e is resolved away by the URL parser: 404, no row', async (t) => {
  const h = await bare(t);
  if (!h) return;
  const res = await call(h.env, 'PUT', '/%2e%2e', GOOD);
  assert.equal(res.status, 404);
  assert.equal(count(h.db), 0);
});

test('7. akey_prefix takes any string; line_regex takes a regex that compiles', async (t) => {
  const h = await bare(t);
  if (!h) return;
  const a = await call(h.env, 'PUT', '/paren', { ...GOOD, match: '(' });
  assert.equal(a.status, 200);
  assert.equal((await a.json()).row.match, '(');
  const b = await call(h.env, 'PUT', '/disk-pct', { ...GOOD, match_kind: 'line_regex', match: '^disk \\d+%' });
  assert.equal(b.status, 200);
  assert.equal((await b.json()).row.match, '^disk \\d+%');
  assert.equal(count(h.db), 2);
});

test('8. no bearer: GET and PUT are 401 and nothing is written', async (t) => {
  const h = await bare(t);
  if (!h) return;
  assert.equal((await call(h.env, 'GET', '', undefined, false)).status, 401);
  assert.equal((await call(h.env, 'PUT', '/disk-full', GOOD, false)).status, 401);
  assert.equal(count(h.db), 0);
});
