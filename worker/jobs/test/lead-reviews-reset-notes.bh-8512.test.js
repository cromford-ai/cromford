import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';

// BH-8512 — POST /api/lead-reviews/:id/reset {append_notes} appends the note to
// the row's scope_notes in the same compare-and-set as the reset, so a lead
// re-request after an empty BLOCK reaches the lead prompt (## Scope notes)
// instead of a request the UNIQUE(repo, pr, head_sha) key answers 409.
// Driven through worker.fetch over the shipped schema (the bh-5400 idiom).
const SECRET = 'test-secret';
const LEAD = 'lead-test-token';
const SCHEMA = jobsSchemaSql();
const NOTE = 'write each finding as a - [BLOCK <class>] line';

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

let n = 0;
const headOf = () => (++n).toString(16).padStart(40, 'b');
const rowOf = (db, id) => db.prepare('SELECT * FROM lead_review_requests WHERE id=?').get(id);
const reset = (DB, id, body = {}, lead = true) => call(DB, `/${id}/reset`, { method: 'POST', body, lead });

async function created(DB, scope_notes) {
  const res = await call(DB, '', {
    method: 'POST', lead: true,
    body: { repo: 'example-org/cromford', pr: 8512, head_sha: headOf(), ...(scope_notes ? { scope_notes } : {}) },
  });
  assert.equal(res.status, 201, JSON.stringify(res.body));
  return res.body.request.id;
}
// done BLOCK by job-1: the empty-BLOCK row U13-EMPTY re-requests.
async function done(db, DB, scope_notes) {
  const id = await created(DB, scope_notes);
  const h = rowOf(db, id).head_sha;
  assert.equal((await call(DB, `/${id}/claim`, { method: 'POST', body: { job_id: 'job-1', box: 'box-1' } })).status, 200);
  const r = await call(DB, `/${id}/result`, {
    method: 'POST', body: { job_id: 'job-1', head_sha: h, outcome: 'done', verdict: 'BLOCK', report_ref: 'r.md', reviewer_model: 'm' },
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return id;
}
const NOW = Date.now(); // determinism: ok the single anchor; the worker stamps the reset and its stale cutoff off the real clock, so the backdated heartbeat derives from this one read
const isoAgo = (s) => new Date(NOW - s * 1000).toISOString();

test('W1 reset with {} on a done row: 200, scope_notes unchanged, no notes field', async () => {
  const { db, DB } = fresh();
  const id = await done(db, DB, 'auth: x');
  const r = await reset(DB, id);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(rowOf(db, id).status, 'requested');
  assert.equal(rowOf(db, id).scope_notes, 'auth: x');
  assert.equal('notes' in r.body, false);
});

test('W2 done row, scope_notes NULL + append_notes: reset, note stored, notes stored', async () => {
  const { db, DB } = fresh();
  const id = await done(db, DB);
  assert.equal(rowOf(db, id).scope_notes, null);
  const r = await reset(DB, id, { append_notes: NOTE });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const now = rowOf(db, id);
  assert.equal(now.status, 'requested');
  assert.equal(now.reset_count, 1);
  assert.equal(now.verdict, null);
  assert.equal(now.scope_notes, NOTE);
  assert.equal(r.body.notes, 'stored');
  assert.equal(r.body.request.scope_notes, NOTE);
});

test('W3 done row with tier tokens: the note goes after a newline, the tokens stay', async () => {
  const { db, DB } = fresh();
  const old = 'auto: builder APPROVE on abc; review-tier:medium review-mode:full';
  const id = await done(db, DB, old);
  const r = await reset(DB, id, { append_notes: NOTE });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(rowOf(db, id).scope_notes, `${old}\n${NOTE}`);
  assert.match(rowOf(db, id).scope_notes, /review-tier:medium review-mode:full/);
  assert.equal(r.body.notes, 'stored');
});

test('W4 the same reset retried on the now-requested row: no double append, notes present', async () => {
  const { db, DB } = fresh();
  const id = await done(db, DB, 'auth: x');
  assert.equal((await reset(DB, id, { append_notes: NOTE })).status, 200);
  const r = await reset(DB, id, { append_notes: NOTE });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.existing, true);
  assert.equal(r.body.notes, 'present');
  assert.equal(rowOf(db, id).scope_notes, `auth: x\n${NOTE}`);
  assert.equal(rowOf(db, id).reset_count, 1);
});

test('W4b near misses are stored, not present: a prefix of the note, a case change', async () => {
  const { db, DB } = fresh();
  const id = await done(db, DB, 'write each finding');
  assert.equal((await reset(DB, id, { append_notes: NOTE })).body.notes, 'stored');
  assert.equal(rowOf(db, id).scope_notes, `write each finding\n${NOTE}`);
  const up = NOTE.toUpperCase();
  const r = await reset(DB, id, { append_notes: up });
  assert.equal(r.body.notes, 'stored');
  assert.equal(rowOf(db, id).scope_notes, `write each finding\n${NOTE}\n${up}`);
});

test('W5 a requested row (never worked) + note: note stored, reset_count unchanged', async () => {
  const { db, DB } = fresh();
  const id = await created(DB);
  const before = rowOf(db, id);
  const r = await reset(DB, id, { append_notes: NOTE });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.existing, true);
  assert.equal(r.body.notes, 'stored');
  const now = rowOf(db, id);
  assert.equal(now.scope_notes, NOTE);
  assert.equal(now.status, 'requested');
  assert.equal(now.reset_count ?? 0, before.reset_count ?? 0);
  assert.equal(r.body.request.scope_notes, NOTE);
});

test('W6 review-tier:/review-mode: in a note are stored as = (never a live token)', async () => {
  const { db, DB } = fresh();
  const id = await done(db, DB);
  const r = await reset(DB, id, { append_notes: 'please review-tier:high review-mode:full' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(rowOf(db, id).scope_notes, 'please review-tier=high review-mode=full');
});

test('W7 no room: 3990 chars + a 20-char note keeps the old notes, the reset lands, notes no-room', async () => {
  const { db, DB } = fresh();
  const old = 'x'.repeat(3990);
  const id = await done(db, DB, old);
  const r = await reset(DB, id, { append_notes: 'y'.repeat(20) });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.notes, 'no-room');
  assert.equal(rowOf(db, id).status, 'requested');
  assert.equal(rowOf(db, id).scope_notes, old);
  const id2 = await done(db, DB, 'z'.repeat(4000));
  const r2 = await reset(DB, id2, { append_notes: 'y' });
  assert.equal(r2.body.notes, 'no-room');
  assert.equal(rowOf(db, id2).scope_notes, 'z'.repeat(4000));
});

test('W8 a bad append_notes is 400 and writes nothing; "" and null are absent', async () => {
  const { db, DB } = fresh();
  const id = await done(db, DB, 'auth: x');
  for (const bad of ['y'.repeat(4001), 7, { a: 1 }]) {
    const r = await reset(DB, id, { append_notes: bad });
    assert.equal(r.status, 400, JSON.stringify(r.body));
    assert.equal(rowOf(db, id).status, 'done');
    assert.equal(rowOf(db, id).scope_notes, 'auth: x');
  }
  for (const empty of ['', null]) {
    const id2 = await done(db, DB, 'auth: y');
    const r = await reset(DB, id2, { append_notes: empty });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(rowOf(db, id2).scope_notes, 'auth: y');
    assert.equal('notes' in r.body, false);
  }
});

test('W9 no lead token: 403, row unchanged', async () => {
  const { db, DB } = fresh();
  const id = await done(db, DB);
  const r = await reset(DB, id, { append_notes: NOTE }, false);
  assert.equal(r.status, 403);
  assert.equal(rowOf(db, id).status, 'done');
  assert.equal(rowOf(db, id).scope_notes, null);
});

test('W10 stale running + note: reclaimed and stored; fresh running + note: 409, unchanged', async () => {
  const { db, DB } = fresh();
  const id = await created(DB, 'auth: x');
  assert.equal((await call(DB, `/${id}/claim`, { method: 'POST', body: { job_id: 'job-old', box: 'box-a' } })).status, 200);
  db.prepare('UPDATE lead_review_requests SET heartbeat_at=?1, updated_at=?1 WHERE id=?2').run(isoAgo(1000), id);
  const r = await reset(DB, id, { append_notes: NOTE });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.reclaimed_from.job_id, 'job-old');
  assert.equal(r.body.notes, 'stored');
  assert.equal(rowOf(db, id).status, 'requested');
  assert.equal(rowOf(db, id).scope_notes, `auth: x\n${NOTE}`);

  const id2 = await created(DB, 'auth: y');
  assert.equal((await call(DB, `/${id2}/claim`, { method: 'POST', body: { job_id: 'job-new', box: 'box-b' } })).status, 200);
  const r2 = await reset(DB, id2, { append_notes: NOTE });
  assert.equal(r2.status, 409, JSON.stringify(r2.body));
  assert.equal(rowOf(db, id2).status, 'running');
  assert.equal(rowOf(db, id2).scope_notes, 'auth: y');
});

test('W10b a done row whose scope_notes moved after the read: 409 moved, no reset', async () => {
  const { db, DB } = fresh();
  const id = await done(db, DB, 'auth: x');
  // Make the read see 'auth: x' and the write see another value: change it in
  // between through a DB wrapper that edits the row on the first UPDATE.
  const real = sqliteDB(db);
  let fired = false;
  const DB2 = {
    prepare: (sql) => {
      if (!fired && /^\s*UPDATE lead_review_requests SET status='requested'/.test(sql)) {
        fired = true;
        db.prepare('UPDATE lead_review_requests SET scope_notes=?1 WHERE id=?2').run('auth: changed', id);
      }
      return real.prepare(sql);
    },
  };
  const r = await reset(DB2, id, { append_notes: NOTE });
  assert.equal(fired, true, 'the reset UPDATE ran');
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(rowOf(db, id).status, 'done');
  assert.equal(rowOf(db, id).scope_notes, 'auth: changed');
});

test('W11 the lane list (?status=requested) returns the reset row with the note in scope_notes', async () => {
  const { db, DB } = fresh();
  const id = await done(db, DB, 'auth: x');
  assert.equal((await reset(DB, id, { append_notes: NOTE })).status, 200);
  const l = await call(DB, '?status=requested');
  assert.equal(l.status, 200, JSON.stringify(l.body));
  const row = l.body.requests.find((q) => q.id === id);
  assert.ok(row, JSON.stringify(l.body));
  assert.ok(row.scope_notes.endsWith(`\n${NOTE}`), row.scope_notes);
});
