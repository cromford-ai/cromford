// BH-2516.0 (BH-2644): the token health contract. The table, its ensureTable
// twin, the warn_h settings seed and the two stub routes, driven through the
// REAL router (worker.fetch) against a node:sqlite D1 built from schema.sql.
// BH-2645 replaced the stubs with the real read and write; A2/A3 pin their
// answers on an empty table here, and the full cases are in
// token-health-routes.bh-2645.test.js.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../../src/index.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';
import { CREATED_TABLES, ensureTable } from '../../src/lib/core.js';
import { jobsSchemaSql } from '../lib/jobs-schema.js';

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();
const norm = (s) => s.replace(/\s+/g, ' ').replace(/\( /g, '(').replace(/ \)/g, ')').trim();

const call = (DB, path, { method = 'GET', body, secret = SECRET } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: secret === null ? {} : { authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};

test('BH-2516.0 token health contract', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('A1 belt DDL == schema.sql, and ensureTable creates token_health with PK (kind, subject)', async () => {
    const stmts = CREATED_TABLES.token_health;
    assert.ok(Array.isArray(stmts) && stmts.length === 1, 'one statement: the table');
    const m = SCHEMA.match(/CREATE TABLE IF NOT EXISTS token_health \([\s\S]*?\n\);/);
    assert.ok(m, 'schema.sql carries the token_health CREATE');
    assert.equal(norm(stmts[0]), norm(m[0].replace(/;$/, '')));

    const fresh = await openDb();
    fresh.db.exec('DROP TABLE IF EXISTS token_health');
    await ensureTable({ DB: fresh.DB }, 'token_health');
    const cols = fresh.db.prepare('PRAGMA table_info(token_health)').all();
    assert.deepEqual(cols.map((c) => c.name), [
      'kind', 'subject', 'box', 'expires_at', 'last_ok_at', 'last_attempt_at',
      'last_ok', 'fail_count', 'last_error', 'updated_at',
    ]);
    const pk = Object.fromEntries(cols.filter((c) => c.pk > 0).map((c) => [c.name, c.pk]));
    assert.deepEqual(pk, { kind: 1, subject: 2 });
    const fc = cols.find((c) => c.name === 'fail_count');
    assert.equal(fc.notnull, 1);
    assert.equal(String(fc.dflt_value), '0');
  });

  await t.test('A2 GET /api/account-leases/health on an empty DB answers the empty shape', async () => {
    const { DB } = await openDb();
    const res = await call(DB, '/api/account-leases/health');
    assert.equal(res.status, 200, JSON.stringify(res.body));
    const { as_of, ...rest } = res.body;
    // warn_h_source is 'settings': openDb builds from schema.sql, which seeds '24'.
    assert.deepEqual(rest, {
      accounts: [], warn_h: 24, warn_h_source: 'settings', truncated: { leases: false, tokens: false },
    });
    assert.equal(typeof as_of, 'string');
    assert.ok(Number.isFinite(Date.parse(as_of)), `as_of is ISO: ${as_of}`);
  });

  await t.test('A3 POST /api/account-leases/token-health answers 200 and writes the row', async () => {
    const { db, DB } = await openDb();
    const res = await call(DB, '/api/account-leases/token-health', {
      method: 'POST',
      body: { kind: 'oauth', subject: 'max1', box: 'hub', ok: true, expires_at: '2100-01-01T00:00:00Z' },
    });
    assert.equal(res.status, 200, JSON.stringify(res.body));
    assert.equal(res.body.ok, true);
    assert.equal(res.body.row.subject, 'max1');
    assert.equal(db.prepare('SELECT count(*) AS n FROM token_health').get().n, 1);
  });

  await t.test('A4 both routes refuse a request with no bearer', async () => {
    const { DB } = await openDb();
    const g = await call(DB, '/api/account-leases/health', { secret: null });
    assert.equal(g.status, 401);
    const p = await call(DB, '/api/account-leases/token-health', { method: 'POST', body: {}, secret: null });
    assert.equal(p.status, 401);
  });

  await t.test('A5 the old GET /api/account-leases answer is unchanged', async () => {
    const { DB } = await openDb();
    const c = await call(DB, '/api/account-leases/claim', { method: 'POST', body: { account: 'max1', machine_id: 'm1' } });
    assert.equal(c.status, 200, JSON.stringify(c.body));
    const res = await call(DB, '/api/account-leases');
    assert.equal(res.status, 200);
    assert.deepEqual(Object.keys(res.body).sort(), ['as_of', 'counts', 'live']);
    assert.equal(res.body.counts.max1, 1);
    assert.equal(res.body.live, 1);
  });

  await t.test('A6 schema.sql seeds lib.token-health.token_health_warn_h = 24', async () => {
    const { db } = await openDb();
    const row = db.prepare("SELECT value FROM settings WHERE key='lib.token-health.token_health_warn_h'").get();
    assert.ok(row, 'seed row exists');
    assert.equal(row.value, '24');
  });
});
