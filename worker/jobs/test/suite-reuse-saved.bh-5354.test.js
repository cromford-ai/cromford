import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { ROUTES, OPEN_ROUTES } from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-5354.3 (BH-5369): the suite ledger's READ routes, driven through
// worker.fetch over a real node:sqlite database. Rows are written through the
// contract's own PUT /api/suite-results/runs, so the read sees what the
// writer really stores.

const BEARER = { authorization: 'Bearer SECRET' };
const TOKEN = { 'x-suite-ledger-token': 'tok' };
const BH = 'example-org/cromford';
const TS = 'example-org/project-5';

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
  const run = async (run_key, { repo = BH, headers = BEARER, ran = 1, reused = 1, saved_s = 60 } = {}) => {
    const r = await call('PUT', '/api/suite-results/runs',
      { repo, run_key, ctx: 'isolated', ran, reused, total: ran + reused, saved_s }, headers);
    assert.equal(r.status, 200, JSON.stringify(r.body));
  };
  // Move a row to another time. The writer stamps the server clock; a test
  // that needs yesterday says so here, in one place.
  const at = (repo, run_key, iso) =>
    o.db.prepare('UPDATE suite_reuse_runs SET created_at = ? WHERE repo = ? AND run_key = ?').run(iso, repo, run_key);
  return { db: o.db, env, call, run, at };
}

// The worker stamps created_at with its own clock and /saved cuts its window
// from it, so the fixtures are relative to one anchor taken at load.
const ANCHOR = Date.now(); // determinism: ok the single anchor; the route stamps and windows on its own clock, rows sit relative to this
const today = () => new Date(ANCHOR).toISOString().slice(0, 10);
const yesterday = () => new Date(ANCHOR - 86400000).toISOString().slice(0, 10);

test('1 /saved groups by day, repo and class, newest day first, with summed counts', async (t) => {
  const s = await setup(t);
  if (!s) return;
  await s.run('123-1-0', { headers: TOKEN, ran: 3, reused: 5, saved_s: 120 });
  await s.run('124-1-0', { headers: TOKEN, ran: 1, reused: 2, saved_s: 30 });
  await s.run('example-BH-1-gate-1', { ran: 2, reused: 4, saved_s: 600 });
  await s.run('125-1-0', { headers: TOKEN, ran: 4, reused: 1, saved_s: 45 });
  s.at(BH, '125-1-0', `${yesterday()}T09:00:00Z`);
  const r = await s.call('GET', '/api/suite-results/saved?days=14');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.days, 14);
  assert.deepEqual(r.body.rows, [
    { day: today(), repo: BH, class: 'builder', runs: 1, ran: 2, reused: 4, saved_s: 600 },
    { day: today(), repo: BH, class: 'ci', runs: 2, ran: 4, reused: 7, saved_s: 150 },
    { day: yesterday(), repo: BH, class: 'ci', runs: 1, ran: 4, reused: 1, saved_s: 45 },
  ]);
});

test('2 /saved: repo filters; days clamps an integer to 1..60 and refuses anything else', async (t) => {
  const s = await setup(t);
  if (!s) return;
  await s.run('1-1-0', { headers: TOKEN, saved_s: 10 });
  await s.run('2-1-0', { headers: TOKEN, saved_s: 20, repo: TS });
  s.at(TS, '2-1-0', `${yesterday()}T09:00:00Z`);
  const ts = await s.call('GET', `/api/suite-results/saved?repo=${encodeURIComponent(TS)}`);
  assert.equal(ts.status, 200);
  assert.deepEqual(ts.body.rows.map((r) => r.repo), [TS]);
  assert.equal(ts.body.days, 14, 'absent days is the 14-day default');
  const zero = await s.call('GET', '/api/suite-results/saved?days=0');
  assert.equal(zero.body.days, 1);
  assert.deepEqual(zero.body.rows.map((r) => r.day), [today()], 'a 1-day window excludes yesterday');
  const big = await s.call('GET', '/api/suite-results/saved?days=999');
  assert.equal(big.body.days, 60);
  assert.equal(big.body.rows.length, 2);
  for (const v of ['abc', '1.5', '', '7days']) {
    const r = await s.call('GET', `/api/suite-results/saved?days=${encodeURIComponent(v)}`);
    assert.equal(r.status, 400, `days=${v}`);
  }
  assert.equal((await s.call('GET', '/api/suite-results/saved?repo=a%20b')).status, 400);
});

test('3 /runs: only that day, newest first; class and repo filter; bad day or class is a 400', async (t) => {
  const s = await setup(t);
  if (!s) return;
  await s.run('10-1-0', { headers: TOKEN });
  await s.run('11-1-0', { headers: TOKEN });
  await s.run('cromford-BH-2-gate-1');
  await s.run('12-1-0', { headers: TOKEN });
  const d = today();
  s.at(BH, '10-1-0', `${d}T01:00:00Z`);
  s.at(BH, '11-1-0', `${d}T03:00:00Z`);
  s.at(BH, 'cromford-BH-2-gate-1', `${d}T02:00:00Z`);
  s.at(BH, '12-1-0', `${yesterday()}T23:59:59Z`);
  const r = await s.call('GET', `/api/suite-results/runs?day=${d}`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.rows.map((x) => x.run_key), ['11-1-0', 'cromford-BH-2-gate-1', '10-1-0']);
  assert.equal(r.body.capped, false);
  const ci = await s.call('GET', `/api/suite-results/runs?day=${d}&class=ci&repo=${encodeURIComponent(BH)}`);
  assert.deepEqual(ci.body.rows.map((x) => x.run_key), ['11-1-0', '10-1-0']);
  const other = await s.call('GET', `/api/suite-results/runs?day=${d}&repo=${encodeURIComponent(TS)}`);
  assert.deepEqual(other.body.rows, []);
  for (const q of ['', 'day=2026-13-40', 'day=2026-02-30', 'day=20261008', `day=${d}&class=x`, `day=${d}&repo=a%20b`]) {
    const b = await s.call('GET', `/api/suite-results/runs?${q}`);
    assert.equal(b.status, 400, q);
  }
});

test('4 /runs: 201 rows on one day come back as 200 and capped', async (t) => {
  const s = await setup(t);
  if (!s) return;
  const d = today();
  const ins = s.db.prepare(`INSERT INTO suite_reuse_runs
    (repo, run_key, ctx, class, head_sha, ran, reused, total, saved_s, created_at, updated_at)
    VALUES (?, ?, 'isolated', 'ci', NULL, 1, 1, 2, 5, ?, ?)`);
  for (let i = 0; i < 201; i++) {
    const iso = `${d}T00:${String(Math.floor(i / 60)).padStart(2, '0')}:${String(i % 60).padStart(2, '0')}Z`;
    ins.run(BH, `${1000 + i}-1-0`, iso, iso);
  }
  const r = await s.call('GET', `/api/suite-results/runs?day=${d}`);
  assert.equal(r.status, 200);
  assert.equal(r.body.rows.length, 200);
  assert.equal(r.body.capped, true);
  assert.equal(r.body.rows[0].run_key, '1200-1-0', 'newest first');
});

test('5 url: a ci run key on an owner/name repo links its GitHub run; nothing else is guessed', async (t) => {
  const s = await setup(t);
  if (!s) return;
  await s.run('123-1-0', { headers: TOKEN });
  await s.run('nightly-456-2-0', { headers: TOKEN });
  await s.run('cromford-BH-5367-x-gate-plan-1728', {});
  await s.run('builder-hub-1728000000-42', {});
  await s.run('789-1-0', {});
  await s.run('321-1-0', { headers: TOKEN, repo: '../evil' });
  await s.run('322-1-0', { headers: TOKEN, repo: 'a/b/c' });
  await s.run('not-a-run', { headers: TOKEN });
  const r = await s.call('GET', `/api/suite-results/runs?day=${today()}`);
  const by = Object.fromEntries(r.body.rows.map((x) => [`${x.repo}|${x.run_key}`, x.url]));
  assert.equal(by[`${BH}|123-1-0`], `https://github.com/${BH}/actions/runs/123/attempts/1`);
  assert.equal(by[`${BH}|nightly-456-2-0`], `https://github.com/${BH}/actions/runs/456/attempts/2`);
  assert.equal(by[`${BH}|cromford-BH-5367-x-gate-plan-1728`], null);
  assert.equal(by[`${BH}|builder-hub-1728000000-42`], null);
  assert.equal(by[`${BH}|789-1-0`], null, 'a builder row never links, even with a CI-shaped key');
  assert.equal(by['../evil|321-1-0'], null);
  assert.equal(by['a/b/c|322-1-0'], null);
  assert.equal(by[`${BH}|not-a-run`], null);
});

test('6 reused_suites: null with no column; parsed when a column holds a JSON array; bad JSON is null', async (t) => {
  const s = await setup(t);
  if (!s) return;
  await s.run('1-1-0', { headers: TOKEN });
  let r = await s.call('GET', `/api/suite-results/runs?day=${today()}`);
  assert.equal(r.body.rows[0].reused_suites, null);
  s.db.exec('ALTER TABLE suite_reuse_runs ADD COLUMN reused_suites TEXT');
  await s.run('2-1-0', { headers: TOKEN });
  await s.run('3-1-0', { headers: TOKEN });
  await s.run('4-1-0', { headers: TOKEN });
  await s.run('5-1-0', { headers: TOKEN });
  const list = [{ suite: 'tests/a.sh', run_id: '99-1-0', duration_s: 40 }];
  s.db.prepare("UPDATE suite_reuse_runs SET reused_suites = ? WHERE run_key = '2-1-0'").run(JSON.stringify(list));
  s.db.prepare("UPDATE suite_reuse_runs SET reused_suites = '{not json' WHERE run_key = '3-1-0'").run();
  s.db.prepare("UPDATE suite_reuse_runs SET reused_suites = '{\"suite\":\"tests/a.sh\"}' WHERE run_key = '4-1-0'").run();
  s.db.prepare("UPDATE suite_reuse_runs SET reused_suites = '[1,2]' WHERE run_key = '5-1-0'").run();
  r = await s.call('GET', `/api/suite-results/runs?day=${today()}`);
  const by = Object.fromEntries(r.body.rows.map((x) => [x.run_key, x.reused_suites]));
  assert.deepEqual(by['2-1-0'], list);
  assert.equal(by['3-1-0'], null);
  assert.equal(by['4-1-0'], null, 'an object is not a list');
  assert.equal(by['5-1-0'], null, 'a list of non-objects is not a suite list');
  assert.equal(by['1-1-0'], null);
});

test('7 both reads are bearer only: the ledger token and no credential are 401', async (t) => {
  const s = await setup(t);
  if (!s) return;
  for (const p of ['/api/suite-results/saved?days=14', `/api/suite-results/runs?day=${today()}`]) {
    assert.equal((await s.call('GET', p, undefined, TOKEN)).status, 401, `token ${p}`);
    assert.equal((await s.call('GET', p, undefined, {})).status, 401, `none ${p}`);
    assert.equal((await s.call('GET', p)).status, 200, `bearer ${p}`);
  }
});

test('8 registered in ROUTES, not in OPEN_ROUTES', () => {
  const sig = (rows) => rows.map(([m, p]) => `${m} ${p}`);
  for (const r of ['GET /api/suite-results/saved', 'GET /api/suite-results/runs']) {
    assert.ok(sig(ROUTES).includes(r), `${r} in ROUTES`);
    assert.ok(!sig(OPEN_ROUTES).includes(r), `${r} not in OPEN_ROUTES`);
  }
});

test('9 an empty table answers rows: [], never a 404 or an error', async (t) => {
  const s = await setup(t);
  if (!s) return;
  const saved = await s.call('GET', '/api/suite-results/saved');
  assert.equal(saved.status, 200);
  assert.deepEqual(saved.body.rows, []);
  const runs = await s.call('GET', `/api/suite-results/runs?day=${today()}`);
  assert.deepEqual([runs.status, runs.body.rows, runs.body.capped], [200, [], false]);
});
