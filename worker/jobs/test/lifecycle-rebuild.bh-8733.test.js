// BH-8733 (lifecycle 3/6): a resolver rebuild-fresh over an open PR phase.
// The pool must be able to move a key from pr_open back to building, so a
// PLAN_BLOCKED stop of the rebuild can be stored. Driven through the REAL
// worker.fetch over the REAL composed schema (the node:sqlite D1 shim), as
// ticket-lifecycle.bh-8731.test.js does.
//
//   (a) pr_open -> building by pool: 200, one event, phase_actor pool
//   (b) the same move by conductor: 409 wrong_owner, no event
//   (c) pr_open -> plan_blocked is still 409 illegal_transition
//   (d) ejected -> building and abandoned -> building by pool are still 409
//       (re-entry from those phases is the lifecycle actor's, BH-8731)
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { ensureColumns } from '../src/lib/core.js';

const SECRET = 'test-secret-fixture';
const P = 'bh8733';

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
    VALUES (?, ?, 'queued', '2026-11-01T00:00:00Z', '2026-11-01T00:00:00Z', ?, '2026-11-01T00:00:00Z', 'pool')`).run(P, key, phase);
}
const rowOf = (db, key) => db.prepare('SELECT phase, phase_actor FROM build_queue WHERE project = ? AND ticket_key = ?').get(P, key);
const eventsOf = (db, key) => db.prepare('SELECT from_phase, to_phase, actor FROM ticket_events WHERE project = ? AND ticket_key = ?').all(P, key);

const SKIP = (await openDb()) === null && 'node:sqlite unavailable in this runtime';

test('(a) pr_open -> building by pool: 200 and one event', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  seedRow(db, 'BH-1', 'pr_open');
  const r = await move(DB, { project: P, ticket_key: 'BH-1', to_phase: 'building', actor: 'pool', reason: 'machine m1 spawned' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.from, 'pr_open');
  assert.deepEqual({ ...rowOf(db, 'BH-1') }, { phase: 'building', phase_actor: 'pool' });
  assert.deepEqual(eventsOf(db, 'BH-1').map((e) => ({ ...e })), [{ from_phase: 'pr_open', to_phase: 'building', actor: 'pool' }]);
  // ...and the rebuild's PLAN_BLOCKED stop is now storable.
  const pb = await move(DB, { project: P, ticket_key: 'BH-1', to_phase: 'plan_blocked', actor: 'pool', reason: 'PLAN_BLOCKED', question: 'Which org?' });
  assert.equal(pb.status, 200, JSON.stringify(pb.body));
});

test('(b) pr_open -> building by conductor: 409 wrong_owner, no event', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  seedRow(db, 'BH-2', 'pr_open');
  const r = await move(DB, { project: P, ticket_key: 'BH-2', to_phase: 'building', actor: 'conductor', reason: 'r' });
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'wrong_owner');
  assert.deepEqual(r.body.owners, ['pool']);
  assert.equal(eventsOf(db, 'BH-2').length, 0);
  assert.equal(rowOf(db, 'BH-2').phase, 'pr_open');
});

test('(c) pr_open -> plan_blocked is still illegal', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  seedRow(db, 'BH-3', 'pr_open');
  const r = await move(DB, { project: P, ticket_key: 'BH-3', to_phase: 'plan_blocked', actor: 'pool', reason: 'r', question: 'q' });
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'illegal_transition');
  assert.equal(r.body.current, 'pr_open');
  assert.equal(eventsOf(db, 'BH-3').length, 0);
});

test('(d) ejected -> building and abandoned -> building by pool stay 409', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  for (const ph of ['ejected', 'abandoned']) {
    const key = `BH-4-${ph}`;
    seedRow(db, key, ph);
    const r = await move(DB, { project: P, ticket_key: key, to_phase: 'building', actor: 'pool', reason: 'r' });
    assert.equal(r.status, 409, `${ph} -> building`);
    assert.equal(r.body.current, ph);
    assert.equal(eventsOf(db, key).length, 0);
    assert.equal(rowOf(db, key).phase, ph);
  }
});
