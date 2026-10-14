// BH-5351 (BH-5348.2) — separation of duties at lead review claim time: a
// claimer named in head_authors (recorded at create; bin/lead-review-enqueue.sh
// puts the build identity and the fix-round box/claimed_by there) is refused
// 409 `self-review refused`. The worker reads no fix-round table. Then
// each refusal writes one stage_events row verdict=sod_refused. A participant
// claim on a row with no recorded authorship fails closed; a box claim keeps
// today's behaviour, and box SoD runs only with settings lead_review_sod_boxes=1.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { createHash, randomBytes } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

const SECRET = 'test-secret';
const LEAD = 'lead-test-token';
const SCHEMA = jobsSchemaSql();

// `failOn` makes any statement whose SQL contains that text throw, so a test can
// break one write and watch the route's answer.
function sqliteDB(db, failOn = null) {
  const bindAndRun = (sql, binds) => {
    const boom = () => { if (failOn && sql.includes(failOn)) throw new Error(`injected failure on ${failOn}`); };
    return {
      first: async (col) => { boom(); const r = db.prepare(sql).get(...binds) ?? null; return col && r ? r[col] : r; },
      all: async () => { boom(); return { results: db.prepare(sql).all(...binds) }; },
      run: async () => {
        boom();
        const r = db.prepare(sql).run(...binds);
        return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
      },
    };
  };
  return {
    prepare: (sql) => ({ ...bindAndRun(sql, []), bind: (...b) => bindAndRun(sql, b.map((v) => (v === undefined ? null : v))) }),
  };
}
const fresh = (failOn = null) => { const db = new DatabaseSync(':memory:'); db.exec(SCHEMA); return { db, DB: sqliteDB(db, failOn) }; };

// Every call carries the bearer; `lead` adds the lead token, `token` the
// participant token (a string, blank included, means the header is sent).
const call = (DB, path, { method = 'GET', body, lead = false, token } = {}) => {
  const headers = { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' };
  if (lead) headers['x-lead-verdict-token'] = LEAD;
  if (token !== undefined) headers['x-participant-token'] = token;
  const req = new Request(`https://jobs.test${path}`, { method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const H1 = 'a'.repeat(40);
const REPO = 'example-org/cromford';
const PR = 5351;
const PR_URL = `https://github.com/${REPO}/pull/${PR}`;
const REQ = { repo: REPO, pr: PR, head_sha: H1, scope_notes: 'bh-5351' };

async function created(DB, over = {}) {
  const res = await call(DB, '/api/lead-reviews', { method: 'POST', body: { ...REQ, ...over }, lead: true });
  assert.equal(res.status, 201, JSON.stringify(res.body));
  return res.body.request;
}
const claim = (DB, id, job_id, { box = 'box-a', token } = {}) =>
  call(DB, `/api/lead-reviews/${id}/claim`, { method: 'POST', token, body: { job_id, ...(box === null ? {} : { box }) } });
const beat = (DB, id, job_id) => call(DB, `/api/lead-reviews/${id}/heartbeat`, { method: 'POST', body: job_id === undefined ? {} : { job_id } });
const result = (DB, id, job_id) =>
  call(DB, `/api/lead-reviews/${id}/result`, { method: 'POST', body: { job_id, head_sha: H1, outcome: 'done', verdict: 'MERGE' } });
const row = (db, id) => db.prepare('SELECT * FROM lead_review_requests WHERE id=?').get(id);
const NOW = Date.now(); // determinism: ok the single anchor; the worker stamps claims and staleness off the real clock, so every backdated age derives from this one read
const isoAgo = (s) => new Date(NOW - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const backdate = (db, id, s) => db.prepare('UPDATE lead_review_requests SET heartbeat_at=?1, updated_at=?1 WHERE id=?2').run(isoAgo(s), id);
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?1,?2,'test','test','2026-10-08T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, value);
const events = (db, verdict) => db.prepare('SELECT * FROM stage_events WHERE verdict=? ORDER BY id').all(verdict);

// An enrolled machine, seeded straight into participant_machines with the
// sha256 of a token the test holds.
function enrol(db, name, { status = 'approved', roles = ['lead-review'], knobs = null } = {}) {
  const raw = randomBytes(24).toString('hex');
  const sha = createHash('sha256').update(raw).digest('hex');
  db.prepare(`INSERT INTO participant_machines (id, name, requested_roles, granted_roles, token_sha256, status, requested_at, knobs)
              VALUES (?1,?2,?3,?4,?5,?6,'2026-10-08T00:00:00Z',?7)`)
    .run(`pm-${name}`, name, JSON.stringify(roles), status === 'pending' ? null : JSON.stringify(roles), sha, status, knobs);
  return raw;
}

test('S1. the author machine is refused 409 self-review refused, one sod_refused row, the row unchanged', async () => {
  const { db, DB } = fresh();
  const tok = enrol(db, 'mac-a');
  const r = await created(DB, { head_authors: ['Mac-A ', 'box-x'] });
  assert.deepEqual(JSON.parse(row(db, r.id).head_authors), ['mac-a', 'box-x']);
  const res = await claim(DB, r.id, 'job-a', { token: tok });
  assert.equal(res.status, 409, JSON.stringify(res.body));
  assert.equal(res.body.error, 'self-review refused');
  assert.equal(res.body.event_logged, true);
  const ev = events(db, 'sod_refused');
  assert.equal(ev.length, 1);
  assert.equal(ev[0].actor, 'participant:mac-a');
  assert.equal(ev[0].job_id, 'job-a');
  assert.equal(ev[0].stage, 'lead-review');
  const d = JSON.parse(ev[0].detail);
  assert.equal(d.request_id, r.id);
  assert.equal(d.repo, REPO);
  assert.equal(d.pr, PR);
  assert.equal(d.head_sha, H1);
  assert.equal(d.why, 'self-review refused');
  assert.equal(d.matched, 'mac-a');
  const now = row(db, r.id);
  assert.equal(now.status, 'requested');
  assert.equal(now.job_id, null);
});

test('S2. head_authors naming participant:mac-a also refuses participant mac-a', async () => {
  const { db, DB } = fresh();
  const tok = enrol(db, 'mac-a');
  const r = await created(DB, { head_authors: ['participant:mac-a'] });
  const res = await claim(DB, r.id, 'job-a', { token: tok });
  assert.equal(res.status, 409);
  assert.equal(res.body.error, 'self-review refused');
});

test('S3. a different enrolled machine claims the same row → 200', async () => {
  const { db, DB } = fresh();
  const a = enrol(db, 'mac-a');
  const b = enrol(db, 'mac-b');
  const r = await created(DB, { head_authors: ['Mac-A ', 'box-x'] });
  assert.equal((await claim(DB, r.id, 'job-a', { token: a })).status, 409);
  const res = await claim(DB, r.id, 'job-b', { token: b });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(row(db, r.id).participant, 'mac-b');
});

test('S4. a fix-rounder named in head_authors is refused: participant always, a box only with lead_review_sod_boxes=1', async () => {
  const { db, DB } = fresh();
  const c = enrol(db, 'mac-c');
  // bin/lead-review-enqueue.sh puts the fix-round box and claimed_by in head_authors.
  const r = await created(DB, { head_authors: ['box-x', 'participant:mac-c', 'fix-box-1'] });
  const pc = await claim(DB, r.id, 'job-c', { token: c });
  assert.equal(pc.status, 409, JSON.stringify(pc.body));
  assert.equal(pc.body.error, 'self-review refused');

  // box SoD off (row absent): the fix-round box claims, as today
  const r2 = await created(DB, { head_sha: '1'.repeat(40), head_authors: ['box-x', 'fix-box-1'] });
  assert.equal((await claim(DB, r2.id, 'job-f', { box: 'fix-box-1' })).status, 200);
  // box SoD on: fix-box-1 is refused with an event row, as is a box named in head_authors in another case
  setting(db, 'lead_review_sod_boxes', '1');
  const r3 = await created(DB, { head_sha: '2'.repeat(40), head_authors: ['box-x', 'fix-box-1'] });
  const bf = await claim(DB, r3.id, 'job-f2', { box: 'fix-box-1' });
  assert.equal(bf.status, 409, JSON.stringify(bf.body));
  assert.equal(bf.body.error, 'self-review refused');
  const bx = await claim(DB, r3.id, 'job-x', { box: 'BOX-X' });
  assert.equal(bx.status, 409);
  const ev = events(db, 'sod_refused');
  assert.equal(ev.length, 3);
  assert.equal(ev[1].actor, 'fix-box-1');
  assert.equal(JSON.parse(ev[1].detail).matched, 'fix-box-1');
  const ok = await claim(DB, r3.id, 'job-y', { box: 'box-y' });
  assert.equal(ok.status, 200);
});

test('S5. no head_authors: a participant fails closed `authorship unknown` with an event row; S5b a box claims', async () => {
  const { db, DB } = fresh();
  const tok = enrol(db, 'mac-b');
  const r = await created(DB);
  assert.equal(row(db, r.id).head_authors, null);
  const res = await claim(DB, r.id, 'job-p', { token: tok });
  assert.equal(res.status, 409);
  assert.equal(res.body.error, 'authorship unknown');
  const ev = events(db, 'sod_refused');
  assert.equal(ev.length, 1);
  assert.equal(JSON.parse(ev[0].detail).why, 'authorship unknown');
  assert.equal(row(db, r.id).status, 'requested');
  // unparseable authorship is unknown too
  db.prepare("UPDATE lead_review_requests SET head_authors='not json' WHERE id=?").run(r.id);
  assert.equal((await claim(DB, r.id, 'job-p', { token: tok })).body.error, 'authorship unknown');
  // S5b: a box claim, even with box SoD on, keeps today's behaviour
  setting(db, 'lead_review_sod_boxes', '1');
  db.prepare('UPDATE lead_review_requests SET head_authors=NULL WHERE id=?').run(r.id);
  assert.equal((await claim(DB, r.id, 'job-box', { box: 'box-a' })).status, 200);
});

test('S6. the event write fails: still 409, event_logged:false with the error, the row unchanged', async () => {
  const { db, DB } = fresh('INSERT INTO stage_events');
  const tok = enrol(db, 'mac-a');
  const r = await created(DB, { head_authors: ['mac-a'] });
  const res = await claim(DB, r.id, 'job-a', { token: tok });
  assert.equal(res.status, 409, JSON.stringify(res.body));
  assert.equal(res.body.error, 'self-review refused');
  assert.equal(res.body.event_logged, false);
  assert.match(res.body.event_error, /injected failure/);
  assert.equal(row(db, r.id).status, 'requested');
  // the participant refusal path says the same when its log fails
  const f = enrol(db, 'mac-f', { roles: ['fix'] });
  const pr = await claim(DB, r.id, 'job-f', { token: f });
  assert.equal(pr.status, 403);
  assert.equal(pr.body.event_logged, false);
});

test('S7. the worker reads no fix-round table: a fix_round_jobs row naming mac-a, not in head_authors, does not refuse', async () => {
  // Any statement naming fix_round_jobs throws: a claim that read it would be a 503.
  const { db, DB } = fresh('fix_round_jobs');
  db.prepare(
    `INSERT INTO fix_round_jobs (project, cap_key, box, args, status, claimed_by, enqueued_at, updated_at)
     VALUES ('cromford', 'cromford-BH-5351', 'participant:mac-a', ?1, 'done', 'mac-a', '2026-10-08T00:00:00Z', '2026-10-08T00:00:00Z')`
  ).run(JSON.stringify(['cromford', 'BH-5351', 'blocked', PR_URL, 'rec', 'BH-5351']));
  const tok = enrol(db, 'mac-a');
  const r = await created(DB, { head_authors: ['box-x'] });
  const res = await claim(DB, r.id, 'job-a', { token: tok });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(row(db, r.id).participant, 'mac-a');
});

test('S8. head_authors is validated, normalised, and filled only when the row has none', async () => {
  const { db, DB } = fresh();
  for (const bad of ['mac-a', [], Array.from({ length: 17 }, (_, i) => `b${i}`), [''], ['   '], ['x'.repeat(129)], [7]]) {
    const res = await call(DB, '/api/lead-reviews', { method: 'POST', body: { ...REQ, head_authors: bad }, lead: true });
    assert.equal(res.status, 400, JSON.stringify(bad));
    assert.match(res.body.error, /head_authors/);
  }
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM lead_review_requests').get().n, 0);
  const r = await created(DB);
  assert.equal(row(db, r.id).head_authors, null);
  const fill = await call(DB, '/api/lead-reviews', { method: 'POST', body: { ...REQ, head_authors: ['B', 'b ', 'a'] }, lead: true });
  assert.equal(fill.status, 200);
  assert.equal(fill.body.existing, true);
  assert.deepEqual(JSON.parse(row(db, r.id).head_authors), ['b', 'a']);
  assert.deepEqual(JSON.parse(fill.body.request.head_authors), ['b', 'a']);
  const keep = await call(DB, '/api/lead-reviews', { method: 'POST', body: { ...REQ, head_authors: ['z'] }, lead: true });
  assert.equal(keep.status, 200);
  assert.deepEqual(JSON.parse(row(db, r.id).head_authors), ['b', 'a']);
  // absent is today: no change, still 200 existing
  const absent = await call(DB, '/api/lead-reviews', { method: 'POST', body: REQ, lead: true });
  assert.equal(absent.status, 200);
  assert.deepEqual(JSON.parse(row(db, r.id).head_authors), ['b', 'a']);
});
