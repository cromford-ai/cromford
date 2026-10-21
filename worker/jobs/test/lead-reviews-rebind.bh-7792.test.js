// BH-7792 — a finished paid lead review is never lost to a rebind. A request
// was dispatched again while its first job was still inside its paid call; the
// request was rebound to the second job, the first job's result was refused
// ("job_id is not the job this request is bound to"), and the second job was
// refused by the call-guard (paid 1/1). The PR then had no lead verdict for 24 h.
//   B1  two dispatches of one request, the first finishes after the second
//       binds: the first job's done result lands, and the second job's /start
//       answers terminal done (paid already: no agent call) and its /result 409s.
//   B2  only a live lead-review job of this exact head wins a rebind: a failed
//       job, a job of another ticket, a job with no jobs row, and a result that
//       is not `done` are all still 409.
//   B3  a recorded result is never replaced by a rebind.
//   B4  POST /:id/release {job_id}: the job that holds the running claim puts it
//       back to requested (job, box and heartbeat cleared, no reset counted);
//       any other job, or a row that is not running, is 409.
//   B5  after a release, the first job's finished review still lands.
// Driven through worker.fetch against the schema that ships (the bh-1949 idiom).
import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'test-secret';
const LEAD = 'lead-test-token';
const SCHEMA = jobsSchemaSql();

function sqliteDB(db) {
  const bindAndRun = (sql, binds) => ({
    first: async (col) => { const r = db.prepare(sql).get(...binds) ?? null; return col && r ? r[col] : r; },
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
  const headers = { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' };
  if (lead) headers['x-lead-verdict-token'] = LEAD;
  const req = new Request(`https://jobs.test/api/lead-reviews${path}`, { method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const H1 = 'c'.repeat(40);
const REPO = 'example-org/cromford';
const PR = 7792;
const KEY = `lr-${PR}-${H1.slice(0, 12)}`;
const BASE = { repo: REPO, pr: PR, head_sha: H1 };
const start = (DB, job_id, box) => call(DB, '/start', { method: 'POST', body: { ...BASE, job_id, box } });
const claim = (DB, id, job_id, box) => call(DB, `/${id}/claim`, { method: 'POST', body: { job_id, box } });
const result = (DB, id, job_id, over = {}) => call(DB, `/${id}/result`, {
  method: 'POST', body: { job_id, head_sha: H1, outcome: 'done', verdict: 'MERGE-WITH-NOTES', report_ref: `state/lead-reviews/${KEY}.md`, ...over },
});
const release = (DB, id, job_id, detail) => call(DB, `/${id}/release`, { method: 'POST', body: { job_id, ...(detail ? { detail } : {}) } });
const rowOf = (db) => db.prepare('SELECT * FROM lead_review_requests WHERE repo=? AND pr=? AND head_sha=?').get(REPO, PR, H1);

const ANCHOR = Date.now(); // determinism: ok the single anchor the seeded job rows are stamped from
const ago = (s) => new Date(ANCHOR - s * 1000).toISOString();
// seedJob — a jobs row as job_open writes it for a lead review: ticket lr-<pr>-<sha12>, kind lead_review.
function seedJob(db, id, status, { box = 'box-a', ticket = KEY, kind = 'lead_review' } = {}) {
  db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at)
              VALUES (?,?,?,?,?,?,?,?,?)`)
    .run(id, 'cromford', ticket, kind, box, 'review', status, ago(120), ago(60));
}
const setJob = (db, id, status) => db.prepare('UPDATE jobs SET status=? WHERE id=?').run(status, id);

// The incident's shape: J1 starts on box-a; its job row is closed while its paid
// call runs (the same-box "key held" path did that); J2 on box-b then takes the
// request over through /start, which reads J1 as not live.
async function rebound(db, DB, j1Status = 'done') {
  seedJob(db, 'J1', 'running', { box: 'box-a' });
  const s1 = await start(DB, 'J1', 'box-a');
  assert.equal(s1.status, 200, JSON.stringify(s1.body));
  setJob(db, 'J1', j1Status);
  seedJob(db, 'J2', 'running', { box: 'box-b' });
  const s2 = await start(DB, 'J2', 'box-b');
  assert.equal(s2.status, 200, JSON.stringify(s2.body));
  assert.equal(rowOf(db).job_id, 'J2');
  return s1.body.request;
}

test('B1. the first job finishes after the second binds: its result lands, the second does not pay', async () => {
  const { db, DB } = fresh();
  const r = await rebound(db, DB);
  const late = await result(DB, r.id, 'J1');
  assert.equal(late.status, 200, JSON.stringify(late.body));
  const now = rowOf(db);
  assert.equal(now.status, 'done');
  assert.equal(now.verdict, 'MERGE-WITH-NOTES');
  assert.equal(now.job_id, 'J1', 'the row is bound to the job that did the review');
  assert.equal(now.box, 'box-a');
  assert.equal(now.report_ref, `state/lead-reviews/${KEY}.md`);
  assert.deepEqual(late.body.rebound_from, { job_id: 'J2', box: 'box-b' });
  // The second dispatch: its next start is terminal done (bin/lead-review.sh
  // logs "paid already" and makes no agent call), and its result is refused.
  const again = await start(DB, 'J2', 'box-b');
  assert.equal(again.status, 409);
  assert.equal(again.body.terminal, true);
  const second = await result(DB, r.id, 'J2', { verdict: 'BLOCK' });
  assert.equal(second.status, 409);
  assert.equal(rowOf(db).verdict, 'MERGE-WITH-NOTES');
});

test('B1b. a still-running first job (the rebind came from a second dispatcher) also lands', async () => {
  const { db, DB } = fresh();
  seedJob(db, 'J1', 'running', { box: 'box-a' });
  const s1 = await start(DB, 'J1', 'box-a');
  assert.equal(s1.status, 200, JSON.stringify(s1.body));
  const r = s1.body.request;
  // J1 is live, so /start refuses J2; a claim taken past a quiet heartbeat binds it instead.
  assert.equal((await start(DB, 'J2', 'box-b')).status, 409);
  db.prepare('UPDATE lead_review_requests SET heartbeat_at=?1, updated_at=?1 WHERE id=?2').run(ago(3000), r.id);
  seedJob(db, 'J2', 'running', { box: 'box-b' });
  const c = await claim(DB, r.id, 'J2', 'box-b');
  assert.equal(c.status, 200, JSON.stringify(c.body));
  assert.equal(rowOf(db).job_id, 'J2');
  const late = await result(DB, r.id, 'J1', { verdict: 'BLOCK' });
  assert.equal(late.status, 200, JSON.stringify(late.body));
  assert.equal(rowOf(db).verdict, 'BLOCK');
  assert.equal(rowOf(db).job_id, 'J1');
});

test('B2. only a live lead-review job of this exact head wins a rebind', async () => {
  for (const [label, prep, over] of [
    ['failed job', (db) => setJob(db, 'J1', 'failed'), {}],
    ['another ticket', (db) => db.prepare("UPDATE jobs SET ticket_id='lr-1-aaaaaaaaaaaa' WHERE id='J1'").run(), {}],
    ['another kind', (db) => db.prepare("UPDATE jobs SET kind='review' WHERE id='J1'").run(), {}],
    ['no jobs row', (db) => db.prepare("DELETE FROM jobs WHERE id='J1'").run(), {}],
    ['failed outcome', () => {}, { outcome: 'failed', verdict: undefined, detail: 'empty' }],
    ['superseded outcome', () => {}, { outcome: 'superseded', verdict: undefined }],
  ]) {
    const { db, DB } = fresh();
    const r = await rebound(db, DB);
    prep(db);
    const res = await result(DB, r.id, 'J1', over);
    assert.equal(res.status, 409, `${label}: ${JSON.stringify(res.body)}`);
    assert.equal(res.body.error, 'job_id is not the job this request is bound to', label);
    assert.equal(rowOf(db).status, 'running', label);
    assert.equal(rowOf(db).job_id, 'J2', label);
  }
});

test('B2b. a rebind result on another head is still refused', async () => {
  const { db, DB } = fresh();
  const r = await rebound(db, DB);
  const res = await result(DB, r.id, 'J1', { head_sha: 'd'.repeat(40) });
  assert.equal(res.status, 409);
  assert.equal(rowOf(db).job_id, 'J2');
});

test('B3. a recorded result is never replaced by a rebind', async () => {
  const { db, DB } = fresh();
  const r = await rebound(db, DB);
  assert.equal((await result(DB, r.id, 'J2', { verdict: 'MERGE' })).status, 200);
  const late = await result(DB, r.id, 'J1', { verdict: 'BLOCK' });
  assert.equal(late.status, 409);
  assert.equal(rowOf(db).verdict, 'MERGE');
  assert.equal(rowOf(db).job_id, 'J2');
});

test('B4. release: the holder puts its claim back to requested; nobody else can', async () => {
  const { db, DB } = fresh();
  const r = await rebound(db, DB);
  const resetsBefore = rowOf(db).reset_count ?? 0;
  const other = await release(DB, r.id, 'J1');
  assert.equal(other.status, 409, JSON.stringify(other.body));
  assert.equal(rowOf(db).job_id, 'J2');
  const missing = await call(DB, '/nope/release', { method: 'POST', body: { job_id: 'J2' } });
  assert.equal(missing.status, 404);
  assert.equal((await call(DB, `/${r.id}/release`, { method: 'POST', body: {} })).status, 400);
  const ok = await release(DB, r.id, 'J2', 'call-guard refused (rc 74): nothing billed');
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  const now = rowOf(db);
  assert.equal(now.status, 'requested');
  assert.equal(now.job_id, null);
  assert.equal(now.box, null);
  assert.equal(now.heartbeat_at, null);
  assert.equal(now.detail, 'call-guard refused (rc 74): nothing billed');
  assert.equal(now.reset_count ?? 0, resetsBefore, 'a release is not a reset');
  // The released job's heartbeat no longer holds anything, and a second release is 409.
  assert.equal((await call(DB, `/${r.id}/heartbeat`, { method: 'POST', body: { job_id: 'J2' } })).status, 409);
  assert.equal((await release(DB, r.id, 'J2')).status, 409);
  // Any box can claim it at once, and the claim counts no reset.
  const c = await claim(DB, r.id, 'J3', 'box-c');
  assert.equal(c.status, 200, JSON.stringify(c.body));
  assert.equal(rowOf(db).reset_count ?? 0, resetsBefore);
});

test('B5. after a release, the first job finished review still lands', async () => {
  const { db, DB } = fresh();
  const r = await rebound(db, DB);
  assert.equal((await release(DB, r.id, 'J2')).status, 200);
  const late = await result(DB, r.id, 'J1');
  assert.equal(late.status, 200, JSON.stringify(late.body));
  assert.equal(rowOf(db).status, 'done');
  assert.equal(rowOf(db).job_id, 'J1');
});
