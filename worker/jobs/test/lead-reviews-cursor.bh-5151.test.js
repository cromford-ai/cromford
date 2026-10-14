import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker, { CREATED_TABLES } from '../src/index.js';
import { ADDED_COLUMNS } from '../src/lib/core.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-5151 — GET /api/lead-reviews reads the WHOLE queue through an
// `after=<created_at>,<rowid>` cursor (next_after on a truncated page), and
// lead_review_requests gains a nullable `priority INTEGER` through
// ADDED_COLUMNS/ensureColumns, settable on POST. Driven through worker.fetch
// against THE SQL THAT SHIPS (worker/jobs/schema.sql), the bh-1949 idiom.
const SECRET = 'test-secret';
const LEAD = 'lead-test-token';
const SCHEMA = jobsSchemaSql();

function sqliteDB(db) {
  const bindAndRun = (sql, binds) => ({
    first: async () => db.prepare(sql).get(...binds) ?? null,
    all: async () => ({ results: db.prepare(sql).all(...binds) }),
    run: async () => {
      const r = db.prepare(sql).run(...binds);
      return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
    },
  });
  return {
    prepare: (sql) => ({ ...bindAndRun(sql, []), bind: (...b) => bindAndRun(sql, b.map((v) => (v === undefined ? null : v))) }),
  };
}
const fresh = () => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return { db, DB: sqliteDB(db) }; };

const call = (DB, path, { method = 'GET', body, lead = false } = {}) => {
  const req = new Request(`https://jobs.test/api/lead-reviews${path}`, {
    method,
    headers: {
      authorization: `Bearer ${SECRET}`,
      ...(lead ? { 'x-lead-verdict-token': LEAD } : {}),
      'content-type': 'application/json',
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const H1 = 'a'.repeat(40);
const REQ = { repo: 'example-org/cromford', pr: 5151, head_sha: H1, scope_notes: 'the queue' };
const cols = (db) => db.prepare('PRAGMA table_info(lead_review_requests)').all();

// n rows straight into the table, created_at cycling over three timestamps so
// every page boundary lands inside a run of equal created_at.
function seed(db, n, status = 'requested') {
  const ts = ['2026-10-07 05:00:00', '2026-10-07 06:00:00', '2026-10-07 07:00:00'];
  const st = db.prepare(`INSERT INTO lead_review_requests (id, repo, pr, head_sha, status, created_at, updated_at)
                         VALUES (?, 'example-org/cromford', ?, ?, ?, ?, ?)`);
  for (let i = 0; i < n; i++) {
    const t = ts[i % 3];
    st.run(`r-${String(i).padStart(3, '0')}`, 1000 + i, i.toString(16).padStart(40, '0'), status, t, t);
  }
}
const order = (db) => db.prepare('SELECT id FROM lead_review_requests ORDER BY created_at, rowid').all().map((r) => r.id);

test('1. 250 rows over 3 pages via next_after: every id once, in created_at,rowid order; no lr_rowid leaks', async () => {
  const { db, DB } = fresh();
  seed(db, 250);
  const seen = [];
  let q = '?status=requested,running&limit=100';
  let pages = 0;
  for (;;) {
    const res = await call(DB, q);
    assert.equal(res.status, 200, JSON.stringify(res.body));
    pages++;
    for (const r of res.body.requests) {
      assert.ok(!('lr_rowid' in r), 'a row carries lr_rowid');
      seen.push(r.id);
    }
    if (!res.body.truncated) {
      assert.ok(!('next_after' in res.body), 'an untruncated page carries next_after');
      break;
    }
    assert.match(res.body.next_after, /^.+,\d+$/);
    q = `?status=requested,running&limit=100&after=${encodeURIComponent(res.body.next_after)}`;
    assert.ok(pages < 10, 'the cursor never ended');
  }
  assert.equal(pages, 3);
  assert.equal(seen.length, 250);
  assert.equal(new Set(seen).size, 250);
  assert.deepEqual(seen, order(db));
});

test('2. a malformed after is a 400 naming next_after', async () => {
  const { db, DB } = fresh();
  seed(db, 5);
  for (const a of ['x', '2026-10-07T00:00:00Z', 't,abc', `${'x'.repeat(65)},3`, ',5', 't,', 't,-1']) {
    const res = await call(DB, `?status=requested&after=${encodeURIComponent(a)}`);
    assert.equal(res.status, 400, `after=${a}`);
    assert.match(res.body.error, /next_after/);
  }
});

test('3. no after: the answer is today\'s (no next_after when not truncated); promoted=0 and after compose', async () => {
  const { db, DB } = fresh();
  seed(db, 5);
  const res = await call(DB, '?status=requested');
  assert.equal(res.status, 200);
  assert.deepEqual(Object.keys(res.body).sort(), ['as_of', 'requests', 'truncated']);
  assert.equal(res.body.truncated, false);
  assert.deepEqual(res.body.requests.map((r) => r.id), order(db));
  // limit 2 → truncated with next_after; the next page carries on from it
  const p1 = await call(DB, '?status=requested&limit=2');
  assert.equal(p1.body.truncated, true);
  assert.deepEqual(p1.body.requests.map((r) => r.id), order(db).slice(0, 2));
  const p2 = await call(DB, `?status=requested&limit=2&promoted=0&after=${encodeURIComponent(p1.body.next_after)}`);
  assert.equal(p2.status, 200);
  assert.deepEqual(p2.body.requests.map((r) => r.id), order(db).slice(2, 4));
  // promoted rows stay out under promoted=0 even past a cursor
  db.prepare("UPDATE lead_review_requests SET promoted_verdict_at='x' WHERE id=?").run(order(db)[2]);
  const p3 = await call(DB, `?status=requested&limit=2&promoted=0&after=${encodeURIComponent(p1.body.next_after)}`);
  assert.deepEqual(p3.body.requests.map((r) => r.id), [order(db)[3], order(db)[4]]);
  // the limit is still refused outside 1..100, never clamped
  assert.equal((await call(DB, '?limit=101')).status, 400);
});

test('4. a database built from schema.sql gains priority INTEGER on the first request, and a second handler call is fine', async () => {
  const { db, DB } = fresh();
  assert.ok(!cols(db).some((c) => c.name === 'priority'), 'schema.sql already carries priority');
  assert.equal((await call(DB, '?status=requested')).status, 200);
  const p = cols(db).find((c) => c.name === 'priority');
  assert.ok(p, 'ensureColumns did not add priority');
  assert.equal(p.type, 'INTEGER');
  assert.equal(p.notnull, 0);
  assert.equal((await call(DB, '?status=requested')).status, 200);
  // a second handle on the same database (another isolate) re-runs the check without a duplicate-column failure
  assert.equal((await call(sqliteDB(db), '?status=requested')).status, 200);
});

test('5. POST priority: 7 is stored; 0, -1, 1.5, "7", 1001 are 400 and write nothing', async () => {
  const { db, DB } = fresh();
  const ok = await call(DB, '', { method: 'POST', body: { ...REQ, priority: 7 }, lead: true });
  assert.equal(ok.status, 201, JSON.stringify(ok.body));
  assert.equal(ok.body.request.priority, 7);
  for (const [i, priority] of [0, -1, 1.5, '7', 1001, true].entries()) {
    const res = await call(DB, '', { method: 'POST', body: { ...REQ, head_sha: String(i).repeat(40), priority }, lead: true });
    assert.equal(res.status, 400, `priority=${JSON.stringify(priority)}`);
    assert.match(res.body.error, /priority must be an integer 1\.\.1000/);
  }
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM lead_review_requests').get().n, 1);
  // absent and null both mean none
  const none = await call(DB, '', { method: 'POST', body: { ...REQ, head_sha: 'b'.repeat(40), priority: null }, lead: true });
  assert.equal(none.status, 201);
  assert.equal(none.body.request.priority, null);
});

test('6. the same ask again with a new priority: a requested row takes it (created_at kept); a running row keeps its own; a new scope is 409', async () => {
  const { db, DB } = fresh();
  const first = await call(DB, '', { method: 'POST', body: REQ, lead: true });
  assert.equal(first.status, 201);
  db.prepare("UPDATE lead_review_requests SET created_at='2026-10-01 00:00:00'").run();
  const bump = await call(DB, '', { method: 'POST', body: { ...REQ, priority: 9 }, lead: true });
  assert.equal(bump.status, 200, JSON.stringify(bump.body));
  assert.equal(bump.body.existing, true);
  assert.equal(bump.body.request.priority, 9);
  assert.equal(bump.body.request.created_at, '2026-10-01 00:00:00');
  // the token still comes first
  assert.equal((await call(DB, '', { method: 'POST', body: { ...REQ, priority: 3 } })).status, 403);
  assert.equal(db.prepare('SELECT priority FROM lead_review_requests').get().priority, 9);
  // a running row keeps its order
  db.prepare("UPDATE lead_review_requests SET status='running', job_id='j1'").run();
  const run = await call(DB, '', { method: 'POST', body: { ...REQ, priority: 4 }, lead: true });
  assert.equal(run.status, 200);
  assert.equal(run.body.existing, true);
  assert.equal(run.body.request.priority, 9);
  // a different scope is still a different ask
  assert.equal((await call(DB, '', { method: 'POST', body: { ...REQ, scope_notes: 'else', priority: 4 }, lead: true })).status, 409);
});

test('7. bh-1949 parity still holds: CREATED_TABLES builds 17 columns; priority lives in ADDED_COLUMNS only', () => {
  const b = new DatabaseSync(':memory:');
  for (const stmt of CREATED_TABLES.lead_review_requests) b.exec(stmt);
  assert.equal(cols(b).length, 17);
  // TEST-CHANGE (BH-5400): reset_count / reset_at joined priority as ADDED
  // columns; the list is still pinned whole, and none of them is in schema.sql.
  // TEST-CHANGE (BH-5349): the three BH-5348 sibling columns follow them;
  // priority is still the first entry and the CREATE carries none of the six.
  // TEST-CHANGE (BH-5779): stale_reclaims (the reclaim-stale sweep) is the
  // seventh, appended last; the CREATE carries it neither.
  assert.deepEqual(ADDED_COLUMNS.lead_review_requests,
    [['priority', 'INTEGER'], ['reset_count', 'INTEGER'], ['reset_at', 'TEXT'],
     ['heartbeat_at', 'TEXT'], ['participant', 'TEXT'], ['head_authors', 'TEXT'],
     ['stale_reclaims', 'INTEGER']]);
  assert.ok(!/priority|reset_count|reset_at|heartbeat_at|participant|head_authors|stale_reclaims/.test(SCHEMA.match(/CREATE TABLE IF NOT EXISTS lead_review_requests[\s\S]*?\);/)[0]));
});
