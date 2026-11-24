// BH-9943: a resolver re-plan of a ticket in phase `ejected` moves the phase
// to pr_open as actor `lifecycle` (bin/lib/phase-uneject.sh). This pins that
// the move is legal for that actor, and that it widens nothing: a move out of
// plan_blocked or abandoned to pr_open stays refused. Driven through the REAL
// worker.fetch over the REAL composed schema (the node:sqlite D1 shim), as
// lifecycle-rebuild.bh-8733.test.js does.
//
//   (a) ejected -> pr_open by lifecycle: 200, one event, phase_actor lifecycle
//   (b) the same move by resolver and by pool: 409 wrong_owner, no event
//   (c) plan_blocked -> pr_open by lifecycle: 409 illegal_transition
//   (d) plan_blocked -> planned by resolver: 409 wrong_owner
//   (e) abandoned -> pr_open by lifecycle: 409 illegal_transition
//   (f) lifecycleCheck answers the same as the route for (a) to (e)
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { ensureColumns } from '../src/lib/core.js';
import { lifecycleCheck } from '../src/lib/lifecycle.js';

const SECRET = 'test-secret-fixture';
const P = 'bh9943';
const REASON = 'blocked-resolver: stale-replan: no head or verdict change for 5d';

const move = (DB, body) => worker.fetch(new Request('https://jobs.test/api/lifecycle/transition', {
  method: 'POST',
  headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
  body: JSON.stringify(body),
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

async function fresh() {
  const o = await openDb();
  await ensureColumns({ DB: d1(o.db) }, 'build_queue');
  return o;
}
function seedRow(db, key, phase) {
  db.prepare(`INSERT INTO build_queue (project, ticket_key, status, enqueued_at, updated_at, phase, phase_at, phase_actor)
    VALUES (?, ?, 'queued', '2026-11-01T00:00:00Z', '2026-11-01T00:00:00Z', ?, '2026-11-01T00:00:00Z', 'conductor')`).run(P, key, phase);
}
const rowOf = (db, key) => db.prepare('SELECT phase, phase_actor FROM build_queue WHERE project = ? AND ticket_key = ?').get(P, key);
const eventsOf = (db, key) => db.prepare('SELECT from_phase, to_phase, actor, reason FROM ticket_events WHERE project = ? AND ticket_key = ?').all(P, key);

const SKIP = (await openDb()) === null && 'node:sqlite unavailable in this runtime';

test('(a) ejected -> pr_open by lifecycle: 200 and one event', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  seedRow(db, 'BH-1', 'ejected');
  const r = await move(DB, { project: P, ticket_key: 'BH-1', to_phase: 'pr_open', actor: 'lifecycle', reason: REASON });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.from, 'ejected');
  assert.deepEqual({ ...rowOf(db, 'BH-1') }, { phase: 'pr_open', phase_actor: 'lifecycle' });
  assert.deepEqual(eventsOf(db, 'BH-1').map((e) => ({ ...e })),
    [{ from_phase: 'ejected', to_phase: 'pr_open', actor: 'lifecycle', reason: REASON }]);
});

test('(b) ejected -> pr_open by resolver or pool: 409 wrong_owner, no event', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  for (const actor of ['resolver', 'pool']) {
    const key = `BH-2-${actor}`;
    seedRow(db, key, 'ejected');
    const r = await move(DB, { project: P, ticket_key: key, to_phase: 'pr_open', actor, reason: REASON });
    assert.equal(r.status, 409, actor);
    assert.equal(r.body.error, 'wrong_owner');
    assert.deepEqual(r.body.owners, ['lifecycle']);
    assert.equal(r.body.current, 'ejected');
    assert.equal(eventsOf(db, key).length, 0);
    assert.equal(rowOf(db, key).phase, 'ejected');
  }
});

test('(c) plan_blocked -> pr_open by lifecycle stays illegal', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  seedRow(db, 'BH-3', 'plan_blocked');
  const r = await move(DB, { project: P, ticket_key: 'BH-3', to_phase: 'pr_open', actor: 'lifecycle', reason: REASON });
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'illegal_transition');
  assert.equal(r.body.current, 'plan_blocked');
  assert.equal(eventsOf(db, 'BH-3').length, 0);
  assert.equal(rowOf(db, 'BH-3').phase, 'plan_blocked');
});

test('(d) plan_blocked -> planned by resolver: 409 wrong_owner', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  seedRow(db, 'BH-4', 'plan_blocked');
  const r = await move(DB, { project: P, ticket_key: 'BH-4', to_phase: 'planned', actor: 'resolver', reason: REASON });
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'wrong_owner');
  assert.equal(eventsOf(db, 'BH-4').length, 0);
});

test('(e) abandoned -> pr_open by lifecycle stays illegal', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  seedRow(db, 'BH-5', 'abandoned');
  const r = await move(DB, { project: P, ticket_key: 'BH-5', to_phase: 'pr_open', actor: 'lifecycle', reason: REASON });
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'illegal_transition');
  assert.equal(r.body.current, 'abandoned');
  assert.equal(eventsOf(db, 'BH-5').length, 0);
});

test('(f) lifecycleCheck answers as the route does', () => {
  assert.deepEqual(lifecycleCheck('ejected', 'pr_open', 'lifecycle'), { ok: true });
  assert.equal(lifecycleCheck('ejected', 'pr_open', 'resolver').error, 'wrong_owner');
  assert.equal(lifecycleCheck('ejected', 'pr_open', 'pool').error, 'wrong_owner');
  assert.equal(lifecycleCheck('plan_blocked', 'pr_open', 'lifecycle').error, 'illegal_transition');
  assert.equal(lifecycleCheck('plan_blocked', 'planned', 'resolver').error, 'wrong_owner');
  assert.equal(lifecycleCheck('abandoned', 'pr_open', 'lifecycle').error, 'illegal_transition');
});
