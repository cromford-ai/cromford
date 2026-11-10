// BH-9160 (the rest of BH-8734): POST /api/lifecycle/note, one ticket_events
// row that moves no phase. bin/jobs-watchdog.sh writes it when it holds a
// review row the call guard refused on its head. Driven through the REAL
// worker.fetch over the REAL composed schema (the node:sqlite D1 shim).
//
//   N1  a note on a plan_blocked row: one event, from = to = plan_blocked; the
//       phase columns do not move
//   N2  a note on a row with no phase: to_phase `none`
//   N3  the same note twice is 200 duplicate:true and one row
//   N4  no build_queue row -> 404 no_row; wrong tenant -> 404 and 0 rows
//   N5  actor watchdog 200; actor bogus, bad pr, a 501-char reason -> 400
//   N6  no bearer -> 401
//   N7  GET /api/lifecycle/history returns the note (round trip)
//   N8  EXPLAIN QUERY PLAN of NOTE_SQL at 10 000 queue rows and 200 000 events
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { ensureColumns } from '../src/lib/core.js';

const SECRET = 'test-secret-fixture';
const SKIP = (await openDb()) === null && 'node:sqlite unavailable in this runtime';
// Imported only when the runtime can run the suite: the module is new.
const { NOTE_SQL } = SKIP ? {} : await import('../src/routes/lifecycle-note.js').catch(() => ({}));

const req = (DB, method, path, body, auth = true) => {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  const r = new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(r, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const note = (DB, body, auth) => req(DB, 'POST', '/api/lifecycle/note', body, auth);

async function fresh() {
  const o = await openDb();
  await ensureColumns({ DB: d1(o.db) }, 'build_queue');
  return o;
}
function seedRow(db, project, key, phase = null) {
  db.prepare(`INSERT INTO build_queue (project, ticket_key, status, enqueued_at, updated_at, phase, phase_at, phase_actor)
    VALUES (?, ?, 'done', '2026-11-06T00:00:00Z', '2026-11-06T00:00:00Z', ?, ?, ?)`)
    .run(project, key, phase, phase ? '2026-11-06T00:00:00Z' : null, phase ? 'triage' : null);
}
const rowOf = (db, project, key) => ({ ...db.prepare(
  'SELECT * FROM build_queue WHERE project = ? AND ticket_key = ?').get(project, key) });
const eventsOf = (db, project, key) => db.prepare(
  'SELECT from_phase, to_phase, actor, reason, pr FROM ticket_events WHERE project = ? AND ticket_key = ? ORDER BY id')
  .all(project, key).map((r) => ({ ...r }));
const eventCount = (db) => db.prepare('SELECT count(*) AS n FROM ticket_events').get().n;
const REASON = 'call guard refused RR-3191-f44d3cf5 on example-org/project-6#3191@f44d3cf5aaaa: this head already had its paid review; existing verdict BLOCK (lead, verdict row 7). Not re-queued: only a new head re-queues.';

test('N1 a note on a plan_blocked row writes one event and moves no phase', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  seedRow(db, 'cromford', 'BH-1', 'plan_blocked');
  const before = rowOf(db, 'cromford', 'BH-1');
  const r = await note(DB, { project: 'cromford', ticket_key: 'BH-1', actor: 'watchdog', reason: 'x', pr: 12 });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.duplicate, false);
  assert.ok(Number.isInteger(r.body.event_id) && r.body.event_id > 0, JSON.stringify(r.body));
  assert.deepEqual(eventsOf(db, 'cromford', 'BH-1'),
    [{ from_phase: 'plan_blocked', to_phase: 'plan_blocked', actor: 'watchdog', reason: 'x', pr: 12 }]);
  assert.deepEqual(rowOf(db, 'cromford', 'BH-1'), before, 'the build_queue row does not move');
});

test('N2 a note on a row with no phase has to_phase none', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  seedRow(db, 'project-6-os', 'RR-3191-f44d3cf5');
  const before = rowOf(db, 'project-6-os', 'RR-3191-f44d3cf5');
  const r = await note(DB, { project: 'project-6-os', ticket_key: 'RR-3191-f44d3cf5', actor: 'watchdog', reason: REASON, pr: 3191 });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(eventsOf(db, 'project-6-os', 'RR-3191-f44d3cf5'),
    [{ from_phase: null, to_phase: 'none', actor: 'watchdog', reason: REASON, pr: 3191 }]);
  assert.deepEqual(rowOf(db, 'project-6-os', 'RR-3191-f44d3cf5'), before);
});

test('N3 the same note twice is duplicate:true and one row; another reason is a second', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  seedRow(db, 'project-6-os', 'LR-3212-e8f497e3');
  const body = { project: 'project-6-os', ticket_key: 'LR-3212-e8f497e3', actor: 'watchdog', reason: REASON };
  assert.equal((await note(DB, body)).body.duplicate, false);
  const again = await note(DB, body);
  assert.equal(again.status, 200);
  assert.equal(again.body.duplicate, true);
  assert.equal(again.body.event_id, undefined);
  assert.equal(eventsOf(db, 'project-6-os', 'LR-3212-e8f497e3').length, 1);
  assert.equal((await note(DB, { ...body, reason: 'another fact' })).body.duplicate, false);
  assert.equal(eventsOf(db, 'project-6-os', 'LR-3212-e8f497e3').length, 2);
});

test('N4 no row and wrong tenant are 404 no_row with 0 rows', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  seedRow(db, 'project-6-os', 'RR-1-aaaaaaaa');
  const none = await note(DB, { project: 'project-6-os', ticket_key: 'RR-2-bbbbbbbb', actor: 'watchdog', reason: 'x' });
  assert.equal(none.status, 404);
  assert.equal(none.body.error, 'no_row');
  const other = await note(DB, { project: 'project-3', ticket_key: 'RR-1-aaaaaaaa', actor: 'watchdog', reason: 'x' });
  assert.equal(other.status, 404);
  assert.equal(other.body.error, 'no_row');
  assert.equal(eventCount(db), 0);
});

test('N5 actor watchdog is 200; a bad field is 400 and writes nothing', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  seedRow(db, 'project-6-os', 'RR-1-aaaaaaaa');
  const ok = { project: 'project-6-os', ticket_key: 'RR-1-aaaaaaaa', actor: 'watchdog', reason: 'x' };
  const cases = [
    [{ ...ok, project: 'Bad Project' }, 'project'],
    [{ ...ok, ticket_key: 'a b' }, 'ticket_key'],
    [{ ...ok, actor: 'bogus' }, 'actor'],
    [{ ...ok, actor: 'Watchdog' }, 'actor'],
    [{ ...ok, reason: '' }, 'reason'],
    [{ ...ok, reason: 'x'.repeat(501) }, 'reason'],
    [{ ...ok, pr: 0 }, 'pr'],
    [{ ...ok, pr: '12' }, 'pr'],
  ];
  for (const [body, field] of cases) {
    const r = await note(DB, body);
    assert.equal(r.status, 400, field);
    assert.equal(r.body.error, field);
  }
  assert.equal(eventCount(db), 0);
  const r = await note(DB, { ...ok, reason: 'x'.repeat(500) });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(eventCount(db), 1);
  // A lifecycle actor may note too.
  assert.equal((await note(DB, { ...ok, actor: 'lifecycle' })).status, 200);
});

test('N6 no bearer is 401 and writes nothing', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  seedRow(db, 'project-6-os', 'RR-1-aaaaaaaa');
  const r = await note(DB, { project: 'project-6-os', ticket_key: 'RR-1-aaaaaaaa', actor: 'watchdog', reason: 'x' }, false);
  assert.equal(r.status, 401);
  assert.equal(eventCount(db), 0);
});

test('N7 GET /api/lifecycle/history returns the note', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  seedRow(db, 'project-6-os', 'RR-2985-25e98935');
  // The exact body tests/jobs-watchdog-cg-terminal.bh-9160-test.sh pins.
  const body = JSON.parse('{"project":"project-6-os","ticket_key":"RR-2985-25e98935","actor":"watchdog","reason":"r","pr":2985}');
  assert.equal((await note(DB, body)).status, 200);
  const h = await req(DB, 'GET', '/api/lifecycle/history?project=project-6-os&ticket_key=RR-2985-25e98935');
  assert.equal(h.status, 200, JSON.stringify(h.body));
  const ev = (h.body.events || h.body.rows || [])[0];
  assert.ok(ev, JSON.stringify(h.body));
  assert.equal(ev.from_phase, null);
  assert.equal(ev.to_phase, 'none');
  assert.equal(ev.actor, 'watchdog');
  assert.equal(ev.reason, 'r');
  assert.equal(ev.pr, 2985);
});

test('N8 EXPLAIN QUERY PLAN: the note reads both tables on an index, no SCAN', { skip: SKIP }, async () => {
  assert.equal(typeof NOTE_SQL, 'string', 'src/routes/lifecycle-note.js exports NOTE_SQL');
  const { db } = await fresh();
  db.exec('BEGIN');
  const qb = db.prepare(`INSERT INTO build_queue (project, ticket_key, status, enqueued_at, updated_at) VALUES (?, ?, 'done', '2026-11-01T00:00:00Z', '2026-11-01T00:00:00Z')`);
  const ev = db.prepare(`INSERT INTO ticket_events (project, ticket_key, from_phase, to_phase, actor, reason, at) VALUES (?, ?, NULL, 'triaged', 'triage', 'r', '2026-11-01T00:00:00Z')`);
  for (let i = 0; i < 10000; i++) {
    qb.run('p' + (i % 10), 'K-' + i);
    for (let j = 0; j < 20; j++) ev.run('p' + (i % 10), 'K-' + i);
  }
  db.exec('COMMIT');
  db.exec('ANALYZE');
  assert.equal(db.prepare('SELECT count(*) AS n FROM ticket_events').get().n, 200000);
  const plan = db.prepare('EXPLAIN QUERY PLAN ' + NOTE_SQL).all('p1', 'K-1', 'watchdog', 'x', null, '2026-11-06T00:00:00Z')
    .map((r) => r.detail).join(' | ');
  assert.match(plan, /idx_ticket_events_project_ticket_id/, plan);
  assert.match(plan, /SEARCH build_queue USING (INDEX|PRIMARY KEY|COVERING INDEX)/, plan);
  assert.doesNotMatch(plan, /SCAN (build_queue|ticket_events)\b/, plan);
});
