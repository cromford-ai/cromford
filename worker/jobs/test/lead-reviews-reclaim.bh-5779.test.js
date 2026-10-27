// BH-5779 — POST /api/lead-reviews/reclaim-stale sends a `running` lead review
// whose heartbeat went quiet past the deadline (settings
// lead_review_running_deadline_s, fallback 900 since BH-8579, floored at
// lead_review_claim_stale_s) back to `requested` the first time and to
// `failed` (detail `stale: ...`) the second time. Driven through worker.fetch
// against the schema.sql that ships (the bh-5351 idiom): the reclaim is a
// compare-and-set, and only a real engine proves which write wins.
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
function sqliteDB(db, afterAll = null) {
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
    prepare: (sql) => ({ ...bindAndRun(sql, []), bind: (...b) => bindAndRun(sql, b.map((v) => (v === undefined ? null : v))) }),
  };
}
// TEST-CHANGE (BH-8579): the two new seed rows are deleted, so every W case
// keeps reading lead_review_running_deadline_s (seed 3600) and W5 pins the
// cap of 1 it was written for. lead-reviews-release.bh-8579.test.js covers
// the seeded rows.
const fresh = (afterAll = null) => {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  db.exec("DELETE FROM settings WHERE key IN ('lead_review.stale_running_min','lead_review.release_max_resets')");
  return { db, DB: sqliteDB(db, afterAll) };
};

const call = (DB, path, { method = 'GET', body, lead = false } = {}) => {
  const headers = { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' };
  if (lead) headers['x-lead-verdict-token'] = LEAD;
  const req = new Request(`https://jobs.test${path}`, { method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const REPO = 'example-org/cromford';
const PR = 5779;
const H1 = 'a'.repeat(40);
const head = (c) => c.repeat(40);

async function created(DB, head_sha = H1) {
  const res = await call(DB, '/api/lead-reviews', { method: 'POST', body: { repo: REPO, pr: PR, head_sha, scope_notes: 'bh-5779' }, lead: true });
  assert.equal(res.status, 201, JSON.stringify(res.body));
  return res.body.request;
}
const claim = (DB, id, job_id, box = 'box-a') =>
  call(DB, `/api/lead-reviews/${id}/claim`, { method: 'POST', body: { job_id, box } });
const reclaim = (DB, lead = true) => call(DB, '/api/lead-reviews/reclaim-stale', { method: 'POST', body: {}, lead });
const row = (db, id) => db.prepare('SELECT * FROM lead_review_requests WHERE id=?').get(id);
const NOW = Date.now(); // determinism: ok the single anchor; the worker stamps claims and the sweep cutoff off the real clock, so every backdated age derives from this one read
const isoAgo = (s) => new Date(NOW - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const backdate = (db, id, beatS, updS = beatS) =>
  db.prepare('UPDATE lead_review_requests SET heartbeat_at=?1, updated_at=?2 WHERE id=?3')
    .run(beatS === null ? null : isoAgo(beatS), isoAgo(updS), id);
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?1,?2,'test','test','2026-10-09T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, value);

// A claimed row whose heartbeat is `ageS` seconds old.
async function staleRunning(db, DB, ageS, job = 'job-1', head_sha = H1) {
  const r = await created(DB, head_sha);
  assert.equal((await claim(DB, r.id, job)).status, 200);
  backdate(db, r.id, ageS);
  return r;
}

test('W1. no lead token → 403; with it, an empty table → 200 {reclaimed:[], deadline_s:3600}', async () => {
  const { DB } = fresh();
  const no = await reclaim(DB, false);
  assert.equal(no.status, 403, JSON.stringify(no.body));
  assert.match(no.body.error, /^reclaiming stale lead reviews needs the lead verdict token/);
  const ok = await reclaim(DB);
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.deepEqual(ok.body.reclaimed, []);
  assert.equal(ok.body.deadline_s, 3600);
  assert.equal(ok.body.truncated, false);
  assert.ok(ok.body.as_of, 'as_of is stamped');
});

test('W2. running, job-1, heartbeat 2 h old → requested; job, beat, box cleared; reset_count 1, stale_reclaims 1, detail stale:', async () => {
  const { db, DB } = fresh();
  const r = await staleRunning(db, DB, 7200);
  const beat = row(db, r.id).heartbeat_at;
  const res = await reclaim(DB);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.reclaimed.length, 1);
  // TEST-CHANGE (BH-8579): the entry gained reason, detail, releases and cap; the old fields are unchanged.
  assert.deepEqual(res.body.reclaimed[0], { id: r.id, repo: REPO, pr: PR, head_sha: H1, to: 'requested', last_beat: beat, job_id: 'job-1',
    reason: 'stale', detail: `stale: running with no heartbeat since ${beat} (job job-1, box box-a); reclaimed after 3600 s`, releases: 1, cap: 3 });
  const now = row(db, r.id);
  assert.equal(now.status, 'requested');
  assert.equal(now.job_id, null);
  assert.equal(now.box, null);
  assert.equal(now.participant, null);
  assert.equal(now.heartbeat_at, null);
  assert.equal(now.reset_count, 1);
  assert.equal(now.reset_at, res.body.as_of);
  assert.equal(now.stale_reclaims, 1);
  assert.equal(now.detail, `stale: running with no heartbeat since ${beat} (job job-1, box box-a); reclaimed after 3600 s`);
});

test('W3. a 60 s old heartbeat on a 2 h old updated_at → not listed, not changed', async () => {
  const { db, DB } = fresh();
  const r = await staleRunning(db, DB, 60);
  backdate(db, r.id, 60, 7200);
  const before = row(db, r.id);
  const res = await reclaim(DB);
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.reclaimed, []);
  assert.deepEqual(row(db, r.id), before);
});

test('W4. running with heartbeat_at NULL, job_id NULL, updated_at 2 h old (the #5282 shape) → requested', async () => {
  const { db, DB } = fresh();
  const r = await created(DB);
  db.prepare("UPDATE lead_review_requests SET status='running', job_id=NULL, box=NULL WHERE id=?").run(r.id);
  backdate(db, r.id, null, 7200);
  const res = await reclaim(DB);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.reclaimed.length, 1);
  assert.equal(res.body.reclaimed[0].to, 'requested');
  assert.equal(res.body.reclaimed[0].job_id, null);
  assert.equal(res.body.reclaimed[0].last_beat, isoAgo(7200));
  const now = row(db, r.id);
  assert.equal(now.status, 'requested');
  assert.equal(now.stale_reclaims, 1);
  assert.match(now.detail, /^stale: running with no heartbeat since \S+ \(job none, box none\); reclaimed after 3600 s$/);
});

test('W5. the same row stale a second time → failed, detail stale:, stale_reclaims 2, job_id kept', async () => {
  const { db, DB } = fresh();
  setting(db, 'lead_review.release_max_resets', '1'); // TEST-CHANGE (BH-8579): the cap of 1 this case pins is now a settings row (seed 3)
  const r = await staleRunning(db, DB, 7200, 'job-1');
  assert.equal((await reclaim(DB)).body.reclaimed[0].to, 'requested');
  assert.equal((await claim(DB, r.id, 'job-2', 'box-b')).status, 200);
  backdate(db, r.id, 7200);
  const resetCount = row(db, r.id).reset_count;
  const res = await reclaim(DB);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.reclaimed.length, 1);
  assert.equal(res.body.reclaimed[0].to, 'failed');
  assert.equal(res.body.reclaimed[0].job_id, 'job-2');
  const now = row(db, r.id);
  assert.equal(now.status, 'failed');
  assert.match(now.detail, /^stale: running with no heartbeat since \S+ \(job job-2, box box-b\); reclaimed after 3600 s$/);
  assert.equal(now.stale_reclaims, 2);
  assert.equal(now.job_id, 'job-2');
  assert.equal(now.reset_count, resetCount, 'a failed reclaim is not a reset');
  // a failed row is finished, so /reset (the enqueue's retry ladder) takes it
  const rs = await call(DB, `/api/lead-reviews/${r.id}/reset`, { method: 'POST', lead: true });
  assert.equal(rs.status, 200, JSON.stringify(rs.body));
  assert.equal(rs.body.request.status, 'requested');
});

test('W6. deadline 60 is floored at lead_review_claim_stale_s 900: a 300 s quiet row stays; a 1000 s quiet row goes', async () => {
  const { db, DB } = fresh();
  setting(db, 'lead_review_running_deadline_s', '60');
  setting(db, 'lead_review_claim_stale_s', '900');
  const quiet = await staleRunning(db, DB, 300, 'job-q', head('b'));
  const old = await staleRunning(db, DB, 1000, 'job-o', head('c'));
  const res = await reclaim(DB);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.deadline_s, 900);
  assert.deepEqual(res.body.reclaimed.map((x) => x.id), [old.id]);
  assert.equal(row(db, quiet.id).status, 'running');
  assert.equal(row(db, quiet.id).job_id, 'job-q');
  assert.match(row(db, old.id).detail, /reclaimed after 900 s$/);
});

test('W6b. a deadline above the floor is used as set', async () => {
  const { db, DB } = fresh();
  setting(db, 'lead_review_running_deadline_s', '1800');
  const quiet = await staleRunning(db, DB, 1200, 'job-q', head('b'));
  const old = await staleRunning(db, DB, 2000, 'job-o', head('c'));
  const res = await reclaim(DB);
  assert.equal(res.body.deadline_s, 1800);
  assert.deepEqual(res.body.reclaimed.map((x) => x.id), [old.id]);
  assert.equal(row(db, quiet.id).status, 'running');
});

// TEST-CHANGE (BH-8579): the code fallback is now 15 min (LEAD_REVIEW_STALE_RUNNING_MIN_FALLBACK,
// the ticket's number), not 3600 s. A bad old row with no new row uses 900, so a
// 2000 s quiet row is reclaimed and a 300 s one stays.
test('W7. a setting that is not a positive integer uses the fallback 900', async () => {
  for (const bad of ['abc', '0', '-5', '1.5']) {
    const { db, DB } = fresh();
    setting(db, 'lead_review_running_deadline_s', bad);
    const r = await staleRunning(db, DB, 2000);
    const quiet = await staleRunning(db, DB, 300, 'job-q', head('b'));
    const res = await reclaim(DB);
    assert.equal(res.status, 200, JSON.stringify(res.body));
    assert.equal(res.body.deadline_s, 900, `value ${bad}`);
    assert.deepEqual(res.body.reclaimed.map((x) => x.id), [r.id], `value ${bad}: 2000 s is over the fallback, 300 s is under it`);
    assert.equal(row(db, quiet.id).status, 'running');
  }
});

test('W8. after a reclaim, the old job-1 /result and /heartbeat → 409', async () => {
  const { db, DB } = fresh();
  const r = await staleRunning(db, DB, 7200, 'job-1');
  assert.equal((await reclaim(DB)).body.reclaimed.length, 1);
  const res = await call(DB, `/api/lead-reviews/${r.id}/result`, { method: 'POST', body: { job_id: 'job-1', head_sha: H1, outcome: 'done', verdict: 'MERGE' } });
  assert.equal(res.status, 409, JSON.stringify(res.body));
  const hb = await call(DB, `/api/lead-reviews/${r.id}/heartbeat`, { method: 'POST', body: { job_id: 'job-1' } });
  assert.equal(hb.status, 409, JSON.stringify(hb.body));
  assert.equal(row(db, r.id).status, 'requested');
  assert.equal(row(db, r.id).verdict, null);
});

test('W9. requested, done, failed and superseded rows of any age → untouched', async () => {
  const { db, DB } = fresh();
  const ids = [];
  for (const [i, status] of ['requested', 'done', 'failed', 'superseded'].entries()) {
    const r = await created(DB, head('bcde'[i]));
    db.prepare("UPDATE lead_review_requests SET status=?1, job_id='job-x', verdict=CASE WHEN ?1='done' THEN 'MERGE' ELSE NULL END WHERE id=?2").run(status, r.id);
    backdate(db, r.id, 86400 * 3);
    ids.push(r.id);
  }
  const before = ids.map((id) => row(db, id));
  const res = await reclaim(DB);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.deepEqual(res.body.reclaimed, []);
  assert.deepEqual(ids.map((id) => row(db, id)), before);
});

test('W10. a heartbeat that lands between the sweep SELECT and its CAS wins: the row is not listed and keeps its job', async () => {
  let id = null;
  const hook = { match: 'stale_reclaims', fn: () => { if (id) beatNow(); } };
  const { db, DB } = fresh(hook);
  const beatNow = () => db.prepare('UPDATE lead_review_requests SET heartbeat_at=?1 WHERE id=?2').run(isoAgo(5), id);
  const r = await staleRunning(db, DB, 7200, 'job-1');
  id = r.id;
  const res = await reclaim(DB);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.deepEqual(res.body.reclaimed, []);
  const now = row(db, r.id);
  assert.equal(now.status, 'running');
  assert.equal(now.job_id, 'job-1');
  assert.equal(now.stale_reclaims, null);
});

test('W11. 101 stale rows → 100 reclaimed, truncated true, oldest first; the next call takes the last one', async () => {
  const { db, DB } = fresh();
  await reclaim(DB); // the guard self-creates the added columns before the raw insert below
  const ins = db.prepare(`INSERT INTO lead_review_requests (id, repo, pr, head_sha, status, job_id, box, created_at, updated_at, heartbeat_at)
                          VALUES (?1, ?2, ?3, ?4, 'running', ?5, 'box-a', ?6, ?6, ?6)`);
  for (let i = 0; i < 101; i++) {
    ins.run(`lr-${String(i).padStart(3, '0')}`, REPO, 1000 + i, i.toString(16).padStart(40, '0'), `job-${i}`, isoAgo(90000 - i));
  }
  const first = await reclaim(DB);
  assert.equal(first.status, 200, JSON.stringify(first.body).slice(0, 500));
  assert.equal(first.body.reclaimed.length, 100);
  assert.equal(first.body.truncated, true);
  assert.equal(first.body.reclaimed[0].id, 'lr-000');
  assert.equal(row(db, 'lr-100').status, 'running');
  const second = await reclaim(DB);
  assert.deepEqual(second.body.reclaimed.map((x) => x.id), ['lr-100']);
  assert.equal(second.body.truncated, false);
});
