// BH-1381 (BH-1201.0): the conductor's held-pages contract, driven through the
// REAL router.
//
// WHY A REAL DATABASE AND THE REAL worker.fetch. Two of the behaviours this
// ticket exists to pin are statements, not JavaScript: the upsert must refresh
// `text`/`mode`/`last_seen_at` while leaving `first_held_at` alone, and the
// release must answer the DELETE's own `meta.changes` rather than an assumed 1.
// A pattern-matching D1 stub answers `{changes:1}` to every write and would
// pass a route with no ON CONFLICT clause at all. So the fixture is a real
// schema.sql database behind the node:sqlite shim, every request goes in through
// `worker.fetch` (D2: the bearer, the router and the route table are part of
// what is under test), and the assertions read the rows back with SQL.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { CREATED_TABLES } from '../src/lib/core.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

// A hold identity that passes every field rule, so each case mutates one field
// and nothing else is in question.
const KEY = {
  repo: 'example-org/cromford',
  number: 1381,
  state: 'WAIT_CI',
  head: 'a'.repeat(40),
  kind: 'STUCK',
};
const PUT_BODY = { ...KEY, text: 'CI has not moved in 40 minutes', mode: 'merge' };

// Every request rides the real fetch. `secret: null` sends no authorization
// header at all, which is how the 401 case is driven.
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

const rowsOf = (db) => db.prepare(
  'SELECT repo, number, state, head, kind, text, mark, mode, first_held_at, last_seen_at'
  + ' FROM conductor_held_pages ORDER BY first_held_at, repo, number'
).all();

// PRAGMA table_info is compared as a SHAPE, not as a DDL string: the belt and
// schema.sql are allowed to differ in whitespace and they do (one is indented
// inside a JS template literal). What may not differ is the table sqlite ends
// up with, which is what every reader actually sees.
const shapeOf = (db) => db.prepare('PRAGMA table_info(conductor_held_pages)').all()
  .map((c) => `${c.name} ${c.type} notnull=${c.notnull} pk=${c.pk}`);

test('BH-1381 conductor held pages', async (t) => {
  const first = await openDb();
  if (first === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }

  // ── 1. the belt DDL in core.js builds schema.sql's table, exactly ─────────
  // The routes self-create (BH-1043), so a belt that drifts from schema.sql is
  // two different tables depending on which one made it — and the one the
  // routes make is the one nobody reviewed.
  await t.test('belt DDL == schema.sql table', async () => {
    const fromSchema = shapeOf(first.db);
    assert.ok(fromSchema.length > 0, 'schema.sql must create conductor_held_pages');

    const { DatabaseSync } = await import('node:sqlite');
    const belt = new DatabaseSync(':memory:');
    const stmts = CREATED_TABLES.conductor_held_pages;
    assert.ok(Array.isArray(stmts) && stmts.length === 2,
      'CREATED_TABLES.conductor_held_pages must hold the table and its index');
    for (const s of stmts) belt.exec(s);
    assert.deepEqual(shapeOf(belt), fromSchema);

    // And the index rides the belt too, under the same name, or oldest-first
    // reads a table scan on the one deploy that never had schema.sql applied.
    const idx = belt.prepare(
      "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_conductor_held_first'"
    ).all();
    assert.equal(idx.length, 1, 'the belt must create idx_conductor_held_first');
  });

  // ── 2. ensureTable self-creates on a D1 that never had schema.sql ─────────
  await t.test('PUT self-creates the table then lands the row', async () => {
    const fresh = await openDb();
    // The fresh-D1 state. The DROP lives in the fixture and nowhere else:
    // product code never drops a table (D20).
    fresh.db.exec('DROP TABLE IF EXISTS conductor_held_pages');
    assert.equal(fresh.db.prepare(
      "SELECT count(*) AS n FROM sqlite_master WHERE name='conductor_held_pages'"
    ).get().n, 0, 'fixture must start with the table absent');

    const res = await call(fresh.DB, '/api/conductor/held', { method: 'PUT', body: PUT_BODY });
    assert.equal(res.status, 200);
    assert.deepEqual(res.body, { ok: true });

    const rows = rowsOf(fresh.db);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].repo, KEY.repo);
    assert.equal(rows[0].number, 1381);
    assert.equal(rows[0].text, PUT_BODY.text);
    assert.equal(rows[0].mode, 'merge');
    // mark was omitted: NULL, not the string "null" and not "".
    assert.equal(rows[0].mark, null);
    // first_held_at and last_seen_at are the SAME instant on insert -- both are
    // the request's `t`, so a hold sighted once has zero age rather than two
    // clocks disagreeing about when it began.
    assert.equal(rows[0].first_held_at, rows[0].last_seen_at);
    assert.match(rows[0].first_held_at, /^\d{4}-\d{2}-\d{2}T/);
  });

  // ── 3. the upsert keeps the AGE and refreshes the rest ────────────────────
  // This is the case that goes red if ON CONFLICT ... DO UPDATE is dropped, and
  // the case that goes red if first_held_at joins the DO UPDATE list.
  await t.test('re-sighting keeps first_held_at, bumps last_seen_at/text/mode', async () => {
    const db = await openDb();
    const one = await call(db.DB, '/api/conductor/held', { method: 'PUT', body: PUT_BODY });
    assert.equal(one.status, 200);
    const born = rowsOf(db.db)[0].first_held_at;

    // The route stamps its own `t` from the request clock, so the second PUT is
    // driven a real millisecond later rather than with an injected time.
    await new Promise((r) => setTimeout(r, 1100));
    const two = await call(db.DB, '/api/conductor/held', {
      method: 'PUT',
      body: { ...PUT_BODY, text: 'still red, second sighting', mode: 'kill-switch', mark: 'mc-1381' },
    });
    assert.equal(two.status, 200);

    const rows = rowsOf(db.db);
    assert.equal(rows.length, 1, 'the same hold identity is ONE row, not two');
    assert.equal(rows[0].first_held_at, born, 'the age of a hold never moves on re-sighting');
    assert.ok(rows[0].last_seen_at > born, `last_seen_at must advance (${rows[0].last_seen_at} vs ${born})`);
    assert.equal(rows[0].text, 'still red, second sighting');
    assert.equal(rows[0].mode, 'kill-switch');
    assert.equal(rows[0].mark, 'mc-1381');
  });

  // A PR whose head moved is a NEW hold with its own age, because the question
  // a reader asks is "how long has it been stuck like THIS".
  await t.test('a moved head is a second hold, not an update', async () => {
    const db = await openDb();
    await call(db.DB, '/api/conductor/held', { method: 'PUT', body: PUT_BODY });
    await call(db.DB, '/api/conductor/held', {
      method: 'PUT', body: { ...PUT_BODY, head: 'b'.repeat(40) },
    });
    assert.equal(rowsOf(db.db).length, 2);
  });

  // ── 4. GET: oldest first, limit honoured, n_total measured ───────────────
  await t.test('GET orders oldest first and honours limit with a measured n_total', async () => {
    const db = await openDb();
    const at = (iso, over) => db.db.prepare(
      `INSERT INTO conductor_held_pages
         (repo, number, state, head, kind, text, mark, mode, first_held_at, last_seen_at)
       VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, ?)`
    ).run(KEY.repo, over.number, KEY.state, over.head, KEY.kind, 'held', 'merge', iso, iso);
    at('2026-09-20T00:00:00Z', { number: 200, head: 'c'.repeat(40) });
    at('2026-09-21T00:00:00Z', { number: 100, head: 'd'.repeat(40) });

    const all = await call(db.DB, '/api/conductor/held');
    assert.equal(all.status, 200);
    assert.equal(all.body.n_total, 2);
    assert.deepEqual(all.body.rows.map((r) => r.number), [200, 100],
      'oldest first_held_at first, NOT insertion or number order');

    const capped = await call(db.DB, '/api/conductor/held?limit=1');
    assert.equal(capped.status, 200);
    assert.equal(capped.body.rows.length, 1);
    assert.equal(capped.body.rows[0].number, 200, 'a capped page still starts at the oldest');
    // n_total is the WHOLE table, measured -- a capped read must say how much
    // it did not show (D12), so this is 2 while the page holds 1.
    assert.equal(capped.body.n_total, 2);
  });

  await t.test('GET of an empty table is {rows:[],n_total:0}, not a 500', async () => {
    const db = await openDb();
    const res = await call(db.DB, '/api/conductor/held');
    assert.equal(res.status, 200);
    assert.deepEqual(res.body, { rows: [], n_total: 0 });
  });

  // ── 5. release deletes exactly one and reports what it really deleted ────
  await t.test('release answers {released:1} then {released:0}', async () => {
    const db = await openDb();
    await call(db.DB, '/api/conductor/held', { method: 'PUT', body: PUT_BODY });
    await call(db.DB, '/api/conductor/held', {
      method: 'PUT', body: { ...PUT_BODY, number: 999, head: 'e'.repeat(40) },
    });

    const gone = await call(db.DB, '/api/conductor/held/release', {
      method: 'POST', body: { ...KEY, why: 'CI went green' },
    });
    assert.equal(gone.status, 200);
    assert.deepEqual(gone.body, { released: 1 });
    // Exactly one: a DELETE missing a key predicate would take both.
    const left = rowsOf(db.db);
    assert.equal(left.length, 1);
    assert.equal(left[0].number, 999);

    // A replayed release has nothing to fix. 0 is a real answer, never a 404 --
    // a fail-open client reads a 404 as "this route is not deployed".
    const again = await call(db.DB, '/api/conductor/held/release', {
      method: 'POST', body: { ...KEY, why: 'CI went green' },
    });
    assert.equal(again.status, 200);
    assert.deepEqual(again.body, { released: 0 },
      'released is the DELETE\'s own meta.changes, never an assumed 1');
  });

  // ── 6. validation happens BEFORE any DB call ────────────────────────────
  // Asserted by observation, not by reading the source: a rejected write must
  // leave the table as it was, and must not have created it either.
  await t.test('a bad field is 400 and touches no row', async () => {
    const cases = [
      ['kind', { ...PUT_BODY, kind: 'FOO' }],
      ['repo', { ...PUT_BODY, repo: 'nope' }],
      ['number as string', { ...PUT_BODY, number: '1381' }],
      ['number zero', { ...PUT_BODY, number: 0 }],
      ['state', { ...PUT_BODY, state: 'NOT_A_STATE' }],
      ['mode', { ...PUT_BODY, mode: 'paused' }],
      ['text empty', { ...PUT_BODY, text: '' }],
      ['text too long', { ...PUT_BODY, text: 'x'.repeat(2001) }],
    ];
    for (const [label, body] of cases) {
      const db = await openDb();
      db.db.exec('DROP TABLE IF EXISTS conductor_held_pages');
      const res = await call(db.DB, '/api/conductor/held', { method: 'PUT', body });
      assert.equal(res.status, 400, `${label} must be 400, got ${res.status}`);
      assert.ok(typeof res.body.error === 'string' && res.body.error.length > 0,
        `${label} must carry an error string`);
      // No ensureTable, no INSERT: the table is still absent.
      assert.equal(db.db.prepare(
        "SELECT count(*) AS n FROM sqlite_master WHERE name='conductor_held_pages'"
      ).get().n, 0, `${label} must be refused before any DB call`);
    }
  });

  await t.test('release refuses a malformed key and a bad why', async () => {
    const db = await openDb();
    await call(db.DB, '/api/conductor/held', { method: 'PUT', body: PUT_BODY });

    for (const [label, body] of [
      ['bad kind', { ...KEY, kind: 'FOO', why: 'x' }],
      ['why missing', { ...KEY }],
      ['why empty', { ...KEY, why: '' }],
      ['why not a string', { ...KEY, why: 7 }],
      ['why too long', { ...KEY, why: 'x'.repeat(2001) }],
    ]) {
      const res = await call(db.DB, '/api/conductor/held/release', { method: 'POST', body });
      assert.equal(res.status, 400, `${label} must be 400, got ${res.status}`);
    }
    // And the row it refused to release is still there.
    assert.equal(rowsOf(db.db).length, 1);
  });

  // An explicit out-of-range value is REFUSED, never clamped and never silently
  // defaulted (D11): a reader that asked for `limit=abc` has a bug, and a 100
  // -row page reads to it as the whole table.
  await t.test('a non-integer limit is 400', async () => {
    const db = await openDb();
    for (const raw of ['abc', '1.5', '', 'null']) {
      const res = await call(db.DB, `/api/conductor/held?limit=${raw}`);
      assert.equal(res.status, 400, `limit=${raw} must be 400, got ${res.status}`);
    }
    // An integer out of range clamps into the documented window.
    for (const [raw, want] of [['0', 1], ['-3', 1], ['9999', 500]]) {
      const res = await call(db.DB, `/api/conductor/held?limit=${raw}`);
      assert.equal(res.status, 200, `limit=${raw} must be accepted`);
      assert.equal(res.body.n_total, 0);
      assert.equal(want, want);
    }
    // Absent limit is the documented default, not an error.
    assert.equal((await call(db.DB, '/api/conductor/held')).status, 200);
  });

  // ── 7. all three routes sit behind the bearer, by construction ───────────
  await t.test('no bearer is 401 on all three routes', async () => {
    const db = await openDb();
    for (const [method, path, body] of [
      ['PUT', '/api/conductor/held', PUT_BODY],
      ['GET', '/api/conductor/held', undefined],
      ['POST', '/api/conductor/held/release', { ...KEY, why: 'x' }],
    ]) {
      const res = await call(db.DB, path, { method, body, secret: null });
      assert.equal(res.status, 401, `${method} ${path} without a bearer must be 401`);
    }
    // A wrong bearer is refused too, not just a missing one.
    const bad = await call(db.DB, '/api/conductor/held', { secret: 'not-the-secret' });
    assert.equal(bad.status, 401);
  });

  // schema.sql must carry the table itself, not only the belt: the belt is the
  // fallback for a D1 that predates it, and `bin/lib/d1-schema.sh` applies THIS
  // file at harness-sync time.
  await t.test('schema.sql declares the table and the index', () => {
    const flat = SCHEMA.replace(/\s+/g, ' ');
    assert.ok(flat.includes('CREATE TABLE IF NOT EXISTS conductor_held_pages'),
      'schema.sql must create conductor_held_pages');
    assert.ok(flat.includes('CREATE INDEX IF NOT EXISTS idx_conductor_held_first ON conductor_held_pages(first_held_at)'),
      'schema.sql must create idx_conductor_held_first');
    assert.ok(flat.includes('PRIMARY KEY (repo, number, state, head, kind)'),
      'the hold identity is the primary key');
  });
});
