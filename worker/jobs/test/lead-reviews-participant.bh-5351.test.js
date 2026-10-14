// BH-5351 (BH-5348.2) — a lead review claim carrying x-participant-token is an
// enrolled machine's claim: participantAuth(req, env, 'lead-review') decides it,
// a refusal changes no row and logs one participant_refused stage_events row,
// and an approved claim is recorded as participant=<name>, box=participant:<name>.
// A claim with no participant header is the bearer box claim, unchanged.
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

const untouched = (db, id) => {
  const r = row(db, id);
  assert.equal(r.status, 'requested');
  assert.equal(r.job_id, null);
  assert.equal(r.box, null);
  assert.equal(r.participant, null);
};

test('P1. an approved lead-review participant claims: participant=mac-b, box=participant:mac-b, last_seen_at stamped', async () => {
  const { db, DB } = fresh();
  const tok = enrol(db, 'mac-b');
  const r = await created(DB, { head_authors: ['box-small'] });
  const res = await claim(DB, r.id, 'job-p', { box: null, token: tok });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  const now = row(db, r.id);
  assert.equal(now.status, 'running');
  assert.equal(now.participant, 'mac-b');
  assert.equal(now.box, 'participant:mac-b');
  assert.equal(now.job_id, 'job-p');
  assert.ok(now.heartbeat_at);
  assert.ok(db.prepare("SELECT last_seen_at FROM participant_machines WHERE name='mac-b'").get().last_seen_at);
  // a body box is ignored on a participant claim
  const r2 = await created(DB, { head_sha: 'c'.repeat(40), head_authors: ['box-small'] });
  assert.equal((await claim(DB, r2.id, 'job-q', { box: 'box-spoof', token: tok })).status, 200);
  assert.equal(row(db, r2.id).box, 'participant:mac-b');
});

test('P2. an approved fix-only participant → 403 role lead-review not granted, no row change, one participant_refused row', async () => {
  const { db, DB } = fresh();
  const tok = enrol(db, 'mac-f', { roles: ['fix'] });
  const r = await created(DB, { head_authors: ['box-small'] });
  const res = await claim(DB, r.id, 'job-p', { token: tok });
  assert.equal(res.status, 403);
  assert.equal(res.body.error, 'role lead-review not granted');
  untouched(db, r.id);
  const ev = events(db, 'participant_refused');
  assert.equal(ev.length, 1);
  assert.equal(ev[0].job_id, 'job-p');
  assert.equal(ev[0].stage, 'lead-review');
  assert.equal(ev[0].actor, 'participant:?');
  assert.equal(JSON.parse(ev[0].detail).why, 'role lead-review not granted');
});

test('P3. revoked, pending and denied participants → 403 naming why, no row change', async () => {
  const { db, DB } = fresh();
  const r = await created(DB, { head_authors: ['box-small'] });
  for (const status of ['revoked', 'pending', 'denied']) {
    const tok = enrol(db, `mac-${status}`, { status });
    const res = await claim(DB, r.id, `job-${status}`, { token: tok });
    assert.equal(res.status, 403, status);
    assert.equal(res.body.error, `participant is ${status}`);
    untouched(db, r.id);
  }
});

test('P4. a blank participant header → 401 and an unknown token → 403; never a box claim', async () => {
  const { db, DB } = fresh();
  const r = await created(DB, { head_authors: ['box-small'] });
  const blank = await claim(DB, r.id, 'job-p', { token: '   ' });
  assert.equal(blank.status, 401);
  assert.equal(blank.body.error, 'needs x-participant-token');
  untouched(db, r.id);
  const unknown = await claim(DB, r.id, 'job-p', { token: 'not-a-real-token' });
  assert.equal(unknown.status, 403);
  assert.equal(unknown.body.error, 'unknown participant token');
  untouched(db, r.id);
});

test('P5. a bearer box claim is unchanged, and a box reclaiming a stale participant row clears participant', async () => {
  const { db, DB } = fresh();
  setting(db, 'lead_review_claim_stale_s', '60');
  const r = await created(DB);
  const box = await claim(DB, r.id, 'job-box', { box: 'box-a' });
  assert.equal(box.status, 200);
  assert.equal(row(db, r.id).box, 'box-a');
  assert.equal(row(db, r.id).participant, null);

  const tok = enrol(db, 'mac-b');
  const r2 = await created(DB, { head_sha: 'd'.repeat(40), head_authors: ['box-small'] });
  assert.equal((await claim(DB, r2.id, 'job-p', { token: tok })).status, 200);
  backdate(db, r2.id, 120);
  const taken = await claim(DB, r2.id, 'job-box2', { box: 'box-c' });
  assert.equal(taken.status, 200, JSON.stringify(taken.body));
  assert.deepEqual(taken.body.reclaimed_from, { job_id: 'job-p', box: 'participant:mac-b', participant: 'mac-b' });
  const now = row(db, r2.id);
  assert.equal(now.box, 'box-c');
  assert.equal(now.participant, null);
  assert.equal(now.job_id, 'job-box2');
  // the participant's late result is refused
  assert.equal((await result(DB, r2.id, 'job-p')).status, 409);
});

test('P6. a participant claim needs no body box; a box claim without one is still 400', async () => {
  const { db, DB } = fresh();
  const r = await created(DB);
  const noBox = await claim(DB, r.id, 'job-box', { box: null });
  assert.equal(noBox.status, 400);
  assert.equal(noBox.body.error, 'box must be a string, 1..64 chars');
  const tok = enrol(db, 'mac-b');
  const r2 = await created(DB, { head_sha: 'e'.repeat(40), head_authors: ['box-small'] });
  assert.equal((await claim(DB, r2.id, 'job-p', { box: null, token: tok })).status, 200);
});
