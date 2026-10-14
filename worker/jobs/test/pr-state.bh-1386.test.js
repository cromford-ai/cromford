import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { d1, openDb } from './lib/d1-sqlite.bh-1030.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1386 (BH-1025.1) — the six PR-state / PR-attempt routes.
//
// EVERY CASE DRIVES `worker.fetch` (D2): the routes are reached through the
// real bearer check, the real body parse and the real route table, over the
// real schema.sql in node:sqlite. A stubbed D1 would pass a handler whose SQL
// never ran — and the whole point of this family is the two dedupe indexes and
// the `pr_state` view, which are SQL and nothing else.
//
// THE FAMILY SHIPS DARK. Nothing calls these routes until the `pr-state-rows`
// flag is up, so this file is the only consumer they have today; it therefore
// asserts the wire shapes `bin/lib/jobs/jobs.sh` will read when the flag flips
// (`.rows`, `.count`, 404 on a missing attempt), not the shapes that would be
// convenient here.
//
// `t.skip` when node:sqlite is absent (the settings-schema.test.js rule): a
// silent pass would hide exactly the checks that make this file worth running.

const SCHEMA = jobsSchemaSql();
const MARK = '-- ── BH-1025.0';
const SECRET = 'test-secret';
const REPO = 'example-org/x';

async function call(DB, path, { method = 'GET', body, auth = true } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const res = await worker.fetch(req, { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null) };
}

const ev = (over = {}) => ({ repo: REPO, number: 12, state: 'BLOCKED', since: '2026-09-22T10:00:00Z', ...over });
const att = (over = {}) => ({ repo: REPO, number: 12, kind: 'rebase', sha: 'abc', ...over });
const count = (db, table) => db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n;

// A database in the state a box is in when `wrangler deploy` beat
// `bin/harness-sync.sh`'s schema apply: schema.sql sliced before the BH-1025.0
// marker, so neither table and no view exists. Only `ensureTable` at the top of
// each handler can make these routes answer (BH-1000's outage is why).
async function openPreDb() {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    return null;
  }
  const at = SCHEMA.indexOf(MARK);
  assert.notEqual(at, -1, `worker/jobs/schema.sql must carry the "${MARK}" block marker`);
  const before = SCHEMA.slice(0, at);
  assert.equal(before.includes('pr_state_events'), false,
    'the BH-1025.0 objects must all live under the marker, or this case proves nothing');
  const db = new DatabaseSync(':memory:');
  db.exec(before);
  return { db, DB: d1(db) };
}

// ── 1. events dedupe ────────────────────────────────────────────────────────
test('POST /api/pr-state-events twice is 201 then 200 duplicate, and one row', async (t) => {
  const open = await openDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, DB } = open;

  const first = await call(DB, '/api/pr-state-events', { method: 'POST', body: ev() });
  assert.equal(first.status, 201);
  assert.equal(first.body.recorded, true);
  assert.equal(first.body.duplicate, false);
  assert.equal(first.body.event.state, 'BLOCKED');

  const again = await call(DB, '/api/pr-state-events', { method: 'POST', body: ev() });
  assert.equal(again.status, 200);
  assert.equal(again.body.recorded, false);
  assert.equal(again.body.duplicate, true);

  assert.equal(count(db, 'pr_state_events'), 1, 'the dedupe index must have refused the repeat');
  // `alerted` omitted -> '-', never NULL: a NULL never collides in a SQLite
  // UNIQUE index, so a NULL here would let the same sighting insert forever.
  assert.equal(db.prepare('SELECT alerted FROM pr_state_events').get().alerted, '-');
  db.close();
});

test('alerted:"" is stored as "-" too, so the client default is not load-bearing', async (t) => {
  const open = await openDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, DB } = open;
  const res = await call(DB, '/api/pr-state-events', { method: 'POST', body: ev({ alerted: '' }) });
  assert.equal(res.status, 201);
  assert.equal(db.prepare('SELECT alerted FROM pr_state_events').get().alerted, '-');
  const dup = await call(DB, '/api/pr-state-events', { method: 'POST', body: ev({ alerted: '-' }) });
  assert.equal(dup.status, 200, 'alerted:"" and alerted:"-" are the same sighting');
  assert.equal(count(db, 'pr_state_events'), 1);
  db.close();
});

// ── 2. the alerted sighting is a SECOND row ─────────────────────────────────
test('the same sighting with a new alerted value is a new row, and the view shows it', async (t) => {
  const open = await openDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, DB } = open;

  assert.equal((await call(DB, '/api/pr-state-events', { method: 'POST', body: ev() })).status, 201);
  assert.equal((await call(DB, '/api/pr-state-events', { method: 'POST', body: ev({ alerted: '1' }) })).status, 201);
  assert.equal(count(db, 'pr_state_events'), 2);

  const view = await call(DB, `/api/pr-state?repo=${encodeURIComponent(REPO)}`);
  assert.equal(view.status, 200);
  assert.equal(view.body.rows.length, 1, 'the view is one row per PR');
  assert.equal(view.body.rows[0].alerted, '1', 'the view must answer the LATEST event');
  db.close();
});

// ── 3. the view is the latest event per PR, and `before` pages it ───────────
test('GET /api/pr-state answers the latest event per PR, newest first, and pages on before', async (t) => {
  const open = await openDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, DB } = open;

  for (const body of [
    ev({ state: 'BLOCKED', since: 'S1' }),
    ev({ state: 'REVIEWED', since: 'S2' }),
    ev({ state: 'MERGED', since: 'S3', alerted: '2' }),
  ]) assert.equal((await call(DB, '/api/pr-state-events', { method: 'POST', body })).status, 201);

  let view = await call(DB, '/api/pr-state');
  assert.equal(view.status, 200);
  assert.equal(view.body.rows.length, 1);
  assert.equal(view.body.rows[0].state, 'MERGED');
  assert.equal(view.body.rows[0].alerted, '2');

  assert.equal((await call(DB, '/api/pr-state-events', {
    method: 'POST', body: ev({ number: 34, state: 'QUEUED', since: 'S4' }),
  })).status, 201);

  view = await call(DB, '/api/pr-state');
  assert.equal(view.body.rows.length, 2);
  assert.deepEqual(view.body.rows.map((r) => r.number), [34, 12], 'rows come back id DESC');
  assert.ok(view.body.as_of, 'as_of rides on the answer');

  const cursor = view.body.rows[0].id;
  const page2 = await call(DB, `/api/pr-state?before=${cursor}`);
  assert.equal(page2.status, 200);
  assert.deepEqual(page2.body.rows.map((r) => r.number), [12]);

  const scoped = await call(DB, `/api/pr-state?repo=${encodeURIComponent(REPO)}&limit=1`);
  assert.equal(scoped.body.rows.length, 1, 'limit is honoured');
  db.close();
});

// ── 4. an empty page is a 404, and a junk cursor is a 400 ───────────────────
test('GET /api/pr-state 404s "no rows" on an empty page and 400s a non-integer before', async (t) => {
  const open = await openDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, DB } = open;

  const empty = await call(DB, '/api/pr-state');
  assert.equal(empty.status, 404);
  assert.deepEqual(empty.body, { error: 'no rows' });

  const junk = await call(DB, '/api/pr-state?before=abc');
  assert.equal(junk.status, 400, 'before is an id cursor; a non-integer is a 400, never a 0');
  assert.match(junk.body.error, /before/);

  assert.equal((await call(DB, '/api/pr-state-events', { method: 'POST', body: ev() })).status, 201);
  // before=0 is a real integer cursor: id < 0 matches nothing, which is 404.
  assert.equal((await call(DB, '/api/pr-state?before=0')).status, 404);
  db.close();
});

// ── 5. the event log, filtered ──────────────────────────────────────────────
test('GET /api/pr-state-events answers rows (not events), newest first, filtered', async (t) => {
  const open = await openDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, DB } = open;

  for (let i = 1; i <= 5; i++) {
    const body = ev({ number: i <= 3 ? 12 : 34, state: i === 5 ? 'MERGED' : 'BLOCKED', since: `S${i}` });
    assert.equal((await call(DB, '/api/pr-state-events', { method: 'POST', body })).status, 201);
  }
  // Every POST in this test shares one second of wall clock, so the `at` values
  // are stamped here instead — the `since` filter is a comparison on the `at`
  // COLUMN and a test where every row has the same `at` cannot see it work.
  const ids = db.prepare('SELECT id FROM pr_state_events ORDER BY id').all().map((r) => r.id);
  ids.forEach((id, i) => db.prepare('UPDATE pr_state_events SET at=? WHERE id=?')
    .run(`2026-09-22T1${i}:00:00Z`, id));

  const all = await call(DB, '/api/pr-state-events');
  assert.equal(all.status, 200);
  assert.ok(Array.isArray(all.body.rows), 'the client reads `.rows` (jobs.sh:525) — not `.events`');
  assert.equal(all.body.events, undefined);
  assert.equal(all.body.rows.length, 5);
  assert.deepEqual(all.body.rows.map((r) => r.id), [...ids].reverse(), 'ORDER BY id DESC');

  const blocked = await call(DB, '/api/pr-state-events?state=BLOCKED&limit=2');
  assert.equal(blocked.body.rows.length, 2, 'limit is honoured');
  assert.deepEqual(blocked.body.rows.map((r) => r.state), ['BLOCKED', 'BLOCKED']);

  const since = await call(DB, '/api/pr-state-events?since=2026-09-22T12:00:00Z');
  assert.deepEqual(since.body.rows.map((r) => r.at), [
    '2026-09-22T14:00:00Z', '2026-09-22T13:00:00Z', '2026-09-22T12:00:00Z',
  ], 'since filters the `at` column, inclusive');

  const byPr = await call(DB, `/api/pr-state-events?repo=${encodeURIComponent(REPO)}&number=34`);
  assert.equal(byPr.body.rows.length, 2);
  assert.deepEqual([...new Set(byPr.body.rows.map((r) => r.number))], [34]);

  const other = await call(DB, '/api/pr-state-events?repo=example-org/nope');
  assert.equal(other.status, 200, 'an empty log is a 200 with rows:[] — the client maps that to its own rc 2');
  assert.deepEqual(other.body.rows, []);

  assert.equal((await call(DB, '/api/pr-state-events?number=abc')).status, 400);
  db.close();
});

// ── 5b. the limit parameter, on both list routes ────────────────────────────
// `limit` is BOUND into the statement, never interpolated, and a limit that was
// SENT and is not an integer is its own 400 (D11) — `?limit=1.5` reached the
// statement as 1.5 and threw ERR_SQLITE_ERROR `datatype mismatch` out of the
// handler, which nothing catches, so the caller read a 500 and could not tell
// its own bad request from an outage.
test('limit is an integer or a 400, and never unbounded, on both list routes', async (t) => {
  const open = await openDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, DB } = open;

  for (const body of [
    ev({ number: 12, since: '2026-09-22T10:00:00Z' }),
    ev({ number: 34, since: '2026-09-22T10:05:00Z' }),
    ev({ number: 56, since: '2026-09-22T10:10:00Z' }),
  ]) assert.equal((await call(DB, '/api/pr-state-events', { method: 'POST', body })).status, 201);
  const rowsOf = (res) => (res.body && res.body.rows) || [];

  for (const path of ['/api/pr-state-events', '/api/pr-state']) {
    for (const bad of ['abc', '1.5', '12abc', 'Infinity']) {
      const res = await call(DB, `${path}?limit=${encodeURIComponent(bad)}`);
      assert.equal(res.status, 400, `${path}?limit=${bad} must be a 400, never a 500`);
      assert.deepEqual(res.body, { error: 'limit must be an integer' });
    }

    const two = await call(DB, `${path}?limit=2`);
    assert.equal(two.status, 200);
    assert.equal(rowsOf(two).length, 2, `${path} must honour limit=2`);

    // Math.max(1, …): SQLite reads LIMIT -1 and LIMIT 0 differently and one of
    // them is "the whole table" — neither may come back as more than one row.
    for (const edge of ['0', '-1']) {
      const res = await call(DB, `${path}?limit=${encodeURIComponent(edge)}`);
      assert.equal(res.status, 200);
      assert.equal(rowsOf(res).length, 1, `${path}?limit=${edge} clamps to one row, never the table`);
    }

    // Over the ceiling is a clamp to 1000, not a refusal; empty is absent.
    const big = await call(DB, `${path}?limit=5000`);
    assert.equal(big.status, 200);
    assert.equal(rowsOf(big).length, 3);
    const blank = await call(DB, `${path}?limit=`);
    assert.equal(blank.status, 200, `${path}?limit= is absent, and absent is the 200 default`);
    assert.equal(rowsOf(blank).length, 3);
  }
  db.close();
});

// ── 6. attempts dedupe ──────────────────────────────────────────────────────
test('PUT /api/pr-attempts twice is 201 then 200 duplicate, and one row', async (t) => {
  const open = await openDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, DB } = open;

  const first = await call(DB, '/api/pr-attempts', { method: 'PUT', body: att({ actor: 'hub' }) });
  assert.equal(first.status, 201);
  assert.equal(first.body.recorded, true);
  assert.equal(first.body.attempt.sha, 'abc');

  const again = await call(DB, '/api/pr-attempts', { method: 'PUT', body: att({ actor: 'other-box' }) });
  assert.equal(again.status, 200);
  assert.equal(again.body.recorded, false);
  assert.equal(again.body.duplicate, true);

  assert.equal(count(db, 'pr_attempts'), 1, 'the primary key must have refused the repeat');
  assert.equal(db.prepare('SELECT actor FROM pr_attempts').get().actor, 'hub',
    'a duplicate must not overwrite the first attempt');
  db.close();
});

// ── 7. the attempt lookup that mc_attempt_has reads ─────────────────────────
test('GET /api/pr-attempts with a sha answers the row, or 404 — and needs kind', async (t) => {
  const open = await openDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, DB } = open;

  await call(DB, '/api/pr-attempts', { method: 'PUT', body: att() });

  const hit = await call(DB, `/api/pr-attempts?repo=${encodeURIComponent(REPO)}&number=12&kind=rebase&sha=abc`);
  assert.equal(hit.status, 200);
  assert.equal(hit.body.attempt.sha, 'abc');
  assert.equal(hit.body.attempt.kind, 'rebase');

  const miss = await call(DB, `/api/pr-attempts?repo=${encodeURIComponent(REPO)}&number=12&kind=rebase&sha=zzz`);
  assert.equal(miss.status, 404, 'a real miss is a 404 — the client reads rc 2, never "unusable"');
  assert.deepEqual(miss.body, { error: 'not found' });

  // The primary key is (repo, number, kind, sha): a lookup without `kind` could
  // match two rows, and picking one of them is D17's exact failure.
  const noKind = await call(DB, `/api/pr-attempts?repo=${encodeURIComponent(REPO)}&number=12&sha=abc`);
  assert.equal(noKind.status, 400);
  db.close();
});

// ── 8. the measured count ───────────────────────────────────────────────────
test('GET /api/pr-attempts without a sha answers a measured count and the rows', async (t) => {
  const open = await openDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, DB } = open;

  await call(DB, '/api/pr-attempts', { method: 'PUT', body: att({ sha: 'abc' }) });
  await call(DB, '/api/pr-attempts', { method: 'PUT', body: att({ sha: 'def' }) });
  await call(DB, '/api/pr-attempts', { method: 'PUT', body: att({ sha: 'ghi', kind: 'review' }) });

  const rebases = await call(DB, `/api/pr-attempts?repo=${encodeURIComponent(REPO)}&number=12&kind=rebase`);
  assert.equal(rebases.status, 200);
  assert.equal(rebases.body.count, 2);
  assert.equal(rebases.body.attempts.length, 2);

  const all = await call(DB, `/api/pr-attempts?repo=${encodeURIComponent(REPO)}&number=12`);
  assert.equal(all.body.count, 3, 'kind is an optional filter, not a required one, without a sha');

  const none = await call(DB, `/api/pr-attempts?repo=${encodeURIComponent(REPO)}&number=12&kind=other`);
  assert.equal(none.status, 200, 'a measured zero is a 200, not a 404');
  assert.equal(none.body.count, 0);
  assert.deepEqual(none.body.attempts, []);
  db.close();
});

// ── 9. the forget (pr-rows-contract.md:83-88) ───────────────────────────────
test('DELETE /api/pr-attempts removes exactly one row, then 404s', async (t) => {
  const open = await openDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, DB } = open;

  await call(DB, '/api/pr-attempts', { method: 'PUT', body: att({ sha: 'abc' }) });
  await call(DB, '/api/pr-attempts', { method: 'PUT', body: att({ sha: 'def' }) });

  const q = `repo=${encodeURIComponent(REPO)}&number=12&kind=rebase&sha=abc`;
  const gone = await call(DB, `/api/pr-attempts?${q}`, { method: 'DELETE' });
  assert.equal(gone.status, 200);
  assert.equal(gone.body.deleted, true);
  assert.equal(count(db, 'pr_attempts'), 1, 'exactly the named row goes');

  assert.equal((await call(DB, `/api/pr-attempts?${q}`)).status, 404,
    'once deleted, mc_attempt_has must read a real miss');
  const twice = await call(DB, `/api/pr-attempts?${q}`, { method: 'DELETE' });
  assert.equal(twice.status, 404, 'a second forget is "there was none", not an error');
  assert.deepEqual(twice.body, { error: 'not found' });

  // Three of four keys is a 400, never a wider DELETE.
  const partial = await call(DB, `/api/pr-attempts?repo=${encodeURIComponent(REPO)}&number=12&kind=rebase`,
    { method: 'DELETE' });
  assert.equal(partial.status, 400);
  assert.equal(count(db, 'pr_attempts'), 1, 'the surviving attempt must survive');
  db.close();
});

// ── 10. the validation negatives ────────────────────────────────────────────
test('missing fields and non-integer numbers are 400s, never a wrong row', async (t) => {
  const open = await openDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, DB } = open;

  const post = (body) => call(DB, '/api/pr-state-events', { method: 'POST', body });
  const noSince = await post({ repo: REPO, number: 12, state: 'BLOCKED' });
  assert.equal(noSince.status, 400);
  assert.match(noSince.body.error, /required/);
  assert.equal((await post(ev({ number: undefined }))).status, 400);

  for (const bad of ['abc', 1.5, true]) {
    const res = await post(ev({ number: bad }));
    assert.equal(res.status, 400, `number=${JSON.stringify(bad)} must be refused`);
    assert.match(res.body.error, /integer/, `number=${JSON.stringify(bad)} must say why`);
  }

  const put = (body) => call(DB, '/api/pr-attempts', { method: 'PUT', body });
  assert.equal((await put(att({ sha: undefined }))).status, 400);
  assert.equal((await put(att({ kind: undefined }))).status, 400);
  assert.equal((await put(att({ number: '1.5' }))).status, 400);

  assert.equal((await call(DB, `/api/pr-attempts?repo=${encodeURIComponent(REPO)}`)).status, 400,
    'a lookup without a number is a 400, never every attempt on the repo');
  assert.equal((await call(DB, '/api/pr-attempts?number=12')).status, 400);

  assert.equal(count(db, 'pr_state_events'), 0, 'not one refused request wrote a row');
  assert.equal(count(db, 'pr_attempts'), 0);
  db.close();
});

// ── 11. the bearer ──────────────────────────────────────────────────────────
test('every one of the six routes is 401 without a bearer', async (t) => {
  const open = await openDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, DB } = open;

  const calls = [
    ['POST', '/api/pr-state-events', ev()],
    ['GET', '/api/pr-state-events'],
    ['GET', '/api/pr-state'],
    ['PUT', '/api/pr-attempts', att()],
    ['GET', `/api/pr-attempts?repo=${encodeURIComponent(REPO)}&number=12&kind=rebase&sha=abc`],
    ['DELETE', `/api/pr-attempts?repo=${encodeURIComponent(REPO)}&number=12&kind=rebase&sha=abc`],
  ];
  for (const [method, path, body] of calls) {
    const res = await call(DB, path, { method, body, auth: false });
    assert.equal(res.status, 401, `${method} ${path} must be 401 without a bearer`);
    assert.deepEqual(res.body, { error: 'unauthorized' });
  }
  assert.equal(count(db, 'pr_state_events'), 0, 'a refused write must not have landed');
  assert.equal(count(db, 'pr_attempts'), 0);

  // ...and the same calls WITH the bearer reach a handler. Without this half
  // the loop above is vacuous: an UNREGISTERED route is 401 too, because the
  // bearer check runs before the route table.
  for (const [method, path, body] of calls) {
    const authed = await call(DB, path, { method, body });
    assert.notEqual(authed.status, 401, `${method} ${path} must pass the bearer`);
    assert.notDeepEqual(authed.body, { error: 'unknown endpoint' },
      `${method} ${path} is not registered in ROUTES`);
  }
  assert.equal(count(db, 'pr_state_events'), 1, 'the authed POST did land');
  assert.equal(count(db, 'pr_attempts'), 0, 'the authed PUT landed and the authed DELETE took it back');
  db.close();
});

// ── 12. the belt: a deploy that outran the schema apply ─────────────────────
test('every route answers on a database the BH-1025.0 schema block never reached', async (t) => {
  const open = await openPreDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, DB } = open;

  const post = await call(DB, '/api/pr-state-events', { method: 'POST', body: ev() });
  assert.equal(post.status, 201, `ensureTable must build pr_state_events first: ${JSON.stringify(post.body)}`);

  const view = await call(DB, '/api/pr-state');
  assert.equal(view.status, 200, `the pr_state view must exist too: ${JSON.stringify(view.body)}`);
  assert.equal(view.body.rows.length, 1);

  const events = await call(DB, '/api/pr-state-events');
  assert.equal(events.status, 200);
  assert.equal(events.body.rows.length, 1);

  const put = await call(DB, '/api/pr-attempts', { method: 'PUT', body: att() });
  assert.equal(put.status, 201, `ensureTable must build pr_attempts first: ${JSON.stringify(put.body)}`);

  const q = `repo=${encodeURIComponent(REPO)}&number=12&kind=rebase&sha=abc`;
  assert.equal((await call(DB, `/api/pr-attempts?${q}`)).status, 200);
  assert.equal((await call(DB, `/api/pr-attempts?${q}`, { method: 'DELETE' })).status, 200);

  // Not a `no such table` anywhere: that 500 is what BH-1000 spent 29 minutes on.
  db.close();
});

// A fresh database that never saw a pr_attempts SELECT still answers the read
// side — the belt is on the GET handlers too, not only the writers.
test('the read routes build their tables as well', async (t) => {
  const open = await openPreDb();
  if (!open) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, DB } = open;

  assert.equal((await call(DB, '/api/pr-state')).status, 404, 'an empty view is 404 "no rows", not a 500');
  assert.equal((await call(DB, '/api/pr-state-events')).status, 200);
  const lookup = await call(DB, `/api/pr-attempts?repo=${encodeURIComponent(REPO)}&number=12&kind=rebase&sha=abc`);
  assert.equal(lookup.status, 404, 'a miss on an unbuilt table is still a real miss');
  db.close();
});
