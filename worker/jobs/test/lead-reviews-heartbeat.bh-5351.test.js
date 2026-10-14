// BH-5351 (BH-5348.2) — a running lead review claim is held by a heartbeat, and
// a claim whose heartbeat went quiet past stale_s (the settings row
// lead_review_claim_stale_s, fallback 900) is taken by the next claimer. Driven
// through worker.fetch against the schema.sql that ships (the bh-1949 idiom):
// the claim is a compare-and-set, and only a real engine proves who wins.
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

test('H1. two box claimers on one requested row: exactly one 200; the winner stamps heartbeat_at = updated_at', async () => {
  const { db, DB } = fresh();
  const r = await created(DB);
  const [a, b] = await Promise.all([claim(DB, r.id, 'job-a', { box: 'box-a' }), claim(DB, r.id, 'job-b', { box: 'box-b' })]);
  assert.deepEqual([a.status, b.status].sort(), [200, 409]);
  const now = row(db, r.id);
  const winner = a.status === 200 ? 'job-a' : 'job-b';
  assert.equal(now.status, 'running');
  assert.equal(now.job_id, winner);
  assert.ok(now.heartbeat_at, 'claim stamps heartbeat_at');
  assert.equal(now.heartbeat_at, now.updated_at);
  assert.equal(now.participant, null);
});

test('H2. a second claimer while the holder is fresh → 409, the row keeps its holder', async () => {
  const { db, DB } = fresh();
  const r = await created(DB);
  assert.equal((await claim(DB, r.id, 'job-a')).status, 200);
  const second = await claim(DB, r.id, 'job-b', { box: 'box-b' });
  assert.equal(second.status, 409);
  assert.equal(row(db, r.id).job_id, 'job-a');
});

test('H3. stale_s=60: the holder heartbeats while updated_at is old; a second claimer → 409', async () => {
  const { db, DB } = fresh();
  setting(db, 'lead_review_claim_stale_s', '60');
  const r = await created(DB);
  assert.equal((await claim(DB, r.id, 'job-a')).status, 200);
  backdate(db, r.id, 600);
  const before = row(db, r.id);
  const hb = await beat(DB, r.id, 'job-a');
  assert.equal(hb.status, 200, JSON.stringify(hb.body));
  assert.equal(hb.body.request.id, r.id);
  const after = row(db, r.id);
  assert.ok(after.heartbeat_at > before.heartbeat_at, 'heartbeat_at moved');
  assert.equal(after.updated_at, before.updated_at, 'a heartbeat never touches updated_at');
  const second = await claim(DB, r.id, 'job-b', { box: 'box-b' });
  assert.equal(second.status, 409, JSON.stringify(second.body));
  assert.equal(row(db, r.id).job_id, 'job-a');
});

test('H4. a missed heartbeat: the second claimer wins, the first job is 409 on /result and /heartbeat', async () => {
  const { db, DB } = fresh();
  setting(db, 'lead_review_claim_stale_s', '60');
  const r = await created(DB);
  assert.equal((await claim(DB, r.id, 'job-a', { box: 'box-a' })).status, 200);
  backdate(db, r.id, 120);
  const second = await claim(DB, r.id, 'job-b', { box: 'box-b' });
  assert.equal(second.status, 200, JSON.stringify(second.body));
  assert.deepEqual(second.body.reclaimed_from, { job_id: 'job-a', box: 'box-a', participant: null });
  const now = row(db, r.id);
  assert.equal(now.job_id, 'job-b');
  assert.equal(now.box, 'box-b');
  assert.equal(now.status, 'running');
  const late = await result(DB, r.id, 'job-a');
  assert.equal(late.status, 409);
  assert.equal(late.body.error, 'job_id is not the job this request is bound to');
  const lateBeat = await beat(DB, r.id, 'job-a');
  assert.equal(lateBeat.status, 409);
  assert.match(lateBeat.body.error, /only the job that holds a running claim may heartbeat/);
  assert.equal(row(db, r.id).status, 'running');
  // and the new holder finishes it
  assert.equal((await result(DB, r.id, 'job-b')).status, 200);
});

test('H4b. the same job re-claiming its own stale row is 200 and not a reclaim', async () => {
  const { db, DB } = fresh();
  setting(db, 'lead_review_claim_stale_s', '60');
  const r = await created(DB);
  assert.equal((await claim(DB, r.id, 'job-a')).status, 200);
  backdate(db, r.id, 120);
  const again = await claim(DB, r.id, 'job-a');
  assert.equal(again.status, 200);
  assert.equal(again.body.reclaimed_from, undefined);
});

test('H5. heartbeat: a never-holder 409, a missing id 404, no job_id 400, a done row 409', async () => {
  const { db, DB } = fresh();
  const r = await created(DB);
  const onRequested = await beat(DB, r.id, 'job-a');
  assert.equal(onRequested.status, 409);
  assert.match(onRequested.body.error, /^lead review request is requested;/);
  assert.equal(row(db, r.id).heartbeat_at, null);
  assert.equal((await claim(DB, r.id, 'job-a')).status, 200);
  const stranger = await beat(DB, r.id, 'job-z');
  assert.equal(stranger.status, 409);
  assert.match(stranger.body.error, /lead review request is running \(job job-a\)/);
  const missing = await beat(DB, 'no-such-id', 'job-a');
  assert.equal(missing.status, 404);
  assert.equal(missing.body.error, 'no such lead review request');
  const noJob = await beat(DB, r.id);
  assert.equal(noJob.status, 400);
  assert.equal((await result(DB, r.id, 'job-a')).status, 200);
  const afterDone = await beat(DB, r.id, 'job-a');
  assert.equal(afterDone.status, 409);
  assert.match(afterDone.body.error, /^lead review request is done/);
});

test('H6. no settings row: the 900s fallback (600s quiet is held, 1000s quiet is taken)', async () => {
  const { db, DB } = fresh();
  db.prepare("DELETE FROM settings WHERE key='lead_review_claim_stale_s'").run();
  const r = await created(DB);
  assert.equal((await claim(DB, r.id, 'job-a')).status, 200);
  backdate(db, r.id, 600);
  assert.equal((await claim(DB, r.id, 'job-b', { box: 'box-b' })).status, 409);
  backdate(db, r.id, 1000);
  assert.equal((await claim(DB, r.id, 'job-b', { box: 'box-b' })).status, 200);
  assert.equal(row(db, r.id).job_id, 'job-b');
});

test('H6b. a junk settings value also falls back to 900, never to 0', async () => {
  const { db, DB } = fresh();
  setting(db, 'lead_review_claim_stale_s', 'soon');
  const r = await created(DB);
  assert.equal((await claim(DB, r.id, 'job-a')).status, 200);
  backdate(db, r.id, 600);
  assert.equal((await claim(DB, r.id, 'job-b', { box: 'box-b' })).status, 409);
});

test('H7. a row written before heartbeat_at existed falls back to updated_at', async () => {
  const { db, DB } = fresh();
  setting(db, 'lead_review_claim_stale_s', '60');
  const r = await created(DB);
  assert.equal((await claim(DB, r.id, 'job-a')).status, 200);
  db.prepare('UPDATE lead_review_requests SET heartbeat_at=NULL, updated_at=?1 WHERE id=?2').run(isoAgo(30), r.id);
  assert.equal((await claim(DB, r.id, 'job-b', { box: 'box-b' })).status, 409);
  db.prepare('UPDATE lead_review_requests SET heartbeat_at=NULL, updated_at=?1 WHERE id=?2').run(isoAgo(120), r.id);
  assert.equal((await claim(DB, r.id, 'job-b', { box: 'box-b' })).status, 200);
});

const start = (DB, job_id, opts = {}) =>
  call(DB, '/api/lead-reviews/start', { method: 'POST', body: { repo: REPO, pr: PR, head_sha: H1, job_id, box: 'box-s' }, ...opts });

test('H8. /start stamps heartbeat_at on create and on takeover; /start with x-participant-token is 403, no row change', async () => {
  const { db, DB } = fresh();
  const viaHeader = await start(DB, 'job-p', { token: 'some-participant-token-fixture' });
  assert.equal(viaHeader.status, 403, JSON.stringify(viaHeader.body));
  assert.equal(viaHeader.body.error, 'participant claims go through /claim');
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM lead_review_requests').get().n, 0);
  const s1 = await start(DB, 'job-s1');
  assert.equal(s1.status, 200, JSON.stringify(s1.body));
  const id = s1.body.request.id;
  assert.ok(row(db, id).heartbeat_at, '/start stamps heartbeat_at');
  assert.equal(row(db, id).heartbeat_at, row(db, id).updated_at);
  // an old heartbeat left from an earlier claim is re-stamped by a /start takeover
  db.prepare("UPDATE lead_review_requests SET status='superseded', heartbeat_at=?1, updated_at=?1 WHERE id=?2").run(isoAgo(5000), id);
  const s2 = await start(DB, 'job-s2');
  assert.equal(s2.status, 200, JSON.stringify(s2.body));
  const now = row(db, id);
  assert.equal(now.job_id, 'job-s2');
  assert.equal(now.heartbeat_at, now.updated_at);
  assert.ok(now.heartbeat_at > isoAgo(60));
  const blank = await start(DB, 'job-s3', { token: '' });
  assert.equal(blank.status, 403);
  assert.equal(row(db, id).job_id, 'job-s2');
});

test('H9. a stale reclaim of a running row is not a reset (BH-5400 reset_count unchanged)', async () => {
  const { db, DB } = fresh();
  setting(db, 'lead_review_claim_stale_s', '60');
  const r = await created(DB);
  assert.equal((await claim(DB, r.id, 'job-a')).status, 200);
  const before = row(db, r.id);
  backdate(db, r.id, 120);
  assert.equal((await claim(DB, r.id, 'job-b', { box: 'box-b' })).status, 200);
  const now = row(db, r.id);
  assert.equal(now.reset_count, before.reset_count);
  assert.equal(now.reset_at, before.reset_at);
});
