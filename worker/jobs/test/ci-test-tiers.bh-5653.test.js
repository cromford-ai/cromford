// BH-5653 slice C1 (BH-5637.2): the test-tier sets in the jobs worker, read by
// bin/ci-test-tiers.sh fetch for bin/ci-plan.sh and written by
// bin/ci-test-tiers.sh put. Driven through the REAL router (worker.fetch)
// against a real schema.sql database on the node:sqlite shim. The shell side is
// tests/ci-test-tiers-*.bh-5653-test.sh.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const HARNESS = 'fixture-harness-secret';
const TOKEN = 'fixture-ci-token';
// The composition of worker/jobs/schema.d/ (BH-6005): schema.sql is a render.
const SCHEMA = jobsSchemaSql();
const PATH = '/api/ci/test-tiers';
const BLOB_A = 'a'.repeat(40);
const BLOB_B = 'b'.repeat(40);

const envOf = (DB, extra = {}) => ({ DB, HARNESS_SECRET: HARNESS, CI_DURATIONS_TOKEN: TOKEN, ...extra });

// `auth: null` sends no authorization header at all.
const call = (env, { method = 'GET', body, raw, auth = HARNESS } = {}) => {
  const headers = { 'content-type': 'application/json' };
  if (auth !== null) headers.authorization = `Bearer ${auth}`;
  const payload = raw !== undefined ? raw : body === undefined ? undefined : JSON.stringify(body);
  const req = new Request(`https://jobs.test${PATH}`, { method, headers, body: payload });
  return worker.fetch(req, env).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const put = (DB, body, opts = {}) => call(envOf(DB, opts.env), { method: 'PUT', body, ...opts });
const get = (DB, opts = {}) => call(envOf(DB, opts.env), { auth: TOKEN, ...opts });
const sets = (db) => Number(db.prepare('SELECT COUNT(*) AS n FROM ci_test_tier_sets').get().n);

const row = (suite, tier = 'nightly', extra = {}) => ({
  suite, tier, runtime_s: 12, paths: tier === 'guard' ? 'bin/x.sh catalog/' : '-', reason: `why ${suite}`, ...extra,
});
const ROWS_A = [row('tests/b-test.sh'), row('tests/a-test.sh', 'guard'), row('tests/mc/c-test.sh', 'batch')];
const ROWS_B = [row('tests/a-test.sh'), row('tests/d-test.sh')];
const body = (rows, extra = {}) => ({ base_blob: BLOB_A, source: 'seed', actor: 'box-1.fixture', rows, ...extra });
const bySuite = (rows) => [...rows].sort((x, y) => (x.suite < y.suite ? -1 : x.suite > y.suite ? 1 : 0));

async function fresh(t) {
  const h = await openDb();
  if (h === null) t.skip('node:sqlite unavailable in this runtime');
  return h;
}

test('BH-5653 C1 ci test-tier sets route', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('W0 schema.sql creates ci_test_tier_sets, and applies twice', () => {
    assert.match(SCHEMA, /CREATE TABLE IF NOT EXISTS ci_test_tier_sets \(/);
    const cols = probe.db.prepare('PRAGMA table_info(ci_test_tier_sets)').all().map((c) => c.name);
    assert.deepEqual(cols, ['id', 'base_blob', 'digest', 'rows_json', 'row_count', 'source', 'actor', 'created_at']);
    probe.db.exec(SCHEMA);
    assert.throws(() => probe.db.prepare(
      "INSERT INTO ci_test_tier_sets (base_blob, digest, rows_json, row_count, source, actor, created_at) VALUES ('b','d','[]',0,'ci','a','t')").run(),
    /CHECK/, 'source is seed or operator only');
  });

  await t.test('W1 GET on an empty table is 200 {set:null}', async (tt) => {
    const { DB } = await fresh(tt);
    const g = await get(DB);
    assert.equal(g.status, 200, JSON.stringify(g.body));
    assert.equal(g.body.set, null);
    const h = await get(DB, { auth: HARNESS });
    assert.equal(h.status, 200, 'HARNESS_SECRET can read too');
    assert.equal(h.body.set, null);
  });

  await t.test('W2 PUT needs HARNESS_SECRET: the CI token, no bearer and an empty bearer are 401', async (tt) => {
    const { db, DB } = await fresh(tt);
    const ci = await put(DB, body(ROWS_A), { auth: TOKEN });
    assert.equal(ci.status, 401, JSON.stringify(ci.body));
    assert.equal((await put(DB, body(ROWS_A), { auth: null })).status, 401);
    assert.equal((await put(DB, body(ROWS_A), { auth: 'wrong' })).status, 401);
    assert.equal(sets(db), 0);
    // A worker with both secrets empty refuses every bearer, the empty one too.
    const bare = { env: { HARNESS_SECRET: '', CI_DURATIONS_TOKEN: '' } };
    assert.equal((await put(DB, body(ROWS_A), { ...bare, auth: '' })).status, 401);
    assert.equal((await get(DB, { ...bare, auth: '' })).status, 401);
    assert.equal((await get(DB, { auth: null })).status, 401);
    assert.equal((await get(DB, { auth: 'wrong' })).status, 401);
    assert.equal(sets(db), 0);
  });

  await t.test('W3 PUT valid is 201 {id}; GET returns the rows sorted by suite, the blob and the source', async (tt) => {
    const { db, DB } = await fresh(tt);
    const p = await put(DB, body(ROWS_A));
    assert.equal(p.status, 201, JSON.stringify(p.body));
    assert.equal(typeof p.body.id, 'number');
    const g = await get(DB);
    assert.equal(g.status, 200, JSON.stringify(g.body));
    const s = g.body.set;
    assert.equal(s.id, p.body.id);
    assert.equal(s.base_blob, BLOB_A);
    assert.equal(s.source, 'seed');
    assert.equal(s.actor, 'box-1.fixture');
    assert.match(s.digest, /^[0-9a-f]{64}$/);
    assert.match(s.created_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    assert.deepEqual(s.rows, bySuite(ROWS_A));
    assert.equal(db.prepare('SELECT row_count FROM ci_test_tier_sets').get().row_count, 3);
    const op = await put(DB, body(ROWS_B, { source: 'operator' }));
    assert.equal(op.status, 201, JSON.stringify(op.body));
    assert.equal((await get(DB)).body.set.source, 'operator');
  });

  await t.test('W4 the same PUT again is 200 duplicate, still one set', async (tt) => {
    const { db, DB } = await fresh(tt);
    const first = await put(DB, body(ROWS_A));
    assert.equal(first.status, 201);
    // Row order in the body does not change the digest.
    const again = await put(DB, body([...ROWS_A].reverse()));
    assert.equal(again.status, 200, JSON.stringify(again.body));
    assert.equal(again.body.duplicate, true);
    assert.equal(again.body.id, first.body.id);
    assert.equal(sets(db), 1);
    // The same rows on another base are another set.
    const other = await put(DB, body(ROWS_A, { base_blob: BLOB_B }));
    assert.equal(other.status, 201, JSON.stringify(other.body));
    assert.equal(sets(db), 2);
  });

  await t.test('W5 A, B, A stores three sets, and GET answers A with the newest id', async (tt) => {
    const { db, DB } = await fresh(tt);
    const a1 = await put(DB, body(ROWS_A));
    const b = await put(DB, body(ROWS_B));
    const a2 = await put(DB, body(ROWS_A));
    assert.deepEqual([a1.status, b.status, a2.status], [201, 201, 201], JSON.stringify(a2.body));
    assert.ok(a2.body.id > b.body.id && b.body.id > a1.body.id);
    assert.equal(sets(db), 3);
    const s = (await get(DB)).body.set;
    assert.equal(s.id, a2.body.id);
    assert.deepEqual(s.rows, bySuite(ROWS_A));
  });

  await t.test('W6 every bad body is 400 and writes nothing', async (tt) => {
    const { db, DB } = await fresh(tt);
    const good = row('tests/ok-test.sh');
    const many = (n) => Array.from({ length: n }, (_, i) => row(`tests/n${i}-test.sh`));
    const bad = {
      'bad suite path': body([good, row('bin/x.sh')]),
      'not a .sh suite': body([row('tests/x-test.py')]),
      'a .. in the suite': body([row('tests/../x-test.sh')]),
      'tier skip': body([good, row('tests/s-test.sh', 'skip')]),
      'guard with paths -': body([row('tests/g-test.sh', 'guard', { paths: '-' })]),
      'guard with empty paths': body([row('tests/g-test.sh', 'guard', { paths: '' })]),
      'nightly with paths': body([row('tests/n-test.sh', 'nightly', { paths: 'bin/' })]),
      'runtime -1': body([row('tests/r-test.sh', 'nightly', { runtime_s: -1 })]),
      'runtime 1.5': body([row('tests/r-test.sh', 'nightly', { runtime_s: 1.5 })]),
      'runtime "12"': body([row('tests/r-test.sh', 'nightly', { runtime_s: '12' })]),
      'runtime over a day': body([row('tests/r-test.sh', 'nightly', { runtime_s: 86401 })]),
      'tab in reason': body([row('tests/r-test.sh', 'nightly', { reason: 'a\tb' })]),
      'newline in paths': body([row('tests/r-test.sh', 'guard', { paths: 'bin/\ncatalog/' })]),
      'empty reason': body([row('tests/r-test.sh', 'nightly', { reason: '' })]),
      'duplicate suite': body([good, good]),
      '0 rows': body([]),
      '2001 rows': body(many(2001)),
      'bad blob': body([good], { base_blob: 'abc' }),
      'upper-case blob': body([good], { base_blob: 'A'.repeat(40) }),
      'source ci': body([good], { source: 'ci' }),
      'actor with a space': body([good], { actor: 'a b' }),
      'actor too long': body([good], { actor: 'x'.repeat(65) }),
      'rows not a list': body('nope'),
      'body a list': [good],
    };
    for (const [name, b] of Object.entries(bad)) {
      const p = await put(DB, b);
      assert.equal(p.status, 400, `${name}: ${JSON.stringify(p.body)}`);
      assert.equal(typeof p.body.error, 'string', name);
    }
    const nj = await call(envOf(DB), { method: 'PUT', raw: '{not json' });
    assert.equal(nj.status, 400, 'malformed JSON');
    // One bad row among 100 good ones stores nothing.
    const hundred = many(100);
    hundred.splice(50, 0, row('tests/bad-test.sh', 'skip'));
    assert.equal((await put(DB, body(hundred))).status, 400);
    assert.equal(sets(db), 0);
    // The edges are accepted: 2000 rows, runtime 0 and 86400.
    const edge = many(2000);
    edge[0].runtime_s = 0; edge[1].runtime_s = 86400;
    const ok = await put(DB, body(edge));
    assert.equal(ok.status, 201, JSON.stringify(ok.body));
    assert.equal(sets(db), 1);
  });

  await t.test('W7 the table not applied answers 503 "ci_test_tier_sets schema not applied"', async (tt) => {
    const { db, DB } = await fresh(tt);
    db.exec('DROP TABLE ci_test_tier_sets');
    const g = await get(DB);
    assert.equal(g.status, 503, JSON.stringify(g.body));
    assert.equal(g.body.error, 'ci_test_tier_sets schema not applied');
    const p = await put(DB, body(ROWS_A));
    assert.equal(p.status, 503, JSON.stringify(p.body));
    assert.equal(p.body.error, 'ci_test_tier_sets schema not applied');
  });

  await t.test('W8 no other verb reaches the route', async (tt) => {
    const { db, DB } = await fresh(tt);
    for (const method of ['POST', 'DELETE', 'PATCH']) {
      const r = await call(envOf(DB), { method, body: body(ROWS_A) });
      assert.notEqual(r.status, 201, method);
      assert.notEqual(r.status, 200, method);
    }
    assert.equal(sets(db), 0);
  });
});
