// BH-9586: an ejected ticket whose PR already merged can move to merged.
// The Tackler's U14-MERGED rule (catalog/unblock-rules.d/U14-MERGED.json)
// writes ejected -> merged as actor lifecycle (the re-entry owner rule in
// src/lib/lifecycle.js). Driven through the REAL worker.fetch over the REAL
// composed schema (the node:sqlite D1 shim), as the BH-8731 suite is.
//
//   W1  lifecycleCheck: ejected -> merged by lifecycle is ok; by conductor it
//       is wrong_owner with owners ['lifecycle']
//   W2  POST /api/lifecycle/transition ejected -> merged by lifecycle: 200,
//       one ticket_events row from ejected to merged, phase merged; a second
//       identical move: 409 illegal_transition (merged is terminal), no event
//   W3  in_queue -> merged by conductor is unchanged (200)
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { ensureColumns } from '../src/lib/core.js';
import { lifecycleCheck } from '../src/lib/lifecycle.js';

const SECRET = 'test-secret-fixture';
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
function seedRow(db, project, key, phase) {
  db.prepare(`INSERT INTO build_queue (project, ticket_key, status, enqueued_at, updated_at, phase, phase_at, phase_actor)
    VALUES (?, ?, 'done', '2026-11-01T00:00:00Z', '2026-11-01T00:00:00Z', ?, '2026-11-12T07:00:00Z', 'seed')`).run(project, key, phase);
}
const eventsOf = (db, project, key) => db.prepare(
  'SELECT from_phase, to_phase, actor, pr FROM ticket_events WHERE project = ? AND ticket_key = ? ORDER BY id').all(project, key);
const phaseOf = (db, project, key) => db.prepare(
  'SELECT phase, phase_actor FROM build_queue WHERE project = ? AND ticket_key = ?').get(project, key);

const SKIP = (await openDb()) === null && 'node:sqlite unavailable in this runtime';

test('W1 ejected -> merged is legal for lifecycle only', () => {
  assert.deepEqual(lifecycleCheck('ejected', 'merged', 'lifecycle'), { ok: true });
  const c = lifecycleCheck('ejected', 'merged', 'conductor');
  assert.equal(c.error, 'wrong_owner');
  assert.deepEqual(c.owners, ['lifecycle']);
});

test('W2 the route moves an ejected ticket to merged once', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  const P = 'w2-bh-9586';
  seedRow(db, P, 'BH-9460', 'ejected');
  const body = { project: P, ticket_key: 'BH-9460', to_phase: 'merged', actor: 'lifecycle', reason: 'U14-MERGED settle', pr: 9508 };
  const r = await move(DB, body);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(eventsOf(db, P, 'BH-9460').map((e) => ({ ...e })),
    [{ from_phase: 'ejected', to_phase: 'merged', actor: 'lifecycle', pr: 9508 }]);
  assert.deepEqual({ ...phaseOf(db, P, 'BH-9460') }, { phase: 'merged', phase_actor: 'lifecycle' });
  const again = await move(DB, body);
  assert.equal(again.status, 409);
  assert.equal(again.body.error, 'illegal_transition');
  assert.equal(again.body.current, 'merged');
  assert.equal(eventsOf(db, P, 'BH-9460').length, 1, 'no second event');
});

test('W3 in_queue -> merged by conductor is unchanged', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  const P = 'w3-bh-9586';
  seedRow(db, P, 'BH-9461', 'in_queue');
  const r = await move(DB, { project: P, ticket_key: 'BH-9461', to_phase: 'merged', actor: 'conductor', reason: 'merged' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(phaseOf(db, P, 'BH-9461').phase, 'merged');
});
