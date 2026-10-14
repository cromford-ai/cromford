import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-6460 (slice C3 of BH-6390): GET /api/suite-results/passes, the per-suite
// pass and fail counts bin/impact-learn-lane.sh reads to expire a learned
// impact edge. Driven through worker.fetch over a real node:sqlite database;
// rows are written through the contract's own PUT /api/suite-results, then
// first_at / updated_at are moved in one place.

const BEARER = { authorization: 'Bearer SECRET' };
const TOKEN = { 'x-suite-ledger-token': 'tok' };
const BH = 'example-org/cromford';
const TS = 'example-org/project-5';
const FA = 'a'.repeat(64);
const FB = 'b'.repeat(64);
const SINCE = '2026-10-11';

async function setup(t) {
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  const env = { DB: o.DB, HARNESS_SECRET: 'SECRET', SUITE_LEDGER_TOKEN: 'tok' };
  const call = async (method, path, body, headers = BEARER) => {
    const res = await worker.fetch(new Request('https://jobs.test' + path, {
      method, headers: { 'content-type': 'application/json', ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
    }), env);
    return { status: res.status, body: await res.json() };
  };
  // put <run_id> <items> [repo] [headers] — one PUT of results.
  const put = async (run_id, items, repo = BH, headers = BEARER) => {
    const r = await call('PUT', '/api/suite-results', { repo, ctx: 'isolated', run_id, items }, headers);
    assert.equal(r.status, 200, JSON.stringify(r.body));
  };
  // Move a row in time: the writer stamps the server clock.
  const at = (suite, first, updated, repo = BH) =>
    o.db.prepare('UPDATE suite_results SET first_at = ?, updated_at = ? WHERE repo = ? AND suite = ?')
      .run(first, updated, repo, suite);
  const passes = (q, headers = BEARER) => call('GET', `/api/suite-results/passes?${q}`, undefined, headers);
  return { call, put, at, passes };
}

const item = (suite, status, fingerprint = FA) => ({ suite, fingerprint, status, duration_s: 3 });
const q = (repo = BH, since = SINCE) => `repo=${encodeURIComponent(repo)}&since=${since}`; // determinism: ok since is a fixed day, not a window from now; the rows are moved to fixed stamps after the last PUT

test('P1 three ok runs and one fail → passes 3 for the ok suite, fails 1 for the other', async (t) => {
  const s = await setup(t);
  if (!s) return;
  await s.put('r1', [item('tests/a.sh', 'ok'), item('tests/b.sh', 'fail', FB)]);
  await s.put('r2', [item('tests/a.sh', 'ok')]);
  await s.put('r3', [item('tests/a.sh', 'ok')], BH, TOKEN);
  s.at('tests/a.sh', '2026-10-11T08:00:00Z', '2026-10-12T08:00:00Z');
  s.at('tests/b.sh', '2026-10-11T09:00:00Z', '2026-10-11T09:00:00Z');
  const r = await s.passes(q());
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.repo, BH);
  assert.equal(r.body.since, SINCE);
  const a = r.body.suites.filter((x) => x.suite === 'tests/a.sh');
  // Two classes (bearer builder, token ci) are two rows; both count.
  assert.equal(a.reduce((n, x) => n + x.passes, 0), 3);
  assert.deepEqual(r.body.suites.map((x) => x.suite), ['tests/a.sh', 'tests/b.sh']);
  const byName = Object.fromEntries(r.body.suites.map((x) => [x.suite, x]));
  assert.equal(byName['tests/a.sh'].passes, 3);
  assert.equal(byName['tests/a.sh'].fails, 0);
  assert.equal(byName['tests/b.sh'].passes, 0);
  assert.equal(byName['tests/b.sh'].fails, 1);
});

test('P2 a row that straddles since counts its fails, not its passes; a row wholly before is absent', async (t) => {
  const s = await setup(t);
  if (!s) return;
  await s.put('r1', [item('tests/a.sh', 'ok'), item('tests/c.sh', 'ok', FB), item('tests/old.sh', 'fail')]);
  await s.put('r2', [item('tests/a.sh', 'fail'), item('tests/c.sh', 'ok', FB)]);
  s.at('tests/a.sh', '2026-10-10T08:00:00Z', '2026-10-12T08:00:00Z');
  s.at('tests/c.sh', '2026-10-10T08:00:00Z', '2026-10-12T08:00:00Z');
  s.at('tests/old.sh', '2026-10-01T08:00:00Z', '2026-10-10T23:59:59Z');
  const r = await s.passes(q());
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const byName = Object.fromEntries(r.body.suites.map((x) => [x.suite, x]));
  assert.equal(byName['tests/a.sh'].fails, 1, 'the fail on a straddling row counts');
  assert.equal(byName['tests/a.sh'].passes, 0);
  assert.equal(byName['tests/c.sh'].passes, 0, 'ok runs first seen before since do not count');
  assert.equal(byName['tests/old.sh'], undefined, 'a row last written before since is absent');
});

test('P3 the CI ledger token cannot read the counts', async (t) => {
  const s = await setup(t);
  if (!s) return;
  const r = await s.passes(q(), TOKEN);
  assert.equal(r.status, 401);
});

test('P4 repo and since are required and refused when bad, never defaulted', async (t) => {
  const s = await setup(t);
  if (!s) return;
  for (const bad of [`since=${SINCE}`, `repo=${encodeURIComponent('a b')}&since=${SINCE}`, // determinism: ok fixed-day since, 400 cases
    `repo=${encodeURIComponent(BH)}`, q(BH, '2026-02-30'), q(BH, '2026-10-1'), q(BH, '')]) {
    const r = await s.passes(bad);
    assert.equal(r.status, 400, `${bad}: ${JSON.stringify(r.body)}`);
  }
});

test('P5 another repo\'s rows are not counted', async (t) => {
  const s = await setup(t);
  if (!s) return;
  await s.put('r1', [item('tests/a.sh', 'ok')], TS);
  await s.put('r2', [item('tests/a.sh', 'ok')], TS);
  s.at('tests/a.sh', '2026-10-11T08:00:00Z', '2026-10-12T08:00:00Z', TS);
  const r = await s.passes(q());
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.suites, []);
  const ts = await s.passes(q(TS));
  assert.equal(ts.body.suites.length, 1);
  assert.equal(ts.body.suites[0].passes, 2);
});
