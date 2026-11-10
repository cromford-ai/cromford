import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { jobsSchemaSql } from './lib/jobs-schema.js';
import { ensureColumns } from '../src/lib/core.js';

// BH-9160 (the rest of BH-8734): one decider for a relaunch.
//
// POST /api/queue refuses a BUILD enqueue (status `queued`) with 409
// `phase_refused` when the row's phase is `plan_blocked` or `abandoned`, unless
// the actor is exactly `lifecycle`. A refusal writes no queue row and rings no
// wake. Driven through `worker.fetch` (D2) over node:sqlite with the composed
// jobs schema; the phase columns come from the worker's own ensureColumns
// (core.d/bh-8731-lifecycle.js), as on D1.
//
//   W1-W5   refuse cases a-e of the plan's decision rule
//   W6-W13  accept cases f-m (W13: wrong project, 0 rows of project A touched)

const SCHEMA = jobsSchemaSql();
const SECRET = 'test-secret-fixture';
const P = 'cromford';

// A D1 shim that records every statement, so a test can prove a refusal ran
// no INSERT or UPDATE at all.
function d1(db, calls) {
  const exec = (sql) => {
    calls.push(sql.replace(/\s+/g, ' ').trim());
    return db.prepare(sql);
  };
  const shape = (sql, binds) => ({
    all: async () => ({ results: exec(sql).all(...binds) }),
    first: async () => exec(sql).get(...binds) ?? null,
    run: async () => {
      const r = exec(sql).run(...binds);
      return { meta: { changes: Number(r.changes), last_row_id: Number(r.lastInsertRowid) } };
    },
  });
  return {
    prepare(sql) { return { bind: (...b) => shape(sql, b), ...shape(sql, []) }; },
    async batch(stmts) { return Promise.all(stmts.map((s) => s.run())); },
  };
}

async function fixture(t) {
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const calls = [];
  const DB = d1(db, calls);
  await ensureColumns({ DB }, 'build_queue');
  calls.length = 0;
  return { db, calls, DB };
}

// A row in the shape a finished build leaves, with the phase a lifecycle
// writer set on it.
function seed(fx, { project = P, key = 'BH-1', status = 'done', phase = null } = {}) {
  const t = '2026-11-06T10:00:00Z';
  fx.db.prepare(
    `INSERT INTO build_queue (project, ticket_key, status, target, attempt, enqueued_at, finished_at,
                              reason, updated_at, phase, phase_at, phase_actor)
     VALUES (?1, ?2, ?3, 'fly', 1, ?4, ?4, 'RESULT PLAN_BLOCKED', ?4, ?5, ?6, ?7)`
  ).run(project, key, status, t, phase, phase ? t : null, phase ? 'triage' : null);
  fx.calls.length = 0;
}

const call = (fx, body) => {
  const req = new Request('https://jobs.test/api/queue', {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
    body: JSON.stringify(body),
  });
  return worker.fetch(req, { DB: fx.DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const PUT = { project: P, key: 'BH-1', target: 'fly' };
const writes = (fx) => fx.calls.filter((s) => /^(INSERT|UPDATE|DELETE|ALTER)\b/i.test(s));
const row = (fx, key = 'BH-1', project = P) => ({ ...fx.db.prepare(
  'SELECT * FROM build_queue WHERE project=?1 AND ticket_key=?2').get(project, key) });
const wakeCount = (fx) => fx.db.prepare('SELECT COUNT(*) AS n FROM wakes').get().n;

async function refused(t, rowOpts, body, phase) {
  const fx = await fixture(t);
  if (!fx) return;
  seed(fx, rowOpts);
  const before = row(fx);
  const r = await call(fx, { ...PUT, ...body });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.error, 'phase_refused');
  assert.equal(r.body.phase, phase);
  assert.equal(r.body.project, P);
  assert.equal(r.body.key, 'BH-1');
  assert.deepEqual(writes(fx), [], 'a refusal runs no write statement');
  assert.equal(wakeCount(fx), 0, 'a refusal rings no wake');
  assert.deepEqual(row(fx), before, 'the row is byte-identical (status, attempt, updated_at)');
}

async function accepted(t, rowOpts, body = {}) {
  const fx = await fixture(t);
  if (!fx) return;
  if (rowOpts) seed(fx, rowOpts);
  const r = await call(fx, { ...PUT, ...body });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.duplicate, false);
  const after = row(fx);
  assert.equal(after.status, 'queued');
  assert.equal(after.attempt, rowOpts ? 2 : 0, 'a re-queue continues the attempt count');
  assert.equal(wakeCount(fx), 1, 'a fly build enqueue rings one wake');
  return fx;
}

test('W1 (a): phase plan_blocked, no actor -> 409 phase_refused, no write, no wake', (t) =>
  refused(t, { phase: 'plan_blocked' }, {}, 'plan_blocked'));

test('W2 (b): phase abandoned, actor triage -> 409', (t) =>
  refused(t, { phase: 'abandoned' }, { actor: 'triage' }, 'abandoned'));

test('W3 (c): phase plan_blocked, actor Lifecycle (case differs) -> 409', (t) =>
  refused(t, { phase: 'plan_blocked' }, { actor: 'Lifecycle' }, 'plan_blocked'));

test('W4 (d): phase abandoned, actor "lifecycle " (trailing space) -> 409', (t) =>
  refused(t, { phase: 'abandoned' }, { actor: 'lifecycle ' }, 'abandoned'));

test('W5 (e): phase plan_blocked over a claimed row -> 409, not the duplicate answer', (t) =>
  refused(t, { phase: 'plan_blocked', status: 'claimed' }, {}, 'plan_blocked'));

test('W6 (f): phase NULL -> 201', (t) => accepted(t, { phase: null }));

test('W7 (g): phase planned -> 201', (t) => accepted(t, { phase: 'planned' }));

test('W8 (h): phase building -> 201', (t) => accepted(t, { phase: 'building' }));

test('W9 (i): phase plan_blocked, actor lifecycle -> 201, the row is re-queued', (t) =>
  accepted(t, { phase: 'plan_blocked' }, { actor: 'lifecycle' }));

test('W10 (j): no existing row -> 201', (t) => accepted(t, null));

test('W11 (k): a ready put over a plan_blocked done row keeps the BH-1033 duplicate answer', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  seed(fx, { phase: 'plan_blocked' });
  const before = row(fx);
  const r = await call(fx, { ...PUT, status: 'ready' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.duplicate, true);
  assert.equal(r.body.error, undefined);
  assert.deepEqual(writes(fx), []);
  assert.deepEqual(row(fx), before);
});

test('W12 (l): phase PLAN_BLOCKED (uppercase, not a phase value) -> 201', (t) =>
  accepted(t, { phase: 'PLAN_BLOCKED' }));

test('W13 (m): project B, same key, while project A is plan_blocked -> B lands, A untouched', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  seed(fx, { phase: 'plan_blocked' });
  const beforeA = row(fx);
  const r = await call(fx, { ...PUT, project: 'other-os' });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(row(fx, 'BH-1', 'other-os').status, 'queued');
  assert.deepEqual(row(fx), beforeA, "project A's row is untouched");
  // And project A itself is still refused.
  const a = await call(fx, PUT);
  assert.equal(a.status, 409);
});
