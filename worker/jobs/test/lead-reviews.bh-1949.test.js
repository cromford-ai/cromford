import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker, { CREATED_TABLES } from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-1949 (BH-1525.1) — the /api/lead-reviews routes over the lead_review_requests
// table BH-1948 shipped. Driven through worker.fetch against THE SQL THAT SHIPS
// (worker/jobs/schema.sql), the verdicts.bh-1525 idiom: claim and result are
// compare-and-set UPDATEs, and only a real engine can prove a second claimer loses.
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

// `lead: true` attaches the lead token; every call carries the bearer.
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
const H2 = 'b'.repeat(40);
const REQ = { repo: 'example-org/cromford', pr: 1949, head_sha: H1, scope_notes: 'look at the router' };
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM lead_review_requests').get().n;

async function created(DB, over = {}) {
  const res = await call(DB, '', { method: 'POST', body: { ...REQ, ...over }, lead: true });
  assert.equal(res.status, 201, JSON.stringify(res.body));
  return res.body.request;
}
const claim = (DB, id, job_id, box = 'box-1') => call(DB, `/${id}/claim`, { method: 'POST', body: { job_id, box } });
const result = (DB, id, body) => call(DB, `/${id}/result`, { method: 'POST', body: { head_sha: H1, ...body } });

test('1. schema parity: CREATED_TABLES.lead_review_requests builds the same table and index as schema.sql', () => {
  const block = SCHEMA.match(/CREATE TABLE IF NOT EXISTS lead_review_requests[\s\S]*?\);\s*CREATE INDEX IF NOT EXISTS idx_lead_review_requests_status[^;]*;/);
  assert.ok(block, 'schema.sql has no lead_review_requests block');
  assert.ok(Array.isArray(CREATED_TABLES.lead_review_requests), 'CREATED_TABLES has no lead_review_requests key');
  const a = new DatabaseSync(':memory:');
  a.exec(block[0]);
  const b = new DatabaseSync(':memory:');
  for (const stmt of CREATED_TABLES.lead_review_requests) b.exec(stmt);
  const cols = (db) => db.prepare('PRAGMA table_info(lead_review_requests)').all()
    .map(({ name, type, notnull, dflt_value, pk }) => ({ name, type, notnull, dflt_value, pk }));
  assert.equal(cols(a).length, 17);
  assert.deepEqual(cols(b), cols(a));
  const idx = (db) => db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='lead_review_requests' ORDER BY name").all().map((r) => r.name);
  assert.deepEqual(idx(b), idx(a));
  assert.ok(idx(b).includes('idx_lead_review_requests_status'));
});

test('2. create without the lead token (bearer only) → 403, and no row is written', async () => {
  const { db, DB } = fresh();
  const res = await call(DB, '', { method: 'POST', body: REQ });
  assert.equal(res.status, 403);
  assert.match(res.body.error, /lead verdict token/);
  assert.equal(count(db), 0);
});

test('3. a short or non-hex head_sha → 400, never resolved, no row', async () => {
  const { db, DB } = fresh();
  for (const head_sha of ['abc1234', 'g'.repeat(40), 'a'.repeat(39), '']) {
    const res = await call(DB, '', { method: 'POST', body: { ...REQ, head_sha }, lead: true });
    assert.equal(res.status, 400, `head_sha=${head_sha}`);
    assert.match(res.body.error, /head_sha/);
  }
  assert.equal((await call(DB, '', { method: 'POST', body: { ...REQ, repo: 'no-slash' }, lead: true })).status, 400);
  assert.equal((await call(DB, '', { method: 'POST', body: { ...REQ, pr: 0 }, lead: true })).status, 400);
  assert.equal(count(db), 0);
});

test('4. create twice with the same payload → 201 then 200, same id, one row; the sha is lower-cased', async () => {
  const { db, DB } = fresh();
  const first = await call(DB, '', { method: 'POST', body: { ...REQ, head_sha: H1.toUpperCase() }, lead: true });
  assert.equal(first.status, 201);
  assert.equal(first.body.request.status, 'requested');
  assert.equal(first.body.request.head_sha, H1);
  const again = await call(DB, '', { method: 'POST', body: REQ, lead: true });
  assert.equal(again.status, 200);
  assert.equal(again.body.existing, true);
  assert.equal(again.body.request.id, first.body.request.id);
  assert.equal(count(db), 1);
});

test('5. same (repo, pr, head) with different scope_notes → 409, and the stored row is untouched', async () => {
  const { db, DB } = fresh();
  const row = await created(DB);
  const res = await call(DB, '', { method: 'POST', body: { ...REQ, scope_notes: 'something else' }, lead: true });
  assert.equal(res.status, 409);
  assert.equal(res.body.request.id, row.id);
  assert.equal(res.body.request.scope_notes, REQ.scope_notes);
  // absent notes against stored notes is also a different scope
  assert.equal((await call(DB, '', { method: 'POST', body: { ...REQ, scope_notes: undefined }, lead: true })).status, 409);
  assert.equal(count(db), 1);
});

test('6. claim: A wins, B → 409 while A holds it, A re-claims → 200', async () => {
  const { DB } = fresh();
  const row = await created(DB);
  const a = await claim(DB, row.id, 'job-A');
  assert.equal(a.status, 200);
  assert.equal(a.body.request.status, 'running');
  assert.equal(a.body.request.job_id, 'job-A');
  const b = await claim(DB, row.id, 'job-B', 'box-2');
  assert.equal(b.status, 409);
  assert.equal(b.body.request.job_id, 'job-A');
  assert.equal((await claim(DB, row.id, 'job-A')).status, 200);
  assert.equal((await claim(DB, 'no-such-id', 'job-A')).status, 404);
  assert.equal((await call(DB, `/${row.id}/claim`, { method: 'POST', body: { box: 'x' } })).status, 400);
  assert.equal((await call(DB, `/${row.id}/claim`, { method: 'POST', body: { job_id: 'job-A' } })).status, 400);
});

test('7. result from the wrong job, or the right job on a different head → 409; the row stays running', async () => {
  const { db, DB } = fresh();
  const row = await created(DB);
  await claim(DB, row.id, 'job-A');
  const wrongJob = await result(DB, row.id, { job_id: 'job-B', outcome: 'done', verdict: 'MERGE' });
  assert.equal(wrongJob.status, 409);
  const wrongHead = await result(DB, row.id, { job_id: 'job-A', head_sha: H2, outcome: 'done', verdict: 'MERGE' });
  assert.equal(wrongHead.status, 409);
  const stored = db.prepare('SELECT status, verdict FROM lead_review_requests WHERE id=?').get(row.id);
  assert.equal(stored.status, 'running');
  assert.equal(stored.verdict, null);
});

test('7b. result on a requested (never claimed) row → 409', async () => {
  const { DB } = fresh();
  const row = await created(DB);
  assert.equal((await result(DB, row.id, { job_id: 'job-A', outcome: 'done', verdict: 'MERGE' })).status, 409);
});

test('8. the vocabulary is refused, never mapped: APPROVE, lower-case, approved, done without a verdict → 400', async () => {
  const { db, DB } = fresh();
  const row = await created(DB);
  await claim(DB, row.id, 'job-A');
  for (const body of [
    { outcome: 'done', verdict: 'APPROVE' },
    { outcome: 'done', verdict: 'merge' },
    { outcome: 'done', verdict: '' },
    { outcome: 'approved', verdict: 'MERGE' },
    { outcome: 'MERGE' },
    { outcome: 'done' },
    { outcome: 'failed', verdict: 'BLOCK' },
  ]) {
    const res = await result(DB, row.id, { job_id: 'job-A', ...body });
    assert.equal(res.status, 400, JSON.stringify(body));
  }
  assert.equal(db.prepare('SELECT status FROM lead_review_requests WHERE id=?').get(row.id).status, 'running');
});

test('9. done+MERGE seals the row; the identical retry → 200 unchanged; anything else → 409; claim after done → 409', async () => {
  const { DB } = fresh();
  const row = await created(DB);
  await claim(DB, row.id, 'job-A');
  const done = await result(DB, row.id, { job_id: 'job-A', outcome: 'done', verdict: 'MERGE', report_ref: 'r/1', reviewer_model: 'm' });
  assert.equal(done.status, 200);
  assert.equal(done.body.request.status, 'done');
  assert.equal(done.body.request.verdict, 'MERGE');
  assert.equal(done.body.request.report_ref, 'r/1');
  const retry = await result(DB, row.id, { job_id: 'job-A', outcome: 'done', verdict: 'MERGE', report_ref: 'r/2' });
  assert.equal(retry.status, 200);
  assert.deepEqual(retry.body.request, done.body.request);
  // the identical result from a job that never held the row is not a retry
  assert.equal((await result(DB, row.id, { job_id: 'job-B', outcome: 'done', verdict: 'MERGE' })).status, 409);
  assert.equal((await result(DB, row.id, { job_id: 'job-A', outcome: 'done', verdict: 'BLOCK' })).status, 409);
  assert.equal((await result(DB, row.id, { job_id: 'job-A', outcome: 'failed' })).status, 409);
  assert.equal((await claim(DB, row.id, 'job-A')).status, 409);
  assert.equal((await result(DB, 'no-such-id', { job_id: 'job-A', outcome: 'failed' })).status, 404);
});

test('10. promoted: lead token only, done rows only, stamped once', async () => {
  const { db, DB } = fresh();
  const row = await created(DB);
  assert.equal((await call(DB, `/${row.id}/promoted`, { method: 'POST', lead: true })).status, 409, 'a requested row is not promotable');
  await claim(DB, row.id, 'job-A');
  await result(DB, row.id, { job_id: 'job-A', outcome: 'done', verdict: 'BLOCK' });
  assert.equal((await call(DB, `/${row.id}/promoted`, { method: 'POST' })).status, 403);
  const first = await call(DB, `/${row.id}/promoted`, { method: 'POST', lead: true });
  assert.equal(first.status, 200);
  assert.ok(first.body.request.promoted_verdict_at);
  // The worker clock is second-resolution, so a re-stamp inside this test
  // would write the same string. Age the stored stamp: a second call must keep it.
  db.prepare("UPDATE lead_review_requests SET promoted_verdict_at='2000-01-01T00:00:00Z' WHERE id=?").run(row.id);
  const second = await call(DB, `/${row.id}/promoted`, { method: 'POST', lead: true });
  assert.equal(second.status, 200);
  assert.equal(second.body.request.promoted_verdict_at, '2000-01-01T00:00:00Z');
  assert.equal((await call(DB, '/no-such-id/promoted', { method: 'POST', lead: true })).status, 404);
});

test('11. list: status/repo filters, limit refused outside 1..100, truncated exact', async () => {
  const { DB } = fresh();
  // All four land in the same second (created_at is second-resolution): the
  // order must still be the order they were asked in, not the random id's.
  const r1 = await created(DB, { pr: 1 });
  await created(DB, { pr: 2 });
  await created(DB, { pr: 3 });
  await created(DB, { pr: 4, repo: 'example-org/other' });
  await claim(DB, r1.id, 'job-A');
  const capped = await call(DB, '?repo=example-org/cromford&limit=2');
  assert.equal(capped.status, 200);
  assert.equal(capped.body.requests.length, 2);
  assert.equal(capped.body.truncated, true);
  const fit = await call(DB, '?repo=example-org/cromford&limit=3');
  assert.equal(fit.body.requests.length, 3);
  assert.equal(fit.body.truncated, false);
  assert.deepEqual(fit.body.requests.map((r) => r.pr), [1, 2, 3]);
  for (const q of ['?limit=101', '?limit=0', '?limit=abc', '?limit=2.5', '?status=bogus', '?status=requested,bogus', '?repo=no-slash']) {
    assert.equal((await call(DB, q)).status, 400, q);
  }
  const running = await call(DB, '?status=running');
  assert.deepEqual(running.body.requests.map((r) => r.id), [r1.id]);
  const both = await call(DB, '?status=requested,running&repo=example-org/cromford');
  assert.deepEqual(both.body.requests.map((r) => r.pr), [1, 2, 3]);
  const other = await call(DB, '?status=requested&repo=example-org/other');
  assert.deepEqual(other.body.requests.map((r) => r.pr), [4]);
  assert.equal((await call(DB, '')).body.requests.length, 4);
});

test('12. GET by id → 200; an unknown id → a 404 that is NOT the worker\'s unknown-endpoint body', async () => {
  const { DB } = fresh();
  const row = await created(DB);
  const got = await call(DB, `/${row.id}`);
  assert.equal(got.status, 200);
  assert.equal(got.body.request.id, row.id);
  const miss = await call(DB, '/no-such-id');
  assert.equal(miss.status, 404);
  assert.equal(miss.body.worker, undefined);
  assert.match(miss.body.error, /no such lead review request/);
});

test('the table self-creates: routes work on a DB where schema.sql was never applied', async () => {
  const db = new DatabaseSync(':memory:');
  const DB = sqliteDB(db);
  const res = await call(DB, '', { method: 'POST', body: REQ, lead: true });
  assert.equal(res.status, 201);
});
