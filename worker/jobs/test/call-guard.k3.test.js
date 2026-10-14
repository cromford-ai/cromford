import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker, { ensureTable, CREATED_TABLES } from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// K3 — THE PRE-CALL GUARD'S COUNTER. bin/agent-call.sh asks this route, BEFORE
// it spends anything, how many paid calls one piece of work (project, stage,
// fingerprint) has already had inside the window, and the route answers by
// either recording the new call or refusing it. Driven through the worker's
// real fetch handler against THE SQL THAT SHIPS (schema.sql into node:sqlite),
// because the whole guard is one SQL property: the count and the insert are one
// statement, so two boxes asking at the same instant cannot both squeeze under
// the ceiling.
//
// Time: the route stamps rows with the server clock. The tests never read a
// clock themselves (docs/TEST-DETERMINISM.md); a row "outside the window" is a
// row stamped in the year 2000, which is outside any window the route accepts.

const SECRET = 'test-secret';
const SCHEMA = jobsSchemaSql();

function sqliteDB(db) {
  const prepare = (sql) => {
    const bindAndRun = (binds) => ({
      first: async () => db.prepare(sql).get(...binds.map((v) => (v === undefined ? null : v))) ?? null,
      all: async () => ({ results: db.prepare(sql).all(...binds.map((v) => (v === undefined ? null : v))) }),
      run: async () => {
        const r = db.prepare(sql).run(...binds.map((v) => (v === undefined ? null : v)));
        return { meta: { changes: Number(r.changes) || 0, last_row_id: Number(r.lastInsertRowid) || 0 } };
      },
    });
    return { ...bindAndRun([]), bind: (...binds) => bindAndRun(binds) };
  };
  return { prepare };
}

async function openDb(t, { schema = true } = {}) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  const db = new DatabaseSync(':memory:');
  if (schema) db.exec(SCHEMA);
  return db;
}

const call = (db, path, { method = 'POST', body, secret = SECRET } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return worker.fetch(req, { DB: sqliteDB(db), HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const claim = (db, id, extra = {}) => call(db, '/api/call-guard/claim', {
  body: { project: 'project-5', stage: 'review', fp: 'review-prs:acme/app#229@553a9e0', call_id: id, max: 2, ...extra },
});

test('claim: the first K calls of one fingerprint are recorded, the K+1th is refused', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  const a = await claim(db, 'c1');
  assert.equal(a.status, 200);
  assert.equal(a.body.allowed, true);
  assert.equal(a.body.count, 1);
  const b = await claim(db, 'c2');
  assert.equal(b.body.allowed, true);
  assert.equal(b.body.count, 2);
  const c = await claim(db, 'c3');
  assert.equal(c.status, 200, 'a refusal is an ANSWER, never an error status');
  assert.equal(c.body.allowed, false);
  assert.equal(c.body.count, 2, 'the refused call is not counted as paid');
  assert.equal(c.body.max, 2);
  const paid = db.prepare("SELECT COUNT(*) AS n FROM call_guard WHERE status='claimed'").get().n;
  assert.equal(paid, 2);
  const refused = db.prepare("SELECT COUNT(*) AS n FROM call_guard WHERE status='refused'").get().n;
  assert.equal(refused, 1, 'the refusal is kept, so the digest can name the fingerprint');
  db.close();
});

test('claim: a different head sha (a different fingerprint) is a different piece of work', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  await claim(db, 'c1'); await claim(db, 'c2');
  const other = await claim(db, 'c3', { fp: 'review-prs:acme/app#229@0000new' });
  assert.equal(other.body.allowed, true);
  assert.equal(other.body.count, 1);
  const otherStage = await claim(db, 'c4', { stage: 'triage-shard' });
  assert.equal(otherStage.body.allowed, true, 'the key is (project, stage, fp), not fp alone');
  const otherProject = await claim(db, 'c5', { project: 'project-4' });
  assert.equal(otherProject.body.allowed, true);
  db.close();
});

test('claim is idempotent on call_id: a retried POST returns the first decision and counts once', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  const a = await claim(db, 'same');
  const again = await claim(db, 'same');
  assert.equal(again.body.allowed, true);
  assert.equal(again.body.count, 1, 'a transport retry of the same claim must not count twice');
  assert.equal(again.body.duplicate, true);
  assert.equal(a.body.duplicate, false);
  await claim(db, 'x2');
  const r = await claim(db, 'x3');
  assert.equal(r.body.allowed, false);
  const rAgain = await claim(db, 'x3');
  assert.equal(rAgain.body.allowed, false, 'a refused call_id stays refused on retry');
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM call_guard').get().n, 3);
  db.close();
});

test('settle: unbilled frees the slot; ok/empty/failed keep it; settle is once-only', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  await claim(db, 'u1');
  const s = await call(db, '/api/call-guard/settle', { body: { call_id: 'u1', outcome: 'unbilled' } });
  assert.equal(s.status, 200);
  assert.equal(s.body.settled, true);
  // nothing was billed, so the fingerprint still has both slots
  assert.equal((await claim(db, 'u2')).body.allowed, true);
  const e = await call(db, '/api/call-guard/settle', { body: { call_id: 'u2', outcome: 'empty' } });
  assert.equal(e.body.settled, true);
  assert.equal((await claim(db, 'u3')).body.allowed, true);
  // an EMPTY result is billed and terminal: it holds its slot, so a third is refused
  assert.equal((await claim(db, 'u4')).body.allowed, false,
    'success-with-nothing-in-it is a PAID call, never a free retry');
  const twice = await call(db, '/api/call-guard/settle', { body: { call_id: 'u2', outcome: 'unbilled' } });
  assert.equal(twice.body.settled, false, 'a settled row is never re-settled (the first outcome stands)');
  assert.equal(db.prepare("SELECT status FROM call_guard WHERE call_id='u2'").get().status, 'empty');
  const bad = await call(db, '/api/call-guard/settle', { body: { call_id: 'u3', outcome: 'maybe' } });
  assert.equal(bad.status, 400);
  const refusedRow = await call(db, '/api/call-guard/settle', { body: { call_id: 'u4', outcome: 'unbilled' } });
  assert.equal(refusedRow.body.settled, false, 'a refusal is not a claim and cannot be settled into one');
  db.close();
});

test('the window: a paid call outside it does not count', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  db.prepare(`INSERT INTO call_guard (call_id, project, stage, fp, status, at)
              VALUES ('old1','project-5','review','review-prs:acme/app#229@553a9e0','ok','2000-01-01T00:00:00Z'),
                     ('old2','project-5','review','review-prs:acme/app#229@553a9e0','ok','2000-01-01T00:00:00Z')`).run();
  const a = await claim(db, 'n1');
  assert.equal(a.body.allowed, true);
  assert.equal(a.body.count, 1);
  db.close();
});

test('claim: validation, clamps, and the bearer', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  for (const missing of ['project', 'stage', 'fp', 'call_id']) {
    const r = await claim(db, 'v1', { [missing]: '' });
    assert.equal(r.status, 400, `${missing} is required`);
  }
  const zero = await claim(db, 'v2', { max: 0 });
  assert.equal(zero.status, 400, 'max 0 is a disabled guard — the CLIENT never asks; the route refuses to guess');
  const wide = await claim(db, 'v3', { window_s: 10 });
  assert.equal(wide.body.window_s, 60, 'a window under a minute is clamped up, never a free-for-all');
  const unauth = await claim(db, 'v4', {});
  assert.equal(unauth.status, 200);
  const res = await call(db, '/api/call-guard/claim', { body: { project: 'p', stage: 's', fp: 'f', call_id: 'z' }, secret: 'wrong' });
  assert.equal(res.status, 401);
  db.close();
});

test('refusal names the top fingerprints for this (project, stage)', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  await claim(db, 'a1'); await claim(db, 'a2');
  await claim(db, 'a3'); await claim(db, 'a4');
  const r = await claim(db, 'a5');
  assert.equal(r.body.allowed, false);
  assert.ok(Array.isArray(r.body.top) && r.body.top.length >= 1);
  assert.equal(r.body.top[0].fp, 'review-prs:acme/app#229@553a9e0');
  assert.equal(r.body.top[0].refused, 3);
  assert.equal(r.body.top[0].paid, 2);
  const list = await call(db, '/api/call-guard?project=project-5&stage=review', { method: 'GET' });
  assert.equal(list.status, 200);
  assert.equal(list.body.rows[0].fp, 'review-prs:acme/app#229@553a9e0');
  db.close();
});

test('the table self-creates on an untouched D1 (BH-658 belt) and matches schema.sql', async (t) => {
  const db = await openDb(t, { schema: false });
  if (!db) return;
  const a = await claim(db, 'b1');
  assert.equal(a.status, 200, 'an unapplied schema is a create, never a thrown 1101');
  assert.equal(a.body.allowed, true);
  const cols = db.prepare('PRAGMA table_info(call_guard)').all().map((c) => c.name);
  const full = await openDb(t);
  const want = full.prepare('PRAGMA table_info(call_guard)').all().map((c) => c.name);
  assert.deepEqual(cols, want, 'CREATED_TABLES.call_guard and schema.sql must create the same columns');
  const idx = db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='call_guard'").all().map((r) => r.name);
  assert.ok(idx.includes('idx_call_guard_key'));
  assert.ok(Array.isArray(CREATED_TABLES.call_guard));
  await ensureTable({ DB: sqliteDB(db) }, 'call_guard');
  db.close(); full.close();
});

test('force: a hand-run path is recorded as paid even at the ceiling', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  await claim(db, 'f1'); await claim(db, 'f2');
  assert.equal((await claim(db, 'f3')).body.allowed, false);
  const f = await claim(db, 'f4', { force: true });
  assert.equal(f.body.allowed, true, 'AGENT_CALL_GUARD_FORCE overrides the ceiling');
  assert.equal(f.body.forced, true);
  assert.equal(f.body.count, 3, 'and the forced call COUNTS — an override is not a free call');
  assert.equal(db.prepare("SELECT status FROM call_guard WHERE call_id='f4'").get().status, 'claimed');
  db.close();
});

test('DELETE /api/call-guard resets one piece of work and writes an audit row', async (t) => {
  const db = await openDb(t);
  if (!db) return;
  await claim(db, 'r1'); await claim(db, 'r2');
  await claim(db, 'o1', { fp: 'other-work' });
  assert.equal((await claim(db, 'r3')).body.allowed, false);
  const fp = encodeURIComponent('review-prs:acme/app#229@553a9e0');
  const res = await call(db, `/api/call-guard?project=project-5&stage=review&fp=${fp}&actor=hub&reason=hand%20retry`, { method: 'DELETE' });
  assert.equal(res.status, 200);
  assert.equal(res.body.reset, 2, 'the two paid rows stop counting');
  const again = await claim(db, 'r4');
  assert.equal(again.body.allowed, true, 'after a reset the work may be bought again');
  assert.equal(again.body.count, 1);
  const audit = db.prepare("SELECT * FROM call_guard WHERE status='reset'").all();
  assert.equal(audit.length, 1, 'exactly one audit row per reset');
  assert.equal(audit[0].box, 'hub');
  assert.match(audit[0].note || '', /hand retry/, 'the audit row keeps the reason');
  assert.equal((await claim(db, 'o2', { fp: 'other-work' })).body.count, 2, 'other work is untouched');
  const bad = await call(db, '/api/call-guard?project=project-5&stage=review', { method: 'DELETE' });
  assert.equal(bad.status, 400, 'a reset names its work: project, stage AND fp');
  db.close();
});
