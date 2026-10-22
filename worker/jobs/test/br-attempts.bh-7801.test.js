// BH-7801 (slice C1 of #4157): GET /api/br-attempts, the resolver record's
// attempts as ledger rows (kind br_attempt, key <project>/<rkey>#<digits>#<n6>,
// bin/blocked-resolver.d/bh-7801-br-attempts.sh bra_key). Driven through the
// REAL router (worker.fetch) on the node:sqlite shim; the rows are seeded
// through PUT /api/ledger, the path bra_put writes them by.
//   W1  5 rows → 5, oldest first; limit=2 → the newest 2, oldest first
//   W2  another project and another kind under the same key → 0 of them
//   W3  rkey k never returns k-2 rows; bad input → 400; no rows → 200 []
//   W4  no bearer → 401; ONE statement per GET
import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { ROUTES } from '../src/index.js';
import { matchRoute } from '../src/lib/router.js';
import { routes as family } from '../src/routes/br-attempts.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'tok-fixture-bh7801';

const call = (DB, method, path, body, auth = SECRET) => {
  const headers = { 'content-type': 'application/json' };
  if (auth !== null) headers.authorization = `Bearer ${auth}`;
  return worker.fetch(new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  }), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const put = (DB, kind, key, status, detail) => call(DB, 'PUT', '/api/ledger', { kind, key, status, detail, actor: 'box-fixture' });
const att = (i, action = 'rebuild') => JSON.stringify({ at: `2026-10-21 19:0${i}:00Z`, action, reason: `r${i}`, detail: `d${i}` });
const key = (p, k, i) => `${p}/${k}#2026102119${String(i).padStart(2, '0')}00#${String(i).padStart(6, '0')}`;
const get = (DB, q, auth) => call(DB, 'GET', `/api/br-attempts?${q}`, undefined, auth);

async function fresh(t) {
  const h = await openDb();
  if (h === null) t.skip('node:sqlite unavailable in this runtime');
  return h;
}

test('BH-7801 GET /api/br-attempts', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W1 oldest first; limit keeps the newest', async (t) => {
    const { DB } = await fresh(t);
    for (const i of [3, 1, 5, 2, 4]) assert.equal((await put(DB, 'br_attempt', key('p', 'k', i), 'rebuild', att(i))).status, 200);
    let r = await get(DB, 'project=p&rkey=k');
    assert.equal(r.status, 200);
    assert.deepEqual(r.body.attempts.map((a) => JSON.parse(a.detail).reason), ['r1', 'r2', 'r3', 'r4', 'r5']);
    assert.equal(r.body.attempts[0].key, key('p', 'k', 1));
    assert.equal(r.body.attempts[0].status, 'rebuild');
    assert.ok(typeof r.body.as_of === 'string');
    r = await get(DB, 'project=p&rkey=k&limit=2');
    assert.deepEqual(r.body.attempts.map((a) => JSON.parse(a.detail).reason), ['r4', 'r5']);
    r = await get(DB, 'project=p&rkey=k&limit=-1');
    assert.equal(r.status, 200);
    assert.deepEqual(r.body.attempts.map((a) => JSON.parse(a.detail).reason), ['r5'], 'limit=-1 clamps to 1');
    r = await get(DB, 'project=p&rkey=k&limit=abc');
    assert.equal(r.body.attempts.length, 5, 'limit=abc is the default');
  });

  await t.test('W2 wrong tenant and wrong kind: 0 rows', async (t) => {
    const { DB } = await fresh(t);
    await put(DB, 'br_attempt', key('p', 'k', 1), 'rebuild', att(1));
    await put(DB, 'br_attempt', key('q', 'k', 2), 'rebuild', att(2));
    await put(DB, 'br_record', 'p/k', 'open', '{}');
    await put(DB, 'ironlaw-head-accept', key('p', 'k', 3), 'accepted', att(3));
    const r = await get(DB, 'project=p&rkey=k');
    assert.deepEqual(r.body.attempts.map((a) => a.key), [key('p', 'k', 1)]);
    const q = await get(DB, 'project=q&rkey=k');
    assert.deepEqual(q.body.attempts.map((a) => a.key), [key('q', 'k', 2)]);
    const none = await get(DB, 'project=z&rkey=k');
    assert.deepEqual(none.body.attempts, [], 'another project reads 0 rows');
  });

  await t.test('W3 prefix near miss, bad input, empty', async (t) => {
    const { DB } = await fresh(t);
    await put(DB, 'br_attempt', key('p', 'k-2', 1), 'rebuild', att(1));
    await put(DB, 'br_attempt', key('p', 'k2', 1), 'rebuild', att(1));
    await put(DB, 'br_attempt', key('p', 'kk', 1), 'rebuild', att(1));
    let r = await get(DB, 'project=p&rkey=k');
    assert.equal(r.status, 200);
    assert.deepEqual(r.body.attempts, [], 'rkey k never reads k-2, k2 or kk');
    for (const q of ['project=&rkey=k', 'rkey=k', 'project=p', 'project=p&rkey=a%2Fb', 'project=p&rkey=a%23b',
      `project=p&rkey=${'x'.repeat(201)}`, 'project=a%2Fb&rkey=k', 'project=p%24&rkey=k']) {
      r = await get(DB, q);
      assert.equal(r.status, 400, q);
      assert.ok(typeof r.body.error === 'string', q);
    }
    r = await get(DB, `project=p&rkey=${'x'.repeat(200)}`);
    assert.equal(r.status, 200, '200 chars is allowed');
  });

  await t.test('W4 bearer-gated, one statement', async (t) => {
    const { DB } = await fresh(t);
    await put(DB, 'br_attempt', key('p', 'k', 1), 'rebuild', att(1));
    assert.equal((await get(DB, 'project=p&rkey=k', null)).status, 401);
    assert.equal((await get(DB, 'project=p&rkey=k', 'tok-fixture-wrong')).status, 401);
    let n = 0;
    const counted = { prepare: (sql) => { n++; return DB.prepare(sql); }, batch: (s) => { n += s.length; return DB.batch(s); } };
    const r = await get(counted, 'project=p&rkey=k');
    assert.equal(r.status, 200);
    assert.equal(r.body.attempts.length, 1);
    assert.equal(n, 1, `one statement per GET (${n})`);
  });

  await t.test('R the family is registered and gated', () => {
    assert.ok(family.some(([m, p]) => m === 'GET' && p === '/api/br-attempts'));
    assert.ok(matchRoute(ROUTES, 'GET', '/api/br-attempts'), 'in the gated ROUTES table');
  });
});
