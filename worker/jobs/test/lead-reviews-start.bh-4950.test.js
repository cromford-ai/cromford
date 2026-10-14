import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-4955 (BH-4950.2) — POST /api/lead-reviews/start: a box creates or takes
// over its own lead review row with the bearer alone, and a `running` row whose
// job died (the #4025 wedge) is taken over instead of 409ing every new job
// forever. Driven through worker.fetch against THE SQL THAT SHIPS
// (worker/jobs/schema.sql): the takeover is a compare-and-set, and only a real
// engine can prove a racing starter loses.
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

// Every call carries the bearer unless `bearer: false`; the lead token only when `lead: true`.
const call = (DB, path, { method = 'GET', body, lead = false, bearer = true } = {}) => {
  const req = new Request(`https://jobs.test/api/lead-reviews${path}`, {
    method,
    headers: {
      ...(bearer ? { authorization: `Bearer ${SECRET}` } : {}),
      ...(lead ? { 'x-lead-verdict-token': LEAD } : {}),
      'content-type': 'application/json',
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET, LEAD_VERDICT_TOKEN: LEAD })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const H1 = 'a'.repeat(40);
const REPO = 'example-org/cromford';
const BASE = { repo: REPO, pr: 4955, head_sha: H1 };
const start = (DB, job_id, box = 'box-1', over = {}, opts = {}) =>
  call(DB, '/start', { method: 'POST', body: { ...BASE, job_id, box, ...over }, ...opts });
const claim = (DB, id, job_id, box = 'box-2') => call(DB, `/${id}/claim`, { method: 'POST', body: { job_id, box } });
const result = (DB, id, body) => call(DB, `/${id}/result`, { method: 'POST', body: { head_sha: H1, ...body } });
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM lead_review_requests').get().n;
const rowOf = (db) => db.prepare('SELECT * FROM lead_review_requests WHERE repo=? AND pr=? AND head_sha=?').get(REPO, 4955, H1);

// The worker reads its own clock for the staleness cut, so the fixtures are aged
// off one anchor captured at load; every age below is tens of seconds off a
// threshold, far wider than the suite's run time.
const ANCHOR = Date.now();  // determinism: ok the single anchor every aged fixture is derived from
const ago = (s) => new Date(ANCHOR - s * 1000).toISOString();
// seedJob — a jobs row (and a heartbeat when beatAgoS is given), stamped relative to ANCHOR.
function seedJob(db, id, status, { updatedAgoS = 60, beatAgoS } = {}) {
  db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at)
              VALUES (?,?,?,?,?,?,?,?,?)`)
    .run(id, 'cromford', 'BH-4955', 'review', 'box-0', 'review', status, ago(updatedAgoS + 60), ago(updatedAgoS));
  if (beatAgoS !== undefined) db.prepare('INSERT INTO job_heartbeats (job_id, beat_at, box) VALUES (?,?,?)').run(id, ago(beatAgoS), 'box-0');
}
// seedRunning — the row a dead lane leaves behind: running, held by job_id.
async function seedRunning(db, DB, job_id) {
  const res = await start(DB, job_id, 'box-0');
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(rowOf(db).job_id, job_id);
  return res.body.request;
}

test('A1. create on a new head: 200 created:true, running for the caller, requested_by defaults to lead-review:<box>', async () => {
  const { db, DB } = fresh();
  seedJob(db, 'J1', 'running', { beatAgoS: 10 });
  const res = await start(DB, 'J1');
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.created, true);
  assert.equal(res.body.request.status, 'running');
  assert.equal(res.body.request.job_id, 'J1');
  assert.equal(res.body.request.box, 'box-1');
  assert.equal(res.body.request.requested_by, 'lead-review:box-1');
  assert.equal(res.body.request.head_sha, H1);
  assert.equal(count(db), 1);
});

test('A2. start an existing requested row: same id, created:false, its scope_notes and requested_by kept', async () => {
  const { db, DB } = fresh();
  const made = await call(DB, '', { method: 'POST', lead: true, body: { ...BASE, scope_notes: 'the router', requested_by: 'lead' } });
  assert.equal(made.status, 201, JSON.stringify(made.body));
  const res = await start(DB, 'J1', 'box-1', { scope_notes: 'something else' });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.created, false);
  assert.equal(res.body.request.id, made.body.request.id);
  assert.equal(res.body.request.status, 'running');
  assert.equal(res.body.request.job_id, 'J1');
  assert.equal(res.body.request.scope_notes, 'the router');
  assert.equal(res.body.request.requested_by, 'lead');
  assert.equal(count(db), 1);
});

test('A3. the #4025 shape: running row held by a FAILED job is taken over by the new job', async () => {
  const { db, DB } = fresh();
  seedJob(db, 'J1', 'running', { beatAgoS: 5 });
  await seedRunning(db, DB, 'J1');
  db.prepare("UPDATE jobs SET status='failed' WHERE id='J1'").run();
  seedJob(db, 'J2', 'running', { beatAgoS: 5 });
  const res = await start(DB, 'J2', 'box-2');
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.created, false);
  const row = rowOf(db);
  assert.equal(row.status, 'running');
  assert.equal(row.job_id, 'J2');
  assert.equal(row.box, 'box-2');
});

test('A4. running row held by a running job silent for 20 minutes is taken over', async () => {
  const { db, DB } = fresh();
  seedJob(db, 'J1', 'running', { beatAgoS: 5 });
  await seedRunning(db, DB, 'J1');
  db.prepare('UPDATE jobs SET updated_at=? WHERE id=?').run(ago(20 * 60), 'J1');
  db.prepare('UPDATE job_heartbeats SET beat_at=? WHERE job_id=?').run(ago(20 * 60), 'J1');
  const res = await start(DB, 'J2', 'box-2');
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(rowOf(db).job_id, 'J2');
});

test('A4b. running row whose job has no jobs row at all is taken over', async () => {
  const { db, DB } = fresh();
  await seedRunning(db, DB, 'ghost');
  const res = await start(DB, 'J2', 'box-2');
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(rowOf(db).job_id, 'J2');
});

test('A5. refuse when the holder is live: a beat 1 min ago counts even with updated_at 30 min old', async () => {
  const { db, DB } = fresh();
  await seedRunning(db, DB, 'J1');
  seedJob(db, 'J1', 'running', { updatedAgoS: 30 * 60, beatAgoS: 60 });
  const before = rowOf(db);
  const res = await start(DB, 'J2', 'box-2');
  assert.equal(res.status, 409, JSON.stringify(res.body));
  assert.equal(res.body.terminal, undefined);
  assert.equal(res.body.request.job_id, 'J1');
  assert.deepEqual(rowOf(db), before);
});

test('A5b. boundary: a holder that beat 14 minutes ago is still live (409)', async () => {
  const { db, DB } = fresh();
  await seedRunning(db, DB, 'J1');
  seedJob(db, 'J1', 'running', { updatedAgoS: 14 * 60, beatAgoS: 14 * 60 });
  const res = await start(DB, 'J2', 'box-2');
  assert.equal(res.status, 409, JSON.stringify(res.body));
  assert.equal(rowOf(db).job_id, 'J1');
});

test('A6. the same live job starting again is idempotent (200, created:false)', async () => {
  const { db, DB } = fresh();
  seedJob(db, 'J1', 'running', { beatAgoS: 5 });
  await seedRunning(db, DB, 'J1');
  const res = await start(DB, 'J1', 'box-0');
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.created, false);
  assert.equal(rowOf(db).job_id, 'J1');
});

test('A7. done and failed rows are terminal: 409 terminal:true and nothing changes', async () => {
  for (const [outcome, verdict] of [['done', 'MERGE'], ['failed', undefined]]) {
    const { db, DB } = fresh();
    const r = await seedRunning(db, DB, 'J1');
    const fin = await result(DB, r.id, { job_id: 'J1', outcome, ...(verdict ? { verdict } : {}) });
    assert.equal(fin.status, 200, JSON.stringify(fin.body));
    const before = rowOf(db);
    const res = await start(DB, 'J2', 'box-2');
    assert.equal(res.status, 409, `${outcome}: ${JSON.stringify(res.body)}`);
    assert.equal(res.body.terminal, true);
    assert.equal(res.body.request.status, outcome);
    assert.deepEqual(rowOf(db), before);
  }
});

test('A8. a superseded row is restarted with verdict, report_ref and detail cleared', async () => {
  const { db, DB } = fresh();
  const r = await seedRunning(db, DB, 'J1');
  const sup = await result(DB, r.id, { job_id: 'J1', outcome: 'superseded', report_ref: 'r', detail: 'moved' });
  assert.equal(sup.status, 200, JSON.stringify(sup.body));
  db.prepare("UPDATE lead_review_requests SET verdict='BLOCK', report_ref='old-ref', detail='old-detail' WHERE id=?").run(r.id);
  const res = await start(DB, 'J2', 'box-2');
  assert.equal(res.status, 200, JSON.stringify(res.body));
  const row = rowOf(db);
  assert.equal(row.status, 'running');
  assert.equal(row.job_id, 'J2');
  assert.equal(row.verdict, null);
  assert.equal(row.report_ref, null);
  assert.equal(row.detail, null);
});

test('A9. the bearer is required (401, no row) and the lead token is not', async () => {
  const { db, DB } = fresh();
  const no = await start(DB, 'J1', 'box-1', {}, { bearer: false });
  assert.equal(no.status, 401);
  assert.equal(count(db), 0);
  const ok = await start(DB, 'J1', 'box-1', {}, { lead: false });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  const withLead = await start(DB, 'J1', 'box-1', {}, { lead: true });
  assert.equal(withLead.status, 200, 'a lead token sent anyway is ignored, not refused');
});

test('A10. malformed sha, pr, repo, job_id or box → 400 and no row written', async () => {
  const cases = [
    [{ head_sha: 'a'.repeat(39) }, 'head_sha must be a full 40-hex commit sha'],
    [{ head_sha: 'g'.repeat(40) }, 'head_sha must be a full 40-hex commit sha'],
    [{ head_sha: 'nothex' }, 'head_sha must be a full 40-hex commit sha'],
    [{ pr: 0 }, 'pr must be a positive integer'],
    [{ pr: -1 }, 'pr must be a positive integer'],
    [{ pr: 'x' }, 'pr must be a positive integer'],
    [{ repo: 'not a repo' }, 'repo must be owner/name'],
    [{ job_id: '' }, /job_id/],
    [{ box: undefined }, /box/],
  ];
  for (const [over, msg] of cases) {
    const { db, DB } = fresh();
    const res = await start(DB, 'J1', 'box-1', over);
    assert.equal(res.status, 400, `${JSON.stringify(over)}: ${JSON.stringify(res.body)}`);
    if (msg instanceof RegExp) assert.match(res.body.error, msg);
    else assert.equal(res.body.error, msg);
    assert.equal(count(db), 0, JSON.stringify(over));
  }
});

test('A10b. uppercase hex is normalized by the shared shaOf (as POST /api/lead-reviews does), not refused', async () => {
  const { db, DB } = fresh();
  const res = await start(DB, 'J1', 'box-1', { head_sha: H1.toUpperCase() });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.request.head_sha, H1);
  assert.equal(count(db), 1);
});

test('A11. after a takeover the dead job cannot finish the review; the new job can', async () => {
  const { db, DB } = fresh();
  seedJob(db, 'J1', 'failed');
  const r = await seedRunning(db, DB, 'J1');
  assert.equal((await start(DB, 'J2', 'box-2')).status, 200);
  const old = await result(DB, r.id, { job_id: 'J1', outcome: 'done', verdict: 'MERGE' });
  assert.equal(old.status, 409);
  assert.equal(old.body.error, 'job_id is not the job this request is bound to');
  const now = await result(DB, r.id, { job_id: 'J2', outcome: 'done', verdict: 'MERGE' });
  assert.equal(now.status, 200, JSON.stringify(now.body));
  assert.equal(rowOf(db).verdict, 'MERGE');
});

// BH-5351: /claim now takes a running row whose claim went quiet past the
// stale window (900 s by default), so the seed is 600 s quiet: inside that
// window /claim still 409s, while /start takes it over on job liveness alone.
test('A12. contrast: the old /claim still 409s a new job on the same #4025 seed', async () => {
  const { db, DB } = fresh();
  db.prepare(`INSERT INTO lead_review_requests (id, repo, pr, head_sha, status, job_id, box, created_at, updated_at)
              VALUES ('r1', ?, 4955, ?, 'running', 'J1', 'box-0', ?, ?)`).run(REPO, H1, ago(3600), ago(600));
  seedJob(db, 'J1', 'failed');
  const res = await claim(DB, 'r1', 'J2');
  assert.equal(res.status, 409, JSON.stringify(res.body));
  assert.equal(rowOf(db).job_id, 'J1');
});

test('A13. race: two starters on the same dead row — exactly one wins and holds the row', async () => {
  const { db, DB } = fresh();
  seedJob(db, 'J1', 'failed');
  await seedRunning(db, DB, 'J1');
  seedJob(db, 'J2', 'running', { beatAgoS: 1 });
  seedJob(db, 'J3', 'running', { beatAgoS: 1 });
  const [a, b] = await Promise.all([start(DB, 'J2', 'box-2'), start(DB, 'J3', 'box-3')]);
  const statuses = [a.status, b.status].sort();
  assert.deepEqual(statuses, [200, 409], `${JSON.stringify(a.body)} / ${JSON.stringify(b.body)}`);
  const [win, lose] = a.status === 200 ? [a, b] : [b, a];
  assert.equal(lose.body.terminal, undefined);
  assert.ok(lose.body.request && lose.body.request.id);
  assert.equal(rowOf(db).job_id, win.body.request.job_id);
});
