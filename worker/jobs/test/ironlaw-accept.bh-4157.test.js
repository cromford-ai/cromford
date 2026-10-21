// BH-4157 (slice C0): the head-bound iron-law ACCEPT as a ledger row, written
// from the console. Driven through the REAL router (worker.fetch) against the
// composed schema on the node:sqlite shim, so the SQL that runs is the SQL
// that ships. The conductor's hold row is seeded through PUT /api/ledger in
// the exact shape bin/lib/mc/classify.sh mc_merge_verdict_put writes:
// kind mc-merge-verdict, key <slug>#<n>, detail "<head> <reason>".
//   P1  400 on every bad input (never a clamp), 401 without the bearer
//   P2-P5, P10  409 unless the conductor holds THIS head on iron-law hits
//   P6  a refused POST writes no row
//   P7  200 created:true; GET shows the hold and the accept; the stored key is
//       the shared fixture's key (tests/fixtures/bh-4157/head-accept.json),
//       the key bin/lib/ironlaw-carry.sh ila_key builds for the same input
//   P8  a second POST for the head is created:false and the first actor stands
//   P9  another repo with the same PR number reads 0 rows
//   R   the fragment registers the family, in the gated table
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker, { ROUTES, OPEN_ROUTES } from '../src/index.js';
import { matchRoute } from '../src/lib/router.js';
import { routes as family } from '../src/routes/ironlaw-accept.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const FIX = JSON.parse(readFileSync(new URL('../../../tests/fixtures/bh-4157/head-accept.json', import.meta.url), 'utf8'));
const SECRET = 'tok-fixture-bh4157';
const REPO = FIX.repo;
const PR = FIX.pr;
const HEAD = FIX.head;
const OLD = 'a'.repeat(40);

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
const hold = (DB, status, detail, repo = REPO, pr = PR) =>
  call(DB, 'PUT', '/api/ledger', { kind: 'mc-merge-verdict', key: `${repo}#${pr}`, status, detail, actor: 'box-fixture' });
const IRON = `${HEAD} iron-law: 2 hit(s) on this head: src/ui.js (window.confirm();src/ui.js (window.confirm()`;
const post = (DB, over = {}) => call(DB, 'POST', '/api/ironlaw-accept',
  { repo: REPO, pr: PR, head: HEAD, reason: 'read the lines, fixture', actor: 'ops@x', ...over });
const acceptRows = (db) => db.prepare("SELECT key, status, actor, detail FROM ledgers WHERE kind='ironlaw-head-accept'").all();

async function fresh(t) {
  const h = await openDb();
  if (h === null) t.skip('node:sqlite unavailable in this runtime');
  return h;
}

test('BH-4157 ironlaw-accept routes', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }

  await t.test('P1 400 on every bad input, 401 without the bearer', async (t) => {
    const { db, DB } = await fresh(t);
    await hold(DB, 'hold', IRON);
    const bad = [
      ['repo', { repo: 'no-slash' }],
      ['repo', { repo: 'o/r/x' }],
      ['pr', { pr: 0 }],
      ['pr', { pr: '3' }],
      ['pr', { pr: 1.5 }],
      ['head', { head: HEAD.slice(0, 39) }],
      ['head', { head: HEAD.toUpperCase() }],
      ['reason', { reason: '' }],
      ['reason', { reason: '   ' }],
      ['reason', { reason: 'x'.repeat(501) }],
      ['actor', { actor: undefined }],
      ['actor', { actor: '' }],
    ];
    for (const [field, over] of bad) {
      const r = await post(DB, over);
      assert.equal(r.status, 400, `${JSON.stringify(over)} → 400`);
      assert.match(r.body.error, new RegExp(field), `the error names ${field}: ${r.body.error}`);
    }
    assert.equal((await post(DB)).status, 200, 'the valid body is accepted (control)');
    const r = await call(DB, 'POST', '/api/ironlaw-accept', { repo: REPO, pr: PR, head: HEAD, reason: 'r', actor: 'a' }, null);
    assert.equal(r.status, 401);
    assert.equal((await call(DB, 'GET', `/api/ironlaw-accept?repo=${q(REPO)}&pr=${PR}`, undefined, null)).status, 401);
    assert.equal((await call(DB, 'GET', `/api/ironlaw-accept?repo=bad&pr=${PR}`)).status, 400);
    assert.equal((await call(DB, 'GET', `/api/ironlaw-accept?repo=${q(REPO)}&pr=x`)).status, 400);
    assert.equal((await call(DB, 'GET', `/api/ironlaw-accept?repo=${q(REPO)}`)).status, 400);
    assert.equal(acceptRows(db).length, 1, 'only the control wrote a row');
  });

  await t.test('P2 409 when the conductor has no verdict row for the PR', async (t) => {
    const { db, DB } = await fresh(t);
    const r = await post(DB);
    assert.equal(r.status, 409);
    assert.equal(r.body.error, `no iron-law hold on record for ${REPO}#${PR}`);
    assert.equal(acceptRows(db).length, 0);
  });

  await t.test('P3 409 when the verdict is clear', async (t) => {
    const { db, DB } = await fresh(t);
    await hold(DB, 'clear', `${HEAD} iron-law scan clean`);
    const r = await post(DB);
    assert.equal(r.status, 409);
    assert.match(r.body.error, /no iron-law hold on record/);
    assert.equal(acceptRows(db).length, 0);
  });

  await t.test('P3b the status decides, not the reason text: a non-hold row with a hits reason is refused', async (t) => {
    const { db, DB } = await fresh(t);
    await hold(DB, 'clear', IRON);
    const r = await post(DB);
    assert.equal(r.status, 409);
    const g = await call(DB, 'GET', `/api/ironlaw-accept?repo=${q(REPO)}&pr=${PR}`);
    assert.equal(g.body.iron_law, false);
    assert.equal(acceptRows(db).length, 0);
  });

  await t.test('P4 409 when the hold is diff-unread, not iron-law hits', async (t) => {
    const { db, DB } = await fresh(t);
    await hold(DB, 'hold', `${HEAD} diff-unread: the diff read was UNVERIFIABLE (HTTP 502), iron-law scan NOT run`);
    const r = await post(DB);
    assert.equal(r.status, 409);
    assert.match(r.body.error, /no iron-law hold on record/);
    const g = await call(DB, 'GET', `/api/ironlaw-accept?repo=${q(REPO)}&pr=${PR}`);
    assert.equal(g.body.iron_law, false);
    assert.equal(g.body.hold.status, 'hold');
    assert.equal(acceptRows(db).length, 0);
  });

  await t.test('P5 409 when the hold is on another head', async (t) => {
    const { db, DB } = await fresh(t);
    await hold(DB, 'hold', IRON.replace(HEAD, OLD));
    const r = await post(DB);
    assert.equal(r.status, 409);
    assert.equal(r.body.error, `the hold is on ${OLD.slice(0, 8)}, not ${HEAD.slice(0, 8)}`);
    assert.equal(acceptRows(db).length, 0);
  });

  await t.test('P6 a hold with an iron-law reason but no head prefix is not a hold on this head', async (t) => {
    const { db, DB } = await fresh(t);
    await hold(DB, 'hold', 'iron-law: 2 hit(s) on this head: src/ui.js (window.confirm()');
    const r = await post(DB);
    assert.equal(r.status, 409);
    assert.equal(acceptRows(db).length, 0, 'a refused POST writes no row');
  });

  await t.test('P10 a partial scan stays held after an ACCEPT, so it is refused', async (t) => {
    const { db, DB } = await fresh(t);
    // The conductor's DIFF_WHY: no text in the local diff. DIFF_UNREAD=1 holds
    // the head whatever an ACCEPT says (bin/merge-conductor.sh), so the console
    // must not offer one.
    await hold(DB, 'hold', `${HEAD} iron-law: 1 file(s) not scanned (no text in the local diff)`);
    let r = await post(DB);
    assert.equal(r.status, 409);
    await hold(DB, 'hold', `${IRON}; iron-law: 1 file(s) not scanned (no text in the local diff)`);
    r = await post(DB);
    assert.equal(r.status, 409);
    const g = await call(DB, 'GET', `/api/ironlaw-accept?repo=${q(REPO)}&pr=${PR}`);
    assert.equal(g.body.iron_law, false);
    assert.equal(acceptRows(db).length, 0);
  });

  await t.test('P7 200 created; GET reads the hold and the accept; the key is the shared fixture key', async (t) => {
    const { db, DB } = await fresh(t);
    await hold(DB, 'hold', IRON);
    let g = await call(DB, 'GET', `/api/ironlaw-accept?repo=${q(REPO)}&pr=${PR}`);
    assert.equal(g.status, 200);
    assert.equal(g.body.iron_law, true);
    assert.equal(g.body.hold.head, HEAD);
    assert.equal(g.body.hold.status, 'hold');
    assert.match(g.body.hold.reason, /^iron-law: 2 hit\(s\)/);
    assert.deepEqual(g.body.accepts, []);
    const r = await post(DB);
    assert.equal(r.status, 200);
    assert.equal(r.body.created, true);
    assert.equal(r.body.accept.head, HEAD);
    assert.equal(r.body.accept.actor, 'ops@x');
    const rows = acceptRows(db);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].key, FIX.key, 'the worker key is the key ila_key builds');
    assert.equal(rows[0].status, 'accepted');
    const d = JSON.parse(rows[0].detail);
    assert.equal(d.sha, HEAD);
    assert.equal(d.source, 'console');
    assert.equal(d.actor, 'ops@x');
    assert.equal(d.reason, 'read the lines, fixture');
    g = await call(DB, 'GET', `/api/ironlaw-accept?repo=${q(REPO)}&pr=${PR}`);
    assert.equal(g.body.accepts.length, 1);
    assert.equal(g.body.accepts[0].head, HEAD);
    assert.equal(g.body.accepts[0].actor, 'ops@x');
    assert.equal(g.body.accepts[0].source, 'console');
    assert.equal(g.body.accepts[0].reason, 'read the lines, fixture');
    assert.ok(g.body.accepts[0].created_at);
  });

  await t.test('P8 a second POST for the head is created:false and the first actor stands', async (t) => {
    const { db, DB } = await fresh(t);
    await hold(DB, 'hold', IRON);
    assert.equal((await post(DB)).body.created, true);
    const r = await post(DB, { actor: 'other@x', reason: 'again' });
    assert.equal(r.status, 200);
    assert.equal(r.body.created, false);
    assert.equal(r.body.accept.actor, 'ops@x');
    assert.equal(acceptRows(db).length, 1);
    assert.equal(JSON.parse(acceptRows(db)[0].detail).reason, 'read the lines, fixture');
  });

  await t.test('P9 another repo with the same PR number reads 0 rows; PR 1 does not read PR 10', async (t) => {
    const { DB } = await fresh(t);
    await hold(DB, 'hold', IRON);
    assert.equal((await post(DB)).status, 200);
    let g = await call(DB, 'GET', `/api/ironlaw-accept?repo=${q('example-org/other-os')}&pr=${PR}`);
    assert.equal(g.status, 200);
    assert.equal(g.body.hold, null);
    assert.equal(g.body.iron_law, false);
    assert.deepEqual(g.body.accepts, []);
    await hold(DB, 'hold', IRON, REPO, 1);
    assert.equal((await post(DB, { pr: 1 })).status, 200);
    g = await call(DB, 'GET', `/api/ironlaw-accept?repo=${q(REPO)}&pr=1`);
    assert.equal(g.body.accepts.length, 1, 'PR 1 reads its own row only, not PR 11');
  });

  await t.test('R the fragment registers the family in the gated table', () => {
    const frag = readFileSync(new URL('./route-table.d/bh-4157-ironlaw-accept.txt', import.meta.url), 'utf8');
    assert.equal(family.length, 2);
    for (const [m, p, handler] of family) {
      assert.ok(frag.includes(`${m} ${p}`), `${m} ${p} in the fragment`);
      const hit = matchRoute(ROUTES, m, p);
      assert.ok(hit && hit.handler === handler, `${m} ${p} reaches this family's handler first`);
      assert.equal(matchRoute(OPEN_ROUTES, m, p), null, `${m} ${p} is not an open route`);
    }
  });
});
