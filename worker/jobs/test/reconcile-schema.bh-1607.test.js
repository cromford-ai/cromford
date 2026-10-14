// BH-1607 (BH-1595.0): the reconcile-prs owner + memory contract.
//
// Two D1 tables and five routes the BH-1595 siblings filled in. The schema
// half is driven on a real SQLite database (node:sqlite) with schema.sql
// applied twice, because bin/harness-sync.sh re-applies the whole file on every
// deploy and the seed row must not multiply. The route half goes in through
// the REAL worker.fetch (D2): the bearer and the route table are what place
// these five in ROUTES rather than OPEN_ROUTES.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SCHEMA = jobsSchemaSql();
const SECRET = 's';
const ISO = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;

async function sqlite() {
  try {
    const { DatabaseSync } = await import('node:sqlite');
    return DatabaseSync;
  } catch {
    return null;
  }
}

test('schema.sql applied twice seeds exactly one un-beaten reconcile-prs owner row', async (t) => {
  const DatabaseSync = await sqlite();
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  db.exec(SCHEMA);

  const cols = db.prepare('PRAGMA table_info(reconcile_owner_beat)').all().map((c) => c.name);
  assert.deepEqual(cols, ['lane', 'box', 'beat_at', 'expected_since', 'alerted_at', 'updated_at']);

  const rows = db.prepare('SELECT * FROM reconcile_owner_beat').all();
  assert.equal(rows.length, 1, `want one seed row, got ${JSON.stringify(rows)}`);
  const [r] = rows;
  assert.equal(r.lane, 'reconcile-prs');
  assert.equal(r.beat_at, null);
  assert.equal(r.box, null);
  assert.equal(r.alerted_at, null);
  assert.match(r.expected_since, ISO);
  assert.match(r.updated_at, ISO);
});

test('reconcile_memory takes the three kinds, refuses any other, and keys on (kind, name)', async (t) => {
  const DatabaseSync = await sqlite();
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const put = db.prepare('INSERT INTO reconcile_memory (kind, name, value, updated_at) VALUES (?, ?, ?, ?)');
  for (const kind of ['terminal', 'open', 'gone']) put.run(kind, 'Example_alpha_5', 'v', '2026-09-23T00:00:00Z');
  assert.throws(() => put.run('failed', 'Example_alpha_5', 'v', '2026-09-23T00:00:00Z'), /CHECK constraint/i);
  assert.throws(() => put.run('open', 'Example_alpha_5', 'w', '2026-09-23T00:00:00Z'), /UNIQUE|PRIMARY KEY/i);
  assert.equal(db.prepare('SELECT count(*) AS n FROM reconcile_memory').get().n, 3);
});

const STUBS = [
  ['POST', '/api/reconcile-prs/beat'],
  ['GET', '/api/reconcile-prs/owner'],
  ['PATCH', '/api/reconcile-prs/owner/alert'],
  ['GET', '/api/reconcile-prs/memory'],
  ['PUT', '/api/reconcile-prs/memory'],
];

const call = (DB, method, path, secret) => worker.fetch(
  new Request(`https://jobs.test${path}`, {
    method,
    headers: secret === null ? {} : { authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
    body: method === 'GET' ? undefined : '{}',
  }),
  { DB, HARNESS_SECRET: SECRET },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

// BH-1608 gave the three owner routes their bodies (test/routes/reconcile-owner.bh-1595.test.js)
// and BH-1610 the two memory routes (test/routes/reconcile-memory.bh-1595.test.js):
// none of the five is a 501 stub any more.
test('the reconcile-prs memory routes are real behind the bearer: empty GET and empty PUT answer 200', async (t) => {
  const opened = await openDb();
  if (!opened) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { DB } = opened;
  const get = await call(DB, 'GET', '/api/reconcile-prs/memory', SECRET);
  assert.equal(get.status, 200, JSON.stringify(get));
  assert.deepEqual(get.body.rows, []);
  assert.equal(get.body.truncated, false);
  const put = await call(DB, 'PUT', '/api/reconcile-prs/memory', SECRET);
  assert.equal(put.status, 200, JSON.stringify(put));
  assert.equal(put.body.ok, true);
});

test('without the bearer the five routes answer 401, so they sit in ROUTES and not OPEN_ROUTES', async (t) => {
  const opened = await openDb();
  if (!opened) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { DB } = opened;
  for (const [method, path] of STUBS) {
    const got = await call(DB, method, path, null);
    assert.equal(got.status, 401, `${method} ${path}: ${JSON.stringify(got)}`);
  }
});
