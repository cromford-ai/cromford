import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-5400 — a lead review request that is reset to `requested` and re-reviewed
// must be visible to the land lane again, and the reset must be recorded
// whatever path made it. Driven through worker.fetch over the shipped
// schema.sql (the bh-1949 idiom); reset_count / reset_at are ADDED columns, so
// ensureColumns adds them on the first handler call.
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
const REQ = { repo: 'example-org/cromford', pr: 5400, head_sha: H1 };
const rowOf = (db, id) => db.prepare('SELECT * FROM lead_review_requests WHERE id=?').get(id);

async function created(DB) {
  const res = await call(DB, '', { method: 'POST', body: REQ, lead: true });
  assert.equal(res.status, 201, JSON.stringify(res.body));
  return res.body.request.id;
}
const claim = (DB, id, job_id) => call(DB, `/${id}/claim`, { method: 'POST', body: { job_id, box: 'box-1' } });
const result = (DB, id, job_id, verdict) =>
  call(DB, `/${id}/result`, { method: 'POST', body: { job_id, head_sha: H1, outcome: 'done', verdict, report_ref: 'r.md', reviewer_model: 'm' } });
const promoted = (DB, id, body) => call(DB, `/${id}/promoted`, { method: 'POST', lead: true, ...(body === undefined ? {} : { body }) });

// done + promoted by job-1: the state the incident's rows were in before the reset.
async function landed(DB, verdict = 'BLOCK') {
  const id = await created(DB);
  assert.equal((await claim(DB, id, 'job-1')).status, 200);
  assert.equal((await result(DB, id, 'job-1', verdict)).status, 200);
  assert.equal((await promoted(DB, id)).status, 200);
  return id;
}

test('W1. reset route: lead token, 404, done -> requested with the result cleared, idempotent, running -> 409', async () => {
  const { db, DB } = fresh();
  const id = await landed(DB);
  const no = await call(DB, `/${id}/reset`, { method: 'POST', body: {} });
  assert.equal(no.status, 403);
  assert.equal(rowOf(db, id).status, 'done');
  assert.equal((await call(DB, '/nope/reset', { method: 'POST', body: {}, lead: true })).status, 404);

  const r = await call(DB, `/${id}/reset`, { method: 'POST', body: {}, lead: true });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const row = rowOf(db, id);
  assert.equal(row.status, 'requested');
  for (const k of ['job_id', 'box', 'verdict', 'report_ref', 'reviewer_model', 'detail', 'promoted_verdict_at']) {
    assert.equal(row[k], null, `${k} not cleared`);
  }
  assert.equal(row.reset_count, 1);
  assert.ok(row.reset_at, 'reset_at not stamped');
  assert.equal(r.body.request.reset_count, 1);

  const again = await call(DB, `/${id}/reset`, { method: 'POST', body: {}, lead: true });
  assert.equal(again.status, 200);
  assert.equal(again.body.existing, true);
  assert.equal(rowOf(db, id).reset_count, 1);

  assert.equal((await claim(DB, id, 'job-2')).status, 200);
  const busy = await call(DB, `/${id}/reset`, { method: 'POST', body: {}, lead: true });
  assert.equal(busy.status, 409);
  assert.equal(rowOf(db, id).status, 'running');
  assert.equal(rowOf(db, id).job_id, 'job-2');
});

test('W2. a raw-SQL reset is recorded by the claim; a fresh claim and an own-job re-claim are not resets', async () => {
  const { db, DB } = fresh();
  const id = await landed(DB);
  db.prepare("UPDATE lead_review_requests SET status='requested' WHERE id=?").run(id);
  const c = await claim(DB, id, 'job-2');
  assert.equal(c.status, 200, JSON.stringify(c.body));
  const row = rowOf(db, id);
  assert.equal(row.reset_count, 1);
  assert.equal(row.reset_at, row.updated_at, 'reset_at is the claim time');
  assert.equal(row.promoted_verdict_at, null);
  assert.equal(row.job_id, 'job-2');
  assert.equal((await claim(DB, id, 'job-2')).status, 200);
  assert.equal(rowOf(db, id).reset_count, 1, 'an own-job re-claim counted as a reset');

  const { db: db2, DB: DB2 } = fresh();
  const id2 = await created(DB2);
  assert.equal((await claim(DB2, id2, 'job-1')).status, 200);
  assert.equal(rowOf(db2, id2).reset_count, null);
  assert.equal(rowOf(db2, id2).reset_at, null);
});

test('W3. a route reset then a claim counts once', async () => {
  const { db, DB } = fresh();
  const id = await landed(DB);
  assert.equal((await call(DB, `/${id}/reset`, { method: 'POST', body: {}, lead: true })).status, 200);
  assert.equal((await claim(DB, id, 'job-2')).status, 200);
  assert.equal(rowOf(db, id).reset_count, 1);
});

test('W4. the promoted stamp is bound to the job it names; no body still stamps', async () => {
  const { db, DB } = fresh();
  const id = await landed(DB);
  db.prepare("UPDATE lead_review_requests SET status='requested' WHERE id=?").run(id);
  await claim(DB, id, 'job-2');
  await result(DB, id, 'job-2', 'MERGE');
  const stale = await promoted(DB, id, { job_id: 'job-1' });
  assert.equal(stale.status, 409);
  assert.match(stale.body.error, /job-2/);
  assert.equal(rowOf(db, id).promoted_verdict_at, null);
  assert.equal((await promoted(DB, id, { job_id: 'job-2' })).status, 200);
  assert.ok(rowOf(db, id).promoted_verdict_at);

  const { db: db2, DB: DB2 } = fresh();
  const id2 = await created(DB2);
  await claim(DB2, id2, 'job-1');
  await result(DB2, id2, 'job-1', 'MERGE');
  assert.equal((await promoted(DB2, id2)).status, 200);
  assert.ok(rowOf(db2, id2).promoted_verdict_at);
});

test('W5. after a raw reset and a new result, ?promoted=0 lists the row again', async () => {
  const { db, DB } = fresh();
  const id = await landed(DB);
  const before = await call(DB, '?status=done&promoted=0');
  assert.equal(before.body.requests.length, 0);
  db.prepare("UPDATE lead_review_requests SET status='requested' WHERE id=?").run(id);
  await claim(DB, id, 'job-2');
  await result(DB, id, 'job-2', 'MERGE');
  const after = await call(DB, '?status=done&promoted=0');
  assert.equal(after.status, 200);
  assert.deepEqual(after.body.requests.map((r) => [r.id, r.job_id, r.verdict, r.reset_count]), [[id, 'job-2', 'MERGE', 1]]);
});
