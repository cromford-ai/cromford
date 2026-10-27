// BH-8579 — POST /api/lead-reviews/reclaim-stale also releases a `running`
// lead review whose bound job ended failed (abandoned/budget_stopped go to
// failed, never requeued), resets a
// running row after lead_review.stale_running_min (seed 15) minutes with no
// heartbeat, caps the releases at lead_review.release_max_resets (seed 3) on
// stale_reclaims, and supersedes (never requeues) a row whose PR fact says
// closed/merged or a different head. Driven through worker.fetch against the
// composed schema.d (the bh-5779 idiom): every write is a compare-and-set, and
// only a real engine proves which one wins.
//   K1-K4 knobs, R1-R12 the release rule, C1-C3 the cap, H1-H7 the head
//   check, P1 the page bound and the query plan.
import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'test-secret';
const LEAD = 'lead-test-token';
const SCHEMA = jobsSchemaSql();

// `afterAll` (sql substring, fn) runs fn after an all() on a matching statement
// returns, so a test can move a row between the sweep's SELECT and its CAS.
// `log` collects every prepared SQL text, so a test can count statements.
function sqliteDB(db, afterAll = null, log = null) {
  const bindAndRun = (sql, binds) => ({
    first: async (col) => { const r = db.prepare(sql).get(...binds) ?? null; return col && r ? r[col] : r; },
    all: async () => {
      const results = db.prepare(sql).all(...binds);
      if (afterAll && sql.includes(afterAll.match)) afterAll.fn();
      return { results };
    },
    run: async () => {
      const r = db.prepare(sql).run(...binds);
      return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
    },
  });
  return {
    prepare: (sql) => {
      if (log) log.push(sql);
      return { ...bindAndRun(sql, []), bind: (...b) => bindAndRun(sql, b.map((v) => (v === undefined ? null : v))) };
    },
  };
}
const fresh = ({ afterAll = null, log = null } = {}) => {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  return { db, DB: sqliteDB(db, afterAll, log) };
};

const call = (DB, path, { method = 'GET', body, lead = false } = {}) => {
  const headers = { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' };
  if (lead) headers['x-lead-verdict-token'] = LEAD;
  const req = new Request(`https://jobs.test${path}`, { method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const REPO = 'example-org/project-6-os';
const PR = 2797;
const POOL = 'pool-project-6-os-83e12ef7d17118';
const uid = () => crypto.randomUUID();
const head = (c) => c.repeat(40);
const H1 = head('a');

const NOW = Date.now(); // determinism: ok the single anchor; the worker stamps claims and the sweep cutoff off the real clock, so every backdated age derives from this one read
const isoAgo = (s) => new Date(NOW - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const MIN = 60;

async function created(DB, head_sha = H1, pr = PR) {
  const res = await call(DB, '/api/lead-reviews', { method: 'POST', body: { repo: REPO, pr, head_sha, scope_notes: 'bh-8579' }, lead: true });
  assert.equal(res.status, 201, JSON.stringify(res.body));
  return res.body.request;
}
const claim = (DB, id, job_id, box = POOL) =>
  call(DB, `/api/lead-reviews/${id}/claim`, { method: 'POST', body: { job_id, box } });
const reclaim = (DB) => call(DB, '/api/lead-reviews/reclaim-stale', { method: 'POST', body: {}, lead: true });
const row = (db, id) => db.prepare('SELECT * FROM lead_review_requests WHERE id=?').get(id);
const beat = (db, id, s) => db.prepare('UPDATE lead_review_requests SET heartbeat_at=?1 WHERE id=?2').run(isoAgo(s), id);
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?1,?2,'test','test','2026-10-27T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, value);
const unset = (db, key) => db.prepare('DELETE FROM settings WHERE key=?').run(key);
// one jobs row; `ageS` is how long ago it last changed (its updated_at)
const job = (db, id, status, ageS, box = POOL, stage = 'review') => db.prepare(
  `INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at)
   VALUES (?1, 'project-6-os', 'lr-2797-aaaaaaaaaaaa', 'lead_review', ?2, ?3, ?4, ?5, ?5)`
).run(id, box, stage, status, isoAgo(ageS));
const fact = (db, { state = 'open', head_sha = H1, refreshedAgoS = 0, pr = PR, fields = true } = {}) => {
  const at = isoAgo(refreshedAgoS);
  db.prepare(`INSERT INTO pr_records (repo, number, state, head_sha, fields_at, created_at, refreshed_at)
              VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)`)
    .run(REPO, pr, state, head_sha, fields ? JSON.stringify({ state: at, head_sha: at }) : '{}', at);
};

// A running row held by `jobId` whose job is `status`, ended `jobAgeS` ago,
// and whose request heartbeat is `beatS` old. created_at is 30 min old.
async function bound(db, DB, { status = 'failed', jobAgeS = 20 * MIN, beatS = 21 * MIN, jobId = `job-f-${uid()}`, head_sha = H1, pr = PR, box = POOL } = {}) {
  const r = await created(DB, head_sha, pr);
  assert.equal((await claim(DB, r.id, jobId, box)).status, 200);
  db.prepare('UPDATE lead_review_requests SET created_at=?1 WHERE id=?2').run(isoAgo(30 * MIN), r.id);
  if (status !== null) job(db, jobId, status, jobAgeS, box);
  beat(db, r.id, beatS);
  return { ...row(db, r.id), jobId };
}

// ── K: the knobs ────────────────────────────────────────────────────────────
test('K1. the seeded rows give deadline_s 900 and cap 3 over lead_review_running_deadline_s 3600', async () => {
  const { db, DB } = fresh();
  assert.equal(db.prepare("SELECT value FROM settings WHERE key='lead_review.stale_running_min'").get()?.value, '15');
  assert.equal(db.prepare("SELECT value FROM settings WHERE key='lead_review.release_max_resets'").get()?.value, '3');
  assert.equal(db.prepare("SELECT value FROM settings WHERE key='lead_review_running_deadline_s'").get()?.value, '3600');
  const res = await reclaim(DB);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.deadline_s, 900);
  assert.equal(res.body.cap, 3);
});

test('K2. the new row absent: the old row 1800 is used; both absent: 900; a bad new row falls through; 5 min floors to 900', async () => {
  {
    const { db, DB } = fresh();
    unset(db, 'lead_review.stale_running_min');
    setting(db, 'lead_review_running_deadline_s', '1800');
    assert.equal((await reclaim(DB)).body.deadline_s, 1800);
  }
  {
    const { db, DB } = fresh();
    unset(db, 'lead_review.stale_running_min');
    unset(db, 'lead_review_running_deadline_s');
    assert.equal((await reclaim(DB)).body.deadline_s, 900);
  }
  for (const bad of ['0', '-1', 'abc', '1.5']) {
    const { db, DB } = fresh();
    setting(db, 'lead_review.stale_running_min', bad);
    setting(db, 'lead_review_running_deadline_s', '1800');
    assert.equal((await reclaim(DB)).body.deadline_s, 1800, `new row ${bad}`);
  }
  {
    const { db, DB } = fresh();
    setting(db, 'lead_review.stale_running_min', '5');
    assert.equal((await reclaim(DB)).body.deadline_s, 900, 'floored at lead_review_claim_stale_s fallback 900');
    setting(db, 'lead_review.stale_running_min', '20');
    assert.equal((await reclaim(DB)).body.deadline_s, 1200);
  }
});

test('K3. cap row 0: the first stale event goes to failed; cap row x: 3', async () => {
  {
    const { db, DB } = fresh();
    setting(db, 'lead_review.release_max_resets', '0');
    const r = await bound(db, DB);
    const res = await reclaim(DB);
    assert.equal(res.body.cap, 0);
    assert.equal(res.body.reclaimed.length, 1, JSON.stringify(res.body));
    assert.equal(res.body.reclaimed[0].to, 'failed');
    assert.equal(row(db, r.id).status, 'failed');
  }
  {
    const { db, DB } = fresh();
    setting(db, 'lead_review.release_max_resets', 'x');
    assert.equal((await reclaim(DB)).body.cap, 3);
  }
});

test('K4. the knob read is ONE settings statement', async () => {
  const log = [];
  const { db, DB } = fresh({ log });
  await bound(db, DB);
  log.length = 0;
  const res = await reclaim(DB);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  const reads = log.filter((s) => /FROM settings/i.test(s));
  assert.equal(reads.length, 1, reads.join('\n---\n'));
});

// ── R: the release rule ─────────────────────────────────────────────────────
test('R1. job failed 20 min ago, beat 21 min old → requested, reason job-failed, reset_count 1, stale_reclaims 1, job cleared', async () => {
  const { db, DB } = fresh();
  const r = await bound(db, DB, { jobId: 'job-f' });
  const res = await reclaim(DB);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.reclaimed.length, 1, JSON.stringify(res.body));
  const e = res.body.reclaimed[0];
  assert.equal(e.id, r.id);
  assert.equal(e.to, 'requested');
  assert.equal(e.reason, 'job-failed');
  assert.equal(e.job_id, 'job-f');
  assert.equal(e.releases, 1);
  assert.equal(e.cap, 3);
  assert.equal(e.last_beat, r.heartbeat_at);
  assert.equal(e.head_sha, H1);
  const now = row(db, r.id);
  assert.equal(now.status, 'requested');
  assert.match(now.detail, /^job failed: job job-f ended failed at stage review on pool-project-6-os-83e12ef7d17118 at \S+Z; no heartbeat since \S+Z$/);
  assert.equal(e.detail, now.detail);
  assert.equal(now.reset_count, 1);
  assert.equal(now.stale_reclaims, 1);
  assert.equal(now.job_id, null);
  assert.equal(now.box, null);
  assert.equal(now.heartbeat_at, null);
});

test('R1b. any placement: a participant (review-2) row with a failed job is released the same way', async () => {
  const { db, DB } = fresh();
  const r = await bound(db, DB, { box: 'participant:review-2' });
  db.prepare("UPDATE lead_review_requests SET participant='review-2' WHERE id=?").run(r.id);
  const res = await reclaim(DB);
  assert.equal(res.body.reclaimed.length, 1, JSON.stringify(res.body));
  assert.equal(res.body.reclaimed[0].reason, 'job-failed');
  assert.equal(row(db, r.id).participant, null);
  assert.equal(row(db, r.id).status, 'requested');
});

test('R2. beat 16 min old with a live job → requested, reason stale, detail names the beat and the box', async () => {
  const { db, DB } = fresh();
  const r = await bound(db, DB, { status: 'running', jobAgeS: 16 * MIN, beatS: 16 * MIN, jobId: 'job-live' });
  const res = await reclaim(DB);
  assert.equal(res.body.reclaimed.length, 1, JSON.stringify(res.body));
  assert.equal(res.body.reclaimed[0].reason, 'stale');
  assert.equal(res.body.reclaimed[0].to, 'requested');
  assert.equal(row(db, r.id).detail, `stale: running with no heartbeat since ${r.heartbeat_at} (job job-live, box ${POOL}); reclaimed after 900 s`);
});

test('R2b. a release keeps the queue position: created_at and priority unchanged', async () => {
  const { db, DB } = fresh();
  const r = await bound(db, DB);
  const before = row(db, r.id);
  assert.equal((await reclaim(DB)).body.reclaimed.length, 1);
  assert.equal(row(db, r.id).created_at, before.created_at);
  assert.equal(row(db, r.id).priority, before.priority);
});

test('R3. abandoned and budget_stopped jobs are terminal: failed at once, never requeued, under the cap', async () => {
  for (const status of ['abandoned', 'budget_stopped']) {
    const { db, DB } = fresh();
    const r = await bound(db, DB, { status, jobId: 'job-x' });
    const res = await reclaim(DB);
    assert.equal(res.body.reclaimed.length, 1, `${status}: ${JSON.stringify(res.body)}`);
    assert.equal(res.body.reclaimed[0].reason, 'job-terminal');
    assert.equal(res.body.reclaimed[0].to, 'failed');
    const after = row(db, r.id);
    assert.equal(after.status, 'failed', status);
    assert.equal(after.job_id, 'job-x', `${status}: job_id kept`);
    assert.equal(after.reset_count || 0, 0, `${status}: no reset recorded`);
    assert.match(after.detail, new RegExp(`^job terminal: job job-x ended ${status} at stage review .*; not requeued$`));
    // a second sweep does not touch the failed row
    assert.deepEqual((await reclaim(DB)).body.reclaimed, []);
    assert.equal(row(db, r.id).status, 'failed');
  }
});

test('R3b. a terminal job on the deadline path (a beat after the job end, then silence) → failed, not requested', async () => {
  for (const status of ['abandoned', 'budget_stopped']) {
    const { db, DB } = fresh();
    const r = await bound(db, DB, { status, jobAgeS: 40 * MIN, beatS: 20 * MIN, jobId: 'job-y' });
    const res = await reclaim(DB);
    assert.equal(res.body.reclaimed.length, 1, `${status}: ${JSON.stringify(res.body)}`);
    assert.equal(res.body.reclaimed[0].reason, 'job-terminal');
    assert.equal(row(db, r.id).status, 'failed', status);
  }
});

test('R4. beat NULL, updated_at 16 min old, no job (the #5282 shape) → requested, reason stale', async () => {
  const { db, DB } = fresh();
  const r = await created(DB);
  db.prepare("UPDATE lead_review_requests SET status='running', job_id=NULL, box=NULL, heartbeat_at=NULL, updated_at=?1 WHERE id=?2").run(isoAgo(16 * MIN), r.id);
  const res = await reclaim(DB);
  assert.equal(res.body.reclaimed.length, 1, JSON.stringify(res.body));
  assert.equal(res.body.reclaimed[0].reason, 'stale');
  assert.equal(row(db, r.id).status, 'requested');
});

test('R5. beat 14 min old with a live job → not listed, not changed', async () => {
  const { db, DB } = fresh();
  const r = await bound(db, DB, { status: 'running', jobAgeS: 14 * MIN, beatS: 14 * MIN });
  const before = row(db, r.id);
  const res = await reclaim(DB);
  assert.deepEqual(res.body.reclaimed, []);
  assert.deepEqual(row(db, r.id), before);
});

test('R6. a job failed 2 min ago (inside one beat interval) → not listed', async () => {
  const { db, DB } = fresh();
  const r = await bound(db, DB, { jobAgeS: 2 * MIN, beatS: 3 * MIN });
  const res = await reclaim(DB);
  assert.deepEqual(res.body.reclaimed, []);
  assert.equal(row(db, r.id).status, 'running');
});

test('R7. a request beat newer than the job end (a live worker) → not listed', async () => {
  const { db, DB } = fresh();
  const r = await bound(db, DB, { jobAgeS: 20 * MIN, beatS: 10 * MIN });
  const res = await reclaim(DB);
  assert.deepEqual(res.body.reclaimed, []);
  assert.equal(row(db, r.id).status, 'running');
});

test('R8. a heartbeat between the sweep SELECT and its CAS wins: not listed, the job is kept', async () => {
  let id = null;
  const hook = { match: 'lead_review_requests', fn: () => { if (id) db.prepare('UPDATE lead_review_requests SET heartbeat_at=?1 WHERE id=?2').run(isoAgo(5), id); } };
  const { db, DB } = fresh({ afterAll: hook });
  const r = await bound(db, DB, { jobId: 'job-r8' });
  id = r.id;
  const res = await reclaim(DB);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.deepEqual(res.body.reclaimed, []);
  const now = row(db, r.id);
  assert.equal(now.status, 'running');
  assert.equal(now.job_id, 'job-r8');
  assert.equal(now.stale_reclaims, null);
});

test('R9. queued_for_retry, orphaned, done and running jobs ended 8 min ago, beat 10 min old → not listed', async () => {
  for (const status of ['queued_for_retry', 'orphaned', 'done', 'running', 'parked']) {
    const { db, DB } = fresh();
    const r = await bound(db, DB, { status, jobAgeS: 8 * MIN, beatS: 10 * MIN });
    const res = await reclaim(DB);
    assert.deepEqual(res.body.reclaimed, [], status);
    assert.equal(row(db, r.id).status, 'running', status);
  }
  // the near miss without a jobs row at all, beat 5 min old
  const { db, DB } = fresh();
  const r = await bound(db, DB, { status: null, beatS: 5 * MIN });
  assert.deepEqual((await reclaim(DB)).body.reclaimed, []);
  assert.equal(row(db, r.id).status, 'running');
});

test('R9b. the same shape with a failed job IS released (the R9 control)', async () => {
  const { db, DB } = fresh();
  const r = await bound(db, DB, { status: 'failed', jobAgeS: 8 * MIN, beatS: 10 * MIN });
  assert.equal((await reclaim(DB)).body.reclaimed[0]?.reason, 'job-failed');
  assert.equal(row(db, r.id).status, 'requested');
});

test('R10. requested, done, failed and superseded rows with a failed job → untouched', async () => {
  const { db, DB } = fresh();
  const ids = [];
  for (const [i, status] of ['requested', 'done', 'failed', 'superseded'].entries()) {
    const jobId = `job-${uid()}`;
    const r = await created(DB, head('bcde'[i]));
    job(db, jobId, 'failed', 20 * MIN);
    db.prepare('UPDATE lead_review_requests SET status=?1, job_id=?2, heartbeat_at=?3, updated_at=?3 WHERE id=?4').run(status, jobId, isoAgo(21 * MIN), r.id);
    ids.push(r.id);
  }
  const before = ids.map((id) => row(db, id));
  const res = await reclaim(DB);
  assert.deepEqual(res.body.reclaimed, []);
  assert.deepEqual(ids.map((id) => row(db, id)), before);
});

test('R11. after a job-failed release, the old job /result and /heartbeat → 409', async () => {
  const { db, DB } = fresh();
  const r = await bound(db, DB, { jobId: 'job-old' });
  assert.equal((await reclaim(DB)).body.reclaimed.length, 1);
  const res = await call(DB, `/api/lead-reviews/${r.id}/result`, { method: 'POST', body: { job_id: 'job-old', head_sha: H1, outcome: 'done', verdict: 'MERGE' } });
  assert.equal(res.status, 409, JSON.stringify(res.body));
  const hb = await call(DB, `/api/lead-reviews/${r.id}/heartbeat`, { method: 'POST', body: { job_id: 'job-old' } });
  assert.equal(hb.status, 409, JSON.stringify(hb.body));
});

test('R12. a released row is started again by /start with a new job → 200 running', async () => {
  const { db, DB } = fresh();
  const r = await bound(db, DB);
  assert.equal((await reclaim(DB)).body.reclaimed.length, 1);
  const st = await call(DB, '/api/lead-reviews/start', { method: 'POST', body: { repo: REPO, pr: PR, head_sha: H1, job_id: 'job-new', box: 'box-b' } });
  assert.equal(st.status, 200, JSON.stringify(st.body));
  assert.equal(st.body.request.id, r.id);
  assert.equal(st.body.request.status, 'running');
  assert.equal(st.body.request.job_id, 'job-new');
});

// ── C: the cap ──────────────────────────────────────────────────────────────
// one failed-job event on row `id`: claim with a new job, the job fails, sweep
async function failOnce(db, DB, id) {
  const jobId = `job-${uid()}`;
  assert.equal((await claim(DB, id, jobId)).status, 200);
  job(db, jobId, 'failed', 20 * MIN);
  beat(db, id, 21 * MIN);
  return { res: await reclaim(DB), jobId };
}

test('C1+C2. cap 3: events 1..3 go to requested (stale_reclaims 1,2,3); the 4th goes to failed, job and detail kept, releases 4', async () => {
  const { db, DB } = fresh();
  const r = await created(DB);
  for (let k = 1; k <= 3; k++) {
    const { res } = await failOnce(db, DB, r.id);
    assert.equal(res.body.reclaimed.length, 1, JSON.stringify(res.body));
    assert.equal(res.body.reclaimed[0].to, 'requested', `event ${k}`);
    assert.equal(res.body.reclaimed[0].releases, k);
    assert.equal(row(db, r.id).stale_reclaims, k);
    assert.equal(row(db, r.id).reset_count, k);
  }
  const { res, jobId } = await failOnce(db, DB, r.id);
  assert.equal(res.body.reclaimed.length, 1, JSON.stringify(res.body));
  const e = res.body.reclaimed[0];
  assert.equal(e.to, 'failed');
  assert.equal(e.releases, 4);
  assert.equal(e.cap, 3);
  const now = row(db, r.id);
  assert.equal(now.status, 'failed');
  assert.equal(now.job_id, jobId);
  assert.equal(now.stale_reclaims, 4);
  assert.equal(now.reset_count, 3, 'a failed release is not a reset');
  assert.match(now.detail, /^job failed: job \S+ ended failed/);
  assert.equal(e.detail, now.detail);
});

test('C3. a cap-failed row reset by /reset and claimed fails again at the next event (bounded, no loop)', async () => {
  const { db, DB } = fresh();
  setting(db, 'lead_review.release_max_resets', '1');
  const r = await created(DB);
  assert.equal((await failOnce(db, DB, r.id)).res.body.reclaimed[0].to, 'requested');
  assert.equal((await failOnce(db, DB, r.id)).res.body.reclaimed[0].to, 'failed');
  const rs = await call(DB, `/api/lead-reviews/${r.id}/reset`, { method: 'POST', lead: true });
  assert.equal(rs.status, 200, JSON.stringify(rs.body));
  assert.equal((await failOnce(db, DB, r.id)).res.body.reclaimed[0].to, 'failed');
});

// ── H: the head check ───────────────────────────────────────────────────────
test('H1-H3. a newer fact that says closed, merged or another head → superseded, reset_count unchanged', async () => {
  for (const [name, f, detail, reason] of [
    ['closed', { state: 'closed' }, 'pr closed', 'pr-closed'],
    ['merged', { state: 'merged' }, 'pr closed', 'pr-closed'],
    ['moved', { head_sha: head('f') }, `head moved to ${'f'.repeat(12)}`, 'head-moved'],
  ]) {
    const { db, DB } = fresh();
    const r = await bound(db, DB, { jobId: 'job-h' });
    fact(db, { ...f, refreshedAgoS: 60 });
    const res = await reclaim(DB);
    assert.equal(res.body.reclaimed.length, 1, `${name}: ${JSON.stringify(res.body)}`);
    assert.equal(res.body.reclaimed[0].to, 'superseded', name);
    assert.equal(res.body.reclaimed[0].reason, reason, name);
    const now = row(db, r.id);
    assert.equal(now.status, 'superseded', name);
    assert.equal(now.detail, detail, name);
    assert.equal(now.reset_count, r.reset_count, name);
    assert.equal(now.job_id, 'job-h', `${name}: job kept`);
  }
});

test('H4. the same head in UPPERCASE → requested (a near miss)', async () => {
  const { db, DB } = fresh();
  await bound(db, DB);
  fact(db, { head_sha: H1.toUpperCase(), refreshedAgoS: 60 });
  assert.equal((await reclaim(DB)).body.reclaimed[0].to, 'requested');
});

test('H5. a fact older than the request (another head) → requested', async () => {
  const { db, DB } = fresh();
  await bound(db, DB);
  fact(db, { head_sha: head('f'), state: 'closed', refreshedAgoS: 60 * MIN });
  assert.equal((await reclaim(DB)).body.reclaimed[0].to, 'requested');
});

test('H5b. a fresh refresh whose head_sha field is older than the request → requested', async () => {
  const { db, DB } = fresh();
  await bound(db, DB);
  fact(db, { head_sha: head('f'), refreshedAgoS: 60 });
  db.prepare('UPDATE pr_records SET fields_at=?1').run(JSON.stringify({ head_sha: isoAgo(60 * MIN), state: isoAgo(60 * MIN) }));
  assert.equal((await reclaim(DB)).body.reclaimed[0].to, 'requested');
});

test('H6. no fact, or a fact with a NULL head and state open → requested', async () => {
  {
    const { db, DB } = fresh();
    await bound(db, DB);
    assert.equal((await reclaim(DB)).body.reclaimed[0].to, 'requested');
  }
  {
    const { db, DB } = fresh();
    await bound(db, DB);
    fact(db, { head_sha: null, refreshedAgoS: 60, fields: false });
    assert.equal((await reclaim(DB)).body.reclaimed[0].to, 'requested');
  }
});

test('H7. a row at the cap whose head moved → superseded, not failed', async () => {
  const { db, DB } = fresh();
  setting(db, 'lead_review.release_max_resets', '0');
  await bound(db, DB);
  fact(db, { head_sha: head('f'), refreshedAgoS: 60 });
  const e = (await reclaim(DB)).body.reclaimed[0];
  assert.equal(e.to, 'superseded');
  assert.equal(e.reason, 'head-moved');
});

// ── P: the page bound and the plan ──────────────────────────────────────────
test('P1. 101 eligible rows → 100 + truncated; the next call takes the last one', async () => {
  const { db, DB } = fresh();
  await reclaim(DB); // the guard self-creates the added columns before the raw insert below
  const ins = db.prepare(`INSERT INTO lead_review_requests (id, repo, pr, head_sha, status, job_id, box, created_at, updated_at, heartbeat_at)
                          VALUES (?1, ?2, ?3, ?4, 'running', ?5, 'box-a', ?6, ?6, ?6)`);
  for (let i = 0; i < 101; i++) ins.run(`lr-${String(i).padStart(3, '0')}`, REPO, 1000 + i, i.toString(16).padStart(40, '0'), `job-${i}`, isoAgo(90000 - i));
  const first = await reclaim(DB);
  assert.equal(first.body.reclaimed.length, 100);
  assert.equal(first.body.truncated, true);
  const second = await reclaim(DB);
  assert.deepEqual(second.body.reclaimed.map((x) => x.id), ['lr-100']);
  assert.equal(second.body.truncated, false);
});

test('P1b. EXPLAIN QUERY PLAN at seeded volume: every table is a SEARCH, no SCAN', async () => {
  const { RELEASE_SELECT_SQL } = await import('../src/lib/lead-review-release.js');
  const { db, DB } = fresh();
  await reclaim(DB);
  const insR = db.prepare(`INSERT INTO lead_review_requests (id, repo, pr, head_sha, status, job_id, created_at, updated_at, heartbeat_at)
                           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, ?7)`);
  const insJ = db.prepare(`INSERT INTO jobs (id, project, kind, box, stage, status, created_at, updated_at) VALUES (?1,'p','lead_review','b','review',?2,?3,?3)`);
  const insP = db.prepare(`INSERT INTO pr_records (repo, number, state, head_sha, created_at, refreshed_at) VALUES (?1, ?2, 'open', ?3, ?4, ?4)`);
  db.exec('BEGIN');
  for (let i = 0; i < 5000; i++) {
    insR.run(`r-${i}`, `o/r${i % 20}`, i, i.toString(16).padStart(40, '0'), i < 100 ? 'running' : 'done', `j-${i}`, isoAgo(i));
    insJ.run(`j-${i}`, i % 3 ? 'done' : 'failed', isoAgo(i));
    if (i < 2000) insP.run(`o/r${i % 20}`, i, i.toString(16).padStart(40, '0'), isoAgo(i));
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const plan = db.prepare(`EXPLAIN QUERY PLAN ${RELEASE_SELECT_SQL}`).all(isoAgo(900), isoAgo(300), 100).map((p) => p.detail);
  const txt = plan.join('\n');
  assert.match(txt, /SEARCH r USING INDEX idx_lead_review_requests_status/, txt);
  assert.match(txt, /SEARCH j USING INDEX sqlite_autoindex_jobs_1|SEARCH j USING PRIMARY KEY/, txt);
  assert.match(txt, /SEARCH p USING INDEX ux_pr_records_repo_number/, txt);
  assert.doesNotMatch(txt, /\bSCAN (r|j|p)\b/, txt);
});
