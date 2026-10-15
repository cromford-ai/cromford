// BH-4156 (C2): the main-red lanes' state as rows. Driven through the REAL
// router (worker.fetch) against the composed schema on the node:sqlite shim,
// so the SQL that runs is the SQL that ships.
//   V  verdicts: upsert, the last tick wins; no row is a 200 with null.
//   E  pr-errors: write-once; the BH-5988 guarded rewrite of a '##[' row only;
//      the age prune; another repo's rows never answer.
//   P  pairs: append-only, one open row per (repo, hash); a resolve stamps
//      resolved_at and keeps the row.
//   B  400 on every bad input (never a clamp), 401 without the bearer.
//   F  a D1 error is a 500, never an empty 200.
//   R  the fragment registers the family, in the gated table.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker, { ROUTES, OPEN_ROUTES } from '../src/index.js';
import { matchRoute, matcherSignature } from '../src/lib/router.js';
import { routes as family } from '../src/routes/main-red-state.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'tok-fixture-bh4156';
const REPO = 'o/r';
const H1 = 'a'.repeat(40);
const H2 = 'b'.repeat(40);
const H3 = 'c'.repeat(40);

const call = (DB, method, path, body, auth = SECRET) => {
  const headers = { 'content-type': 'application/json' };
  if (auth !== null) headers.authorization = `Bearer ${auth}`;
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const q = (s) => encodeURIComponent(s);

async function fresh(t) {
  const h = await openDb();
  if (h === null) t.skip('node:sqlite unavailable in this runtime');
  return h;
}

test('BH-4156 main-red state routes', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  // The worker stamps rows with `new Date()`, so the whole Date is pinned: a
  // no-argument construction and Date.now() read this clock, nothing else.
  let clock = Date.parse('2026-10-14T12:00:00Z');
  const RealDate = Date;
  class FixtureDate extends RealDate {
    constructor(...a) { super(...(a.length ? a : [clock])); }
    static now() { return clock; }
  }
  globalThis.Date = FixtureDate;
  t.after(() => { globalThis.Date = RealDate; });

  await t.test('V1 verdict upsert: the last tick wins, one row per repo', async (t) => {
    const { db, DB } = await fresh(t);
    let r = await call(DB, 'PUT', '/api/main-red-state/verdict', { repo: REPO, decision: 'red', reason: 'tip', sha: 'f1f1f1f1' });
    assert.equal(r.status, 200);
    assert.equal(r.body.verdict.decision, 'red');
    clock += 60_000;
    r = await call(DB, 'PUT', '/api/main-red-state/verdict', { repo: REPO, decision: 'none', reason: 'no-runs', sha: '' });
    assert.equal(r.status, 200);
    r = await call(DB, 'GET', `/api/main-red-state/verdict?repo=${q(REPO)}`);
    assert.equal(r.status, 200);
    assert.equal(r.body.verdict.decision, 'none');
    assert.equal(r.body.verdict.reason, 'no-runs');
    assert.equal(r.body.verdict.sha, '');
    assert.equal(r.body.verdict.at, '2026-10-14T12:01:00Z');
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM main_red_verdicts').get().n, 1);
  });

  await t.test('V2 no verdict row is a 200 with verdict null, never a 404', async (t) => {
    const { DB } = await fresh(t);
    await call(DB, 'PUT', '/api/main-red-state/verdict', { repo: 'o/other', decision: 'green', reason: 'green', sha: 'a2a2' });
    const r = await call(DB, 'GET', `/api/main-red-state/verdict?repo=${q(REPO)}`);
    assert.equal(r.status, 200);
    assert.equal(r.body.verdict, null);
  });

  await t.test('E1 pr-errors are write-once: a second PUT changes nothing', async (t) => {
    const { DB } = await fresh(t);
    let r = await call(DB, 'PUT', '/api/main-red-state/pr-errors', { repo: REPO, head: H1, job: 'lint', error: 'FAIL: one', run_at: '2026-09-22T12:30:00Z' });
    assert.equal(r.status, 200);
    assert.equal(r.body.inserted, true);
    r = await call(DB, 'PUT', '/api/main-red-state/pr-errors', { repo: REPO, head: H1, job: 'lint', error: 'FAIL: two', run_at: '2026-09-22T12:31:00Z' });
    assert.equal(r.status, 200);
    assert.equal(r.body.inserted, false);
    assert.equal(r.body.replaced, false);
    r = await call(DB, 'GET', `/api/main-red-state/pr-errors?repo=${q(REPO)}&heads=${H1}`);
    assert.equal(r.body.rows.length, 1);
    assert.equal(r.body.rows[0].error, 'FAIL: one');
    assert.equal(r.body.rows[0].run_at, '2026-09-22T12:30:00Z');
  });

  await t.test('E2 the BH-5988 rewrite: only a stored error that starts with ##[ is replaced', async (t) => {
    const { db, DB } = await fresh(t);
    db.prepare("INSERT INTO main_red_pr_errors (repo, head, job, error, run_at, at) VALUES (?,?,?,?,?,?)")
      .run(REPO, H1, 'lint', '##[group]Run FAIL=0', '2026-09-22T12:30:00Z', '2026-09-22T12:40:00Z');
    let r = await call(DB, 'PUT', '/api/main-red-state/pr-errors', { repo: REPO, head: H1, job: 'lint', error: 'FAIL: real', run_at: '2026-09-22T12:30:00Z' });
    assert.equal(r.status, 200);
    assert.equal(r.body.inserted, false);
    assert.equal(r.body.replaced, true);
    r = await call(DB, 'PUT', '/api/main-red-state/pr-errors', { repo: REPO, head: H1, job: 'lint', error: 'FAIL: later', run_at: '2026-09-22T12:30:00Z' });
    assert.equal(r.body.replaced, false);
    const row = db.prepare('SELECT error FROM main_red_pr_errors WHERE repo=? AND head=?').get(REPO, H1);
    assert.equal(row.error, 'FAIL: real');
  });

  await t.test('E3 a pr-errors read answers only the asked heads of the asked repo', async (t) => {
    const { DB } = await fresh(t);
    await call(DB, 'PUT', '/api/main-red-state/pr-errors', { repo: REPO, head: H1, job: 'lint', error: 'e1', run_at: 't1' });
    await call(DB, 'PUT', '/api/main-red-state/pr-errors', { repo: REPO, head: H2, job: '-', error: '-', run_at: '-' });
    await call(DB, 'PUT', '/api/main-red-state/pr-errors', { repo: 'o/other', head: H3, job: 'lint', error: 'e3', run_at: 't3' });
    const r = await call(DB, 'GET', `/api/main-red-state/pr-errors?repo=${q(REPO)}&heads=${H1},${H2},${H3}`);
    assert.equal(r.status, 200);
    assert.deepEqual(r.body.rows.map((x) => x.head).sort(), [H1, H2]);
    assert.equal(r.body.rows.find((x) => x.head === H2).job, '-');
  });

  await t.test('E4 prune deletes the repo rows older than the days asked, and keeps the rest', async (t) => {
    const { db, DB } = await fresh(t);
    const ins = db.prepare("INSERT INTO main_red_pr_errors (repo, head, job, error, run_at, at) VALUES (?,?,?,?,?,?)");
    ins.run(REPO, H1, 'lint', 'old', 't', '2026-09-01T00:00:00Z');
    ins.run(REPO, H2, 'lint', 'new', 't', '2026-10-13T00:00:00Z');
    ins.run('o/other', H3, 'lint', 'old-other', 't', '2026-09-01T00:00:00Z');
    const r = await call(DB, 'POST', '/api/main-red-state/pr-errors/prune', { repo: REPO, days: 14 });
    assert.equal(r.status, 200);
    assert.equal(r.body.deleted, 1);
    const left = db.prepare('SELECT repo, head FROM main_red_pr_errors ORDER BY repo, head').all().map((x) => `${x.repo} ${x.head}`);
    assert.deepEqual(left, [`o/other ${H3}`, `${REPO} ${H2}`]);
  });

  await t.test('P1 one open pair per (repo, hash): a second open is refused, not duplicated', async (t) => {
    const { db, DB } = await fresh(t);
    const pair = { repo: REPO, hash: 'abc123def456', job: 'lint', first_error: 'FAIL: x', prs: '#1, #2' };
    let r = await call(DB, 'POST', '/api/main-red-state/pairs', pair);
    assert.equal(r.status, 200);
    assert.equal(r.body.opened, true);
    clock += 1000;
    r = await call(DB, 'POST', '/api/main-red-state/pairs', { ...pair, prs: '#1, #2, #3' });
    assert.equal(r.status, 200);
    assert.equal(r.body.opened, false);
    r = await call(DB, 'GET', `/api/main-red-state/pairs?repo=${q(REPO)}`);
    assert.equal(r.status, 200);
    assert.equal(r.body.pairs.length, 1);
    assert.equal(r.body.pairs[0].prs, '#1, #2');
    assert.equal(r.body.truncated, false);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM main_red_pairs').get().n, 1);
  });

  await t.test('P2 a resolve stamps resolved_at and keeps the row; a re-open appends a new row', async (t) => {
    const { db, DB } = await fresh(t);
    const pair = { repo: REPO, hash: 'abc123def456', job: 'lint', first_error: 'FAIL: x', prs: '#1, #2' };
    await call(DB, 'POST', '/api/main-red-state/pairs', pair);
    clock += 5000;
    let r = await call(DB, 'POST', '/api/main-red-state/pairs/resolve', { repo: REPO, hash: pair.hash });
    assert.equal(r.status, 200);
    assert.equal(r.body.resolved, 1);
    r = await call(DB, 'POST', '/api/main-red-state/pairs/resolve', { repo: REPO, hash: pair.hash });
    assert.equal(r.body.resolved, 0);
    r = await call(DB, 'GET', `/api/main-red-state/pairs?repo=${q(REPO)}`);
    assert.equal(r.body.pairs.length, 0);
    const kept = db.prepare('SELECT resolved_at FROM main_red_pairs WHERE repo=? AND hash=?').all(REPO, pair.hash);
    assert.equal(kept.length, 1);
    assert.ok(kept[0].resolved_at, 'the resolved row is kept with its stamp');
    clock += 5000;
    r = await call(DB, 'POST', '/api/main-red-state/pairs', pair);
    assert.equal(r.body.opened, true);
    const all = db.prepare('SELECT resolved_at FROM main_red_pairs WHERE repo=? AND hash=? ORDER BY opened_at').all(REPO, pair.hash);
    assert.equal(all.length, 2);
    assert.equal(all[1].resolved_at, null);
  });

  await t.test('B1 bad input is a 400, never a clamp or a silent default', async (t) => {
    const { db, DB } = await fresh(t);
    const bad = [
      ['GET', '/api/main-red-state/verdict', undefined],
      ['GET', '/api/main-red-state/verdict?repo=nope', undefined],
      ['PUT', '/api/main-red-state/verdict', { decision: 'red' }],
      ['PUT', '/api/main-red-state/verdict', { repo: REPO }],
      ['PUT', '/api/main-red-state/verdict', { repo: REPO, decision: 'RED!' }],
      ['PUT', '/api/main-red-state/verdict', { repo: REPO, decision: 'red', reason: 'x'.repeat(513) }],
      ['PUT', '/api/main-red-state/verdict', { repo: REPO, decision: 'red', reason: 'a\tb' }],
      ['PUT', '/api/main-red-state/verdict', { repo: REPO, decision: 'red', sha: 'not a sha' }],
      ['GET', `/api/main-red-state/pr-errors?repo=${q(REPO)}`, undefined],
      ['GET', `/api/main-red-state/pr-errors?repo=${q(REPO)}&heads=`, undefined],
      ['GET', `/api/main-red-state/pr-errors?repo=${q(REPO)}&heads=a%20b`, undefined],
      ['GET', `/api/main-red-state/pr-errors?repo=${q(REPO)}&heads=${Array.from({ length: 101 }, (_, i) => `h${i}`).join(',')}`, undefined],
      ['PUT', '/api/main-red-state/pr-errors', { repo: REPO, head: H1, job: '', error: 'e', run_at: 't' }],
      ['PUT', '/api/main-red-state/pr-errors', { repo: REPO, head: H1, job: 'j', error: '', run_at: 't' }],
      ['PUT', '/api/main-red-state/pr-errors', { repo: REPO, head: H1, job: 'j', error: 'e\nf', run_at: 't' }],
      ['PUT', '/api/main-red-state/pr-errors', { repo: REPO, head: '', job: 'j', error: 'e', run_at: 't' }],
      ['POST', '/api/main-red-state/pr-errors/prune', { repo: REPO }],
      ['POST', '/api/main-red-state/pr-errors/prune', { repo: REPO, days: 0 }],
      ['POST', '/api/main-red-state/pr-errors/prune', { repo: REPO, days: '1.5' }],
      ['POST', '/api/main-red-state/pr-errors/prune', { repo: REPO, days: -3 }],
      ['GET', '/api/main-red-state/pairs', undefined],
      ['POST', '/api/main-red-state/pairs', { repo: REPO, hash: 'h', job: '' }],
      ['POST', '/api/main-red-state/pairs', { repo: REPO, hash: 'bad hash', job: 'j' }],
      ['POST', '/api/main-red-state/pairs/resolve', { repo: REPO }],
    ];
    for (const [m, p, b] of bad) {
      const r = await call(DB, m, p, b);
      assert.equal(r.status, 400, `${m} ${p} ${JSON.stringify(b)} answered ${r.status}`);
    }
    for (const tbl of ['main_red_verdicts', 'main_red_pr_errors', 'main_red_pairs']) {
      assert.equal(db.prepare(`SELECT COUNT(*) AS n FROM ${tbl}`).get().n, 0, `${tbl} got a row from a refused request`);
    }
  });

  await t.test('B2 no bearer, no answer', async (t) => {
    const { DB } = await fresh(t);
    const r = await call(DB, 'GET', `/api/main-red-state/verdict?repo=${q(REPO)}`, undefined, null);
    assert.equal(r.status, 401);
  });

  await t.test('F1 a D1 error is a 500 with the error named, never an empty 200', async () => {
    const broken = {
      prepare() { throw new Error('D1_ERROR: fixture outage'); },
      batch() { throw new Error('D1_ERROR: fixture outage'); },
    };
    for (const [m, p, b] of [
      ['GET', `/api/main-red-state/verdict?repo=${q('o/f1')}`, undefined],
      ['GET', `/api/main-red-state/pr-errors?repo=${q('o/f1')}&heads=${H1}`, undefined],
      ['GET', `/api/main-red-state/pairs?repo=${q('o/f1')}`, undefined],
      ['PUT', '/api/main-red-state/verdict', { repo: 'o/f1', decision: 'none' }],
    ]) {
      const r = await call(broken, m, p, b);
      assert.equal(r.status, 500, `${m} ${p} answered ${r.status}`);
      assert.match(String(r.body && r.body.error), /main_red/);
    }
  });

  await t.test('R1 the fragment is the family, and the family is gated', () => {
    const frag = readFileSync(new URL('./route-table.d/774-main-red-state.txt', import.meta.url), 'utf8')
      .split('\n').filter((l) => l.trim() !== '' && !l.startsWith('#'));
    assert.deepEqual(family.map(([m, matcher]) => `${m} ${matcherSignature(matcher)}`), frag);
    for (const [m, matcher] of family) {
      const hit = matchRoute(ROUTES, m, matcher);
      assert.ok(hit, `${m} ${matcher} is not in ROUTES`);
      assert.equal(hit.handler, family.find(([fm, fp]) => fm === m && fp === matcher)[2], `${m} ${matcher} resolves to another family`);
      assert.equal(matchRoute(OPEN_ROUTES, m, matcher), null, `${m} ${matcher} is open`);
    }
  });
});
