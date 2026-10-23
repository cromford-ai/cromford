// BH-8066: GET /api/metrics/gh-ledger and the gh shim's cache rows.
//
// The gh PATH shim answers a repeat GET from disk (bin/lib/gh-cache.sh) and
// ledgers it with status `cache`, counted 0. That row is not a request, so the
// reads that count calls leave it out, and group=served counts how each REST
// call was answered (cache | 304 | 200 | -).
//
// Driven through the REAL worker.fetch on a node:sqlite D1 with the composed
// schema (bearer, router, table and SQL all under test):
//   S1  group=served sums calls per served value; GraphQL rows are not in it
//   S2  cache rows are in no lane-hour / lane-class / repo row and not in
//       totals.rest_calls; totals.graphql_calls does not move when they are added
//   S3  the ungrouped per-box read leaves cache rows out
//   S4  150,000 rows: the served read and its totals read use idx_gh_ledger_hour
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { capturingD1, plan, fullScans } from './lib/d1-volume.bh-6727.js';

const SECRET = 'fixture-secret';
const H = '2026-10-22T10';

const call = (DB, path) => worker.fetch(
  new Request(`https://jobs.test${path}`, { headers: { authorization: `Bearer ${SECRET}` } }),
  { DB, HARNESS_SECRET: SECRET },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

const INS = `INSERT INTO gh_ledger (box, hour, lane, project, meter, resource, method, path_class,
               status, source, calls, counted, updated_at)
             VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`;
const put = (db, r) => db.prepare(INS).run(
  r.box || 'hub', r.hour || H, r.lane || 'lane-a', '-', 'app-1',
  r.resource || 'core', r.method || 'GET', r.path_class || 'repos/Org/app/pulls/N',
  r.status, r.source || 'gh', r.calls, r.counted, '2026-10-22T12:00:00Z');

// The rows a box pushes after its shim served 30 hits, 10 revalidations, 60
// full answers (5 of them 404), 2 network failures, and 7 GraphQL calls.
const seed = (db, { withCache = true } = {}) => {
  if (withCache) put(db, { status: 'cache', calls: 30, counted: 0 });
  put(db, { status: '304', calls: 10, counted: 0 });
  put(db, { status: '200', calls: 55, counted: 55, lane: 'lane-b', path_class: 'repos/Org/app/issues/N' });
  put(db, { status: '404', calls: 5, counted: 5 });
  put(db, { status: '000', calls: 2, counted: 0 });
  put(db, { status: '200', calls: 7, counted: 7, resource: 'graphql', method: 'POST', path_class: 'graphql' });
};

test('BH-8066 gh_ledger served group and cache rows', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('S1 group=served sums calls per served value', async () => {
    const { db, DB } = await openDb();
    seed(db);
    const r = await call(DB, `/api/metrics/gh-ledger?since=2026-10-22T10&group=served`);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.group, 'served');
    const by = Object.fromEntries(r.body.rows.map((x) => [x.served, x.calls]));
    assert.equal(by.cache, 30);
    assert.equal(by['304'], 10);
    assert.equal(by['200'], 60, '200 and 404 are both full answers');
    assert.equal(by['-'], 2);
    assert.equal(Object.values(by).reduce((a, b) => a + b, 0), 102, 'GraphQL rows are not in group=served');
  });

  await t.test('S2 cache rows are not calls in any spending group or the totals', async () => {
    const { db, DB } = await openDb();
    seed(db);
    const { db: db0, DB: DB0 } = await openDb();
    seed(db0, { withCache: false });
    for (const g of ['lane-hour', 'lane-class', 'repo']) {
      const a = await call(DB, `/api/metrics/gh-ledger?since=2026-10-22T10&group=${g}`);
      const b = await call(DB0, `/api/metrics/gh-ledger?since=2026-10-22T10&group=${g}`);
      assert.equal(a.status, 200, g);
      assert.deepEqual(a.body.rows, b.body.rows, `${g}: the rows are those of the same ledger with no cache row`);
      assert.equal(a.body.totals.rest_calls, 72, `${g}: rest_calls = 10 + 55 + 5 + 2`);
      assert.equal(a.body.totals.rest_counted, 60, g);
      assert.equal(a.body.totals.graphql_calls, b.body.totals.graphql_calls, `${g}: graphql_calls does not move`);
      assert.equal(a.body.totals.graphql_calls, 7, g);
    }
    const lc = await call(DB, `/api/metrics/gh-ledger?since=2026-10-22T10&group=lane-class`);
    const pulls = lc.body.rows.find((x) => x.lane === 'lane-a' && x.path_class === 'repos/Org/app/pulls/N');
    assert.equal(pulls.calls, 17, 'lane-a pulls/N = 304 + 404 + 000, no cache row');
  });

  await t.test('S3 the ungrouped read leaves cache rows out', async () => {
    const { db, DB } = await openDb();
    seed(db);
    const r = await call(DB, `/api/metrics/gh-ledger?since=2026-10-22T10`);
    assert.equal(r.status, 200);
    const total = r.body.rows.reduce((a, x) => a + x.calls, 0);
    assert.equal(total, 79, '72 REST requests + 7 GraphQL, no cache row');
  });

  await t.test('S3b group=bogus still names served among the groups', async () => {
    const { DB } = await openDb();
    const r = await call(DB, `/api/metrics/gh-ledger?since=2026-10-22T10&group=bogus`);
    assert.equal(r.status, 400);
    assert.match(r.body.error, /served/);
  });

  await t.test('S4 150,000 rows: the served read uses idx_gh_ledger_hour', async () => {
    const { db } = await openDb();
    const N = 150000;
    const base = Date.parse('2026-10-22T12:00:00Z');
    const statuses = ['200', '304', 'cache', '404', '000'];
    const stmt = db.prepare(INS);
    db.exec('BEGIN');
    for (let i = 0; i < N; i++) {
      const hour = new Date(base - Math.floor((i / N) * 14 * 24) * 3600e3).toISOString().slice(0, 13);
      stmt.run(`box-${i % 9}`, hour, `lane-${i % 98}`, `p${i % 13}`, 'app-1',
        i % 7 === 0 ? 'graphql' : 'core', 'GET', i % 7 === 0 ? 'graphql' : `repos/Org/app${i % 11}/pulls/N`,
        statuses[i % 5], 'gh', 1 + (i % 3), 1, '2026-10-22T12:00:00Z');
    }
    db.exec('COMMIT');
    const log = [];
    const DB = capturingD1(db, log);
    const r = await call(DB, `/api/metrics/gh-ledger?since=2026-10-21T12&group=served`);
    assert.equal(r.status, 200);
    const reads = log.filter((x) => /FROM gh_ledger/.test(x.sql));
    assert.equal(reads.length, 2, 'the served read and its totals read');
    for (const { sql, binds } of reads) {
      const lines = plan(db, sql, ...binds);
      assert.ok(lines.some((l) => /USING (COVERING )?INDEX idx_gh_ledger_hour/.test(l)),
        `${sql}\n${lines.join('\n')}`);
      assert.deepEqual(fullScans(lines, ['gh_ledger']), [], sql);
    }
  });
});
