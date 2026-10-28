// BH-8731 (lifecycle 1/6): the ticket phase columns on build_queue, the
// ticket_events ledger and the /api/lifecycle routes. Driven through the REAL
// worker.fetch over the REAL composed schema (the node:sqlite D1 shim).
//
//   L1  the schema.d fragment runs twice clean; ticket_events has its 9
//       columns and both indexes; the 9 settings seeds; a re-apply keeps an
//       operator's changed value
//   L2  ensureColumns adds phase, phase_at, phase_actor, question (nullable
//       TEXT, no default) and idx_build_queue_phase_at; old rows read NULL
//   L3  the decision table: every (from, to) pair, the owner cases, the core.js
//       re-export is the same object
//   L4  each rejected move: 409 (or 400/404) and NO event, NO phase change;
//       the stale race is 409 stale with no event
//   L5  an accepted chain writes exactly one event per move and the phase
//       columns equal it; question is set on plan_blocked and cleared after;
//       3 statements per warm transition; history and stuck read it back
//   L6  wrong tenant: another project's key is 404 and 0 rows everywhere
//   L7  /stuck: only rows older than their settings row; a row change changes
//       the answer with no deploy; bad rows fall back; truncated is measured
//   L8  EXPLAIN QUERY PLAN at 10 000 tickets / 200 000 events uses the indexes
//   L9  /history: newest first, truncated at lifecycle.history.limit + 1, 400s
//   L10 retention: dry run counts old rows only; unbound archive moves 0;
//       bound archive copies, then deletes
//   L11 the body bin/lib/jobs/lifecycle.sh sends (tests/lifecycle-client
//       C1) passes the route's validation
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb, d1 } from './lib/d1-sqlite.bh-1030.js';
import { ensureColumns, LIFECYCLE_TRANSITIONS as CORE_TRANSITIONS, LIFECYCLE_OWNERS as CORE_OWNERS } from '../src/lib/core.js';
import { RULES } from '../src/routes/retention.js';

const SECRET = 'test-secret-fixture';
const SCHEMA_D = new URL('../schema.d/', import.meta.url);
const FRAGMENT = readdirSync(SCHEMA_D).find((n) => /^\d{12}-bh-8731-ticket-events\.sql$/.test(n));
const fragmentSql = () => readFileSync(new URL(FRAGMENT, SCHEMA_D), 'utf8');
const L = () => import('../src/lib/lifecycle.js');
const R = () => import('../src/routes/ticket-lifecycle.js');

const call = (DB, path, { method = 'GET', body, extra = {} } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, ...extra, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const move = (DB, body) => call(DB, '/api/lifecycle/transition', { method: 'POST', body });
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const setting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'t','test','2026-10-28T00:00:00Z') ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, String(value));

// A db with the phase columns in place (ensureColumns is what the routes run).
async function fresh(hooks) {
  const o = await openDb(hooks);
  await ensureColumns({ DB: d1(o.db) }, 'build_queue');
  return o;
}
function seedRow(db, project, key, phase = null, phaseAt = null, actor = null) {
  db.prepare(`INSERT INTO build_queue (project, ticket_key, status, enqueued_at, updated_at, phase, phase_at, phase_actor)
    VALUES (?, ?, 'done', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z', ?, ?, ?)`).run(project, key, phase, phaseAt, actor);
}
const rowOf = (db, project, key) => db.prepare(
  'SELECT phase, phase_at, phase_actor, question, updated_at FROM build_queue WHERE project = ? AND ticket_key = ?').get(project, key);
const eventsOf = (db, project, key) => db.prepare(
  'SELECT * FROM ticket_events WHERE project = ? AND ticket_key = ? ORDER BY id').all(project, key);
const eventCount = (db) => db.prepare('SELECT count(*) AS n FROM ticket_events').get().n;

// The decision table of plan.md "Phase model", written out independently of
// src/lib/lifecycle.js so a change to one is caught by the other.
const PHASES = ['triaged', 'planned', 'plan_blocked', 'building', 'pr_open', 'in_queue', 'ejected', 'abandoned', 'merged', 'closed'];
const TABLE = {
  '': 'triaged planned building closed',
  triaged: 'planned plan_blocked building closed',
  planned: 'building plan_blocked closed',
  plan_blocked: 'triaged planned closed',
  building: 'pr_open plan_blocked abandoned closed',
  pr_open: 'in_queue merged abandoned closed',
  in_queue: 'merged ejected closed',
  ejected: 'in_queue pr_open abandoned closed',
  abandoned: 'triaged planned closed',
  merged: '',
  closed: '',
};

// node:sqlite is unflagged from 22.13; an older runtime skips visibly.
const SKIP = (await openDb()) === null && 'node:sqlite unavailable in this runtime';

test('L1 the fragment applies twice; ticket_events, its indexes and the 9 seeds', { skip: SKIP }, async () => {
  assert.ok(FRAGMENT, 'worker/jobs/schema.d/<stamp>-bh-8731-ticket-events.sql exists');
  const { db } = await openDb();
  const cols = db.prepare('PRAGMA table_info(ticket_events)').all();
  assert.deepEqual(cols.map((c) => c.name),
    ['id', 'project', 'ticket_key', 'from_phase', 'to_phase', 'actor', 'reason', 'pr', 'at']);
  const notnull = Object.fromEntries(cols.map((c) => [c.name, c.notnull]));
  assert.equal(notnull.from_phase, 0, 'from_phase is NULL for a first move');
  assert.equal(notnull.pr, 0);
  for (const c of ['project', 'ticket_key', 'to_phase', 'actor', 'reason', 'at']) assert.equal(notnull[c], 1, `${c} NOT NULL`);
  const idx = (n) => db.prepare('PRAGMA index_info(' + n + ')').all().map((r) => r.name);
  assert.deepEqual(idx('idx_ticket_events_project_ticket_id'), ['project', 'ticket_key', 'id']);
  assert.deepEqual(idx('idx_ticket_events_at'), ['at']);
  const want = {
    'lifecycle.stuck.plan_blocked_min': '1440', 'lifecycle.stuck.ejected_min': '30',
    'lifecycle.stuck.abandoned_min': '0', 'lifecycle.stuck.building_min': '180',
    'lifecycle.stuck.in_queue_min': '120', 'lifecycle.stuck.pr_open_min': '1440',
    'lifecycle.stuck.limit': '200', 'lifecycle.history.limit': '200', 'retention.ticket_events.days': '180',
  };
  const seeds = () => Object.fromEntries(db.prepare(
    "SELECT key, value FROM settings WHERE key LIKE 'lifecycle.%' OR key = 'retention.ticket_events.days'").all().map((r) => [r.key, r.value]));
  assert.deepEqual(seeds(), want);
  setting(db, 'lifecycle.stuck.building_min', '45');
  db.exec(fragmentSql());
  db.exec(fragmentSql());
  assert.deepEqual(seeds(), { ...want, 'lifecycle.stuck.building_min': '45' }, 'a re-apply keeps the operator value');
});

test('L2 ensureColumns adds the 4 nullable phase columns and the (phase, phase_at) index', { skip: SKIP }, async () => {
  const { db, DB } = await openDb();
  const before = new Set(db.prepare('PRAGMA table_info(build_queue)').all().map((c) => c.name));
  for (const c of ['phase', 'phase_at', 'phase_actor', 'question']) assert.equal(before.has(c), false, `${c} comes from ADDED_COLUMNS`);
  db.prepare(`INSERT INTO build_queue (project, ticket_key, status, enqueued_at, updated_at)
    VALUES ('l2', 'OLD-1', 'done', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z')`).run();
  await ensureColumns({ DB }, 'build_queue');
  const after = new Map(db.prepare('PRAGMA table_info(build_queue)').all().map((c) => [c.name, c]));
  for (const c of ['phase', 'phase_at', 'phase_actor', 'question']) {
    const r = after.get(c);
    assert.ok(r, `${c} added`);
    assert.equal(r.type, 'TEXT');
    assert.equal(r.notnull, 0);
    assert.equal(r.dflt_value, null);
  }
  assert.ok(db.prepare('PRAGMA index_list(build_queue)').all().some((r) => r.name === 'idx_build_queue_phase_at'));
  assert.deepEqual(db.prepare('PRAGMA index_info(idx_build_queue_phase_at)').all().map((r) => r.name), ['phase', 'phase_at']);
  const old = rowOf(db, 'l2', 'OLD-1');
  assert.equal(old.phase, null);
  assert.equal(old.phase_at, null);
});

test('L3 the transition table, the owners, the core.js re-export', { skip: SKIP }, async () => {
  const M = await L();
  assert.deepEqual(M.LIFECYCLE_PHASES, PHASES);
  assert.deepEqual([...M.LIFECYCLE_TERMINAL].sort(), ['closed', 'merged']);
  assert.equal(CORE_TRANSITIONS, M.LIFECYCLE_TRANSITIONS, 'core.js re-exports the same object');
  assert.equal(CORE_OWNERS, M.LIFECYCLE_OWNERS);
  let cells = 0;
  for (const from of ['', ...PHASES]) {
    const legal = new Set(TABLE[from].split(' ').filter(Boolean));
    for (const to of PHASES) {
      cells++;
      // The owner that makes a legal move pass, so only legality decides here.
      const owner = M.lifecycleOwners(from, to)[0] || 'board';
      const r = M.lifecycleCheck(from, to, owner);
      if (legal.has(to)) assert.equal(r.ok, true, `${from || '(none)'} -> ${to} must be legal: ${JSON.stringify(r)}`);
      else assert.equal(r.error, 'illegal_transition', `${from || '(none)'} -> ${to} must be illegal`);
    }
  }
  assert.equal(cells, 110);
  assert.deepEqual(M.LIFECYCLE_TRANSITIONS.merged, []);
  assert.deepEqual(M.LIFECYCLE_TRANSITIONS.closed, []);
  for (const [from, to, actor] of [
    ['', 'triaged', 'triage'], ['building', 'pr_open', 'pool'], ['in_queue', 'merged', 'conductor'],
    ['ejected', 'in_queue', 'lifecycle'], ['abandoned', 'planned', 'lifecycle'], ['building', 'abandoned', 'resolver'],
    ['ejected', 'abandoned', 'pr-records'], ['pr_open', 'closed', 'board'], ['plan_blocked', 'triaged', 'lifecycle'],
  ]) assert.deepEqual(M.lifecycleCheck(from, to, actor), { ok: true }, `${from}->${to} by ${actor}`);
  for (const [from, to, actor, err] of [
    ['merged', 'closed', 'board', 'illegal_transition'], ['closed', 'triaged', 'triage', 'illegal_transition'],
    ['building', 'building', 'pool', 'illegal_transition'], ['triaged', 'merged', 'conductor', 'illegal_transition'],
    ['ejected', 'in_queue', 'conductor', 'wrong_owner'], ['plan_blocked', 'planned', 'pool', 'wrong_owner'],
    ['abandoned', 'closed', 'lifecycle', 'wrong_owner'], ['building', 'pr_open', 'conductor', 'wrong_owner'],
  ]) assert.equal(M.lifecycleCheck(from, to, actor).error, err, `${from}->${to} by ${actor}`);
  assert.deepEqual(M.lifecycleCheck('ejected', 'in_queue', 'conductor').owners, ['lifecycle']);
  assert.deepEqual(M.lifecycleOwners('building', 'abandoned'), ['pr-records', 'resolver']);
  assert.deepEqual([...M.LIFECYCLE_ACTORS].sort(), ['board', 'conductor', 'lifecycle', 'pool', 'pr-records', 'resolver', 'triage']);
});

test('L4 a rejected move answers 409/400/404 and writes nothing', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  const P = 'l4-proj';
  const at0 = '2026-10-20T00:00:00Z';
  const cases = [
    ['merged', 'closed', 'board', 409, 'illegal_transition'],
    ['closed', 'triaged', 'triage', 409, 'illegal_transition'],
    ['building', 'building', 'pool', 409, 'illegal_transition'],
    ['triaged', 'merged', 'conductor', 409, 'illegal_transition'],
    ['ejected', 'in_queue', 'conductor', 409, 'wrong_owner'],
    ['plan_blocked', 'planned', 'pool', 409, 'wrong_owner'],
    ['abandoned', 'closed', 'lifecycle', 409, 'wrong_owner'],
    ['building', 'pr_open', 'Pool', 400, 'actor'],
    ['building', 'pr_open', 'tackler', 400, 'actor'],
    ['building', 'pr_open', 'archie', 400, 'actor'],
    ['building', 'done', 'pool', 400, 'to_phase'],
    ['in_queue', 'MERGED', 'conductor', 400, 'to_phase'],
  ];
  let i = 0;
  for (const [from, to, actor, status, err] of cases) {
    const key = `L4-${++i}`;
    seedRow(db, P, key, from, at0, 'seed');
    const before = rowOf(db, P, key);
    const n0 = eventCount(db);
    const r = await move(DB, { project: P, ticket_key: key, to_phase: to, actor, reason: 'test' });
    assert.equal(r.status, status, `${from}->${to} by ${actor}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.error, err);
    if (status === 409) {
      assert.equal(r.body.current, from);
      assert.equal(r.body.to, to);
    }
    assert.equal(eventCount(db), n0, `${from}->${to}: no event`);
    assert.deepEqual(rowOf(db, P, key), before, `${from}->${to}: phase columns unchanged`);
  }
  // 409 bodies name what would be accepted
  seedRow(db, P, 'L4-own', 'ejected', at0);
  const own = await move(DB, { project: P, ticket_key: 'L4-own', to_phase: 'in_queue', actor: 'conductor', reason: 'r' });
  assert.deepEqual(own.body.owners, ['lifecycle']);
  const ill = await move(DB, { project: P, ticket_key: 'L4-own', to_phase: 'merged', actor: 'conductor', reason: 'r' });
  assert.deepEqual(ill.body.allowed, ['in_queue', 'pr_open', 'abandoned', 'closed']);
  // bad fields: 400 naming the field, nothing written
  seedRow(db, P, 'L4-bad', 'building', at0);
  const ok = { project: P, ticket_key: 'L4-bad', to_phase: 'pr_open', actor: 'pool', reason: 'r' };
  const n0 = eventCount(db);
  for (const [over, field] of [
    [{ project: "x'; DROP TABLE build_queue;--" }, 'project'], [{ project: undefined }, 'project'], [{ project: 'Bad' }, 'project'],
    [{ ticket_key: 'a;b' }, 'ticket_key'], [{ ticket_key: "FR'1" }, 'ticket_key'], [{ ticket_key: '' }, 'ticket_key'],
    [{ to_phase: undefined }, 'to_phase'],
    [{ reason: '' }, 'reason'], [{ reason: '   ' }, 'reason'], [{ reason: 'x'.repeat(501) }, 'reason'], [{ reason: 5 }, 'reason'],
    [{ pr: 0 }, 'pr'], [{ pr: '12' }, 'pr'], [{ pr: 1.5 }, 'pr'], [{ pr: -3 }, 'pr'],
    [{ question: 'x'.repeat(2001), to_phase: 'plan_blocked' }, 'question'], [{ question: 7, to_phase: 'plan_blocked' }, 'question'],
    [{ question: 'why?' }, 'question'],
  ]) {
    const r = await move(DB, { ...ok, ...over });
    assert.equal(r.status, 400, `${JSON.stringify(over).slice(0, 60)}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.error, field);
  }
  assert.equal(eventCount(db), n0);
  assert.equal(rowOf(db, P, 'L4-bad').phase, 'building');
  assert.equal(db.prepare("SELECT count(*) AS n FROM sqlite_master WHERE name = 'build_queue'").get().n, 1);
  // a non-object body
  const arr = await call(DB, '/api/lifecycle/transition', { method: 'POST', body: [1] });
  assert.equal(arr.status, 400);
  // an unknown row
  const nf = await move(DB, { ...ok, ticket_key: 'L4-none' });
  assert.equal(nf.status, 404);
  assert.equal(nf.body.error, 'no_row');
  assert.equal(eventCount(db), n0);
});

test('L4 stale race: the phase moves between the read and the write -> 409 stale, no event', { skip: SKIP }, async () => {
  const hook = { armed: false, db: null };
  const { db, DB } = await fresh({
    beforeRun(sql) {
      if (hook.armed && /INSERT INTO ticket_events/.test(sql)) {
        hook.armed = false;
        hook.db.prepare("UPDATE build_queue SET phase = 'pr_open' WHERE ticket_key = 'L4-race'").run();
      }
    },
  });
  hook.db = db;
  seedRow(db, 'l4-race', 'L4-race', 'building', '2026-10-20T00:00:00Z');
  hook.armed = true;
  const r = await move(DB, { project: 'l4-race', ticket_key: 'L4-race', to_phase: 'pr_open', actor: 'pool', reason: 'r' });
  assert.equal(hook.armed, false, 'the hook fired');
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.error, 'stale');
  assert.equal(r.body.current, 'pr_open');
  assert.equal(eventCount(db), 0);
  assert.equal(rowOf(db, 'l4-race', 'L4-race').phase_actor, null, 'the guarded UPDATE did not run either');
});

test('L5 an accepted chain: one event per move, phase columns equal it, 3 statements warm', { skip: SKIP }, async (tt) => {
  let now = Date.parse('2026-10-28T12:00:00Z');
  tt.mock.timers.enable({ apis: ['Date'], now });
  const { db, DB: inner } = await fresh();
  const seen = [];
  const DB = { prepare(sql) { seen.push(sql); return inner.prepare(sql); }, batch: (s) => inner.batch(s) };
  const P = 'l5-proj', K = 'L5-1';
  seedRow(db, P, K);
  const chain = [
    ['triaged', 'triage', null], ['planned', 'pool', null], ['building', 'pool', null],
    ['pr_open', 'pool', 4242], ['in_queue', 'conductor', 4242], ['merged', 'conductor', 4242],
  ];
  let from = null;
  let n = 0;
  for (const [to, actor, pr] of chain) {
    now += 60000;
    tt.mock.timers.setTime(now);
    seen.length = 0;
    const body = { project: P, ticket_key: K, to_phase: to, actor, reason: `step ${++n}` };
    if (pr !== null) body.pr = pr;
    const r = await move(DB, body);
    assert.equal(r.status, 200, `${to}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.ok, true);
    assert.equal(r.body.from, from);
    assert.equal(r.body.to, to);
    if (n > 1) assert.equal(seen.length, 3, `warm transition ${to}: ${seen.join(' | ')}`);
    const ev = eventsOf(db, P, K);
    assert.equal(ev.length, n, 'exactly one event per accepted move');
    const last = ev[ev.length - 1];
    assert.equal(r.body.event_id, last.id, 'event_id is the row written');
    assert.deepEqual({ from: last.from_phase, to: last.to_phase, actor: last.actor, reason: last.reason, pr: last.pr },
      { from, to, actor, reason: `step ${n}`, pr });
    assert.equal(last.at, iso(now));
    const row = rowOf(db, P, K);
    assert.deepEqual({ phase: row.phase, phase_at: row.phase_at, phase_actor: row.phase_actor },
      { phase: to, phase_at: last.at, phase_actor: actor });
    assert.equal(r.body.phase_at, last.at);
    from = to;
  }
  // terminal: nothing more is accepted
  const after = await move(DB, { project: P, ticket_key: K, to_phase: 'closed', actor: 'board', reason: 'x' });
  assert.equal(after.status, 409);
  assert.equal(eventsOf(db, P, K).length, 6);
  // question: stored on plan_blocked, cleared on the next move
  seedRow(db, P, 'L5-q');
  assert.equal((await move(DB, { project: P, ticket_key: 'L5-q', to_phase: 'triaged', actor: 'triage', reason: 'a' })).status, 200);
  const qb = await move(DB, { project: P, ticket_key: 'L5-q', to_phase: 'plan_blocked', actor: 'pool', reason: 'b', question: 'How does the rep set the fee?' });
  assert.equal(qb.status, 200, JSON.stringify(qb.body));
  assert.equal(rowOf(db, P, 'L5-q').question, 'How does the rep set the fee?');
  const qa = await move(DB, { project: P, ticket_key: 'L5-q', to_phase: 'planned', actor: 'lifecycle', reason: 'client answered' });
  assert.equal(qa.status, 200, JSON.stringify(qa.body));
  assert.equal(rowOf(db, P, 'L5-q').question, null);
  // round trip: history and stuck read back what the transition wrote
  seedRow(db, P, 'L5-rt', 'building', '2026-10-20T00:00:00Z');
  const ab = await move(DB, { project: P, ticket_key: 'L5-rt', to_phase: 'abandoned', actor: 'resolver', reason: 'ladder ran out', pr: 99 });
  assert.equal(ab.status, 200);
  now += 1000;
  tt.mock.timers.setTime(now);
  const h = await call(DB, `/api/lifecycle/history?project=${P}&ticket_key=L5-rt`);
  assert.equal(h.status, 200);
  assert.deepEqual(h.body.events.map((e) => [e.id, e.from_phase, e.to_phase, e.actor, e.reason, e.pr, e.at]),
    [[ab.body.event_id, 'building', 'abandoned', 'resolver', 'ladder ran out', 99, ab.body.phase_at]]);
  const s = await call(DB, `/api/lifecycle/stuck?project=${P}`);
  assert.equal(s.status, 200);
  const sr = s.body.rows.find((x) => x.ticket_key === 'L5-rt');
  assert.ok(sr, `abandoned (0 min) is stuck at once: ${JSON.stringify(s.body.rows)}`);
  assert.deepEqual([sr.phase, sr.phase_actor, sr.phase_at, sr.threshold_min], ['abandoned', 'resolver', ab.body.phase_at, 0]);
});

test('L6 wrong tenant: project B never reads or moves project A', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  seedRow(db, 'tenant-a', 'TK-6', 'building', '2026-01-01T00:00:00Z');
  const a = await move(DB, { project: 'tenant-a', ticket_key: 'TK-6', to_phase: 'abandoned', actor: 'resolver', reason: 'a' });
  assert.equal(a.status, 200);
  // Age the move, so the stuck read (abandoned = 0 min) sees it in the same second.
  db.prepare("UPDATE build_queue SET phase_at = '2026-01-02T00:00:00Z' WHERE project = 'tenant-a'").run();
  const n0 = eventCount(db);
  const b = await move(DB, { project: 'tenant-b', ticket_key: 'TK-6', to_phase: 'closed', actor: 'board', reason: 'b' });
  assert.equal(b.status, 404);
  assert.equal(eventCount(db), n0);
  assert.equal(rowOf(db, 'tenant-a', 'TK-6').phase, 'abandoned');
  assert.equal(db.prepare("SELECT count(*) AS n FROM build_queue WHERE project = 'tenant-b'").get().n, 0);
  const sa = await call(DB, '/api/lifecycle/stuck?project=tenant-a');
  assert.equal(sa.body.rows.length, 1, 'control: A sees its own row');
  const sb = await call(DB, '/api/lifecycle/stuck?project=tenant-b');
  assert.equal(sb.status, 200);
  assert.deepEqual(sb.body.rows, []);
  const hb = await call(DB, '/api/lifecycle/history?project=tenant-b&ticket_key=TK-6');
  assert.equal(hb.status, 200);
  assert.deepEqual(hb.body.events, []);
  const ha = await call(DB, '/api/lifecycle/history?project=tenant-a&ticket_key=TK-6');
  assert.equal(ha.body.events.length, 1, 'control: A reads its own history');
});

test('L7 /stuck: rows past their settings row only; a row change needs no deploy', { skip: SKIP }, async (tt) => {
  const NOW = Date.parse('2026-10-28T12:00:00Z');
  tt.mock.timers.enable({ apis: ['Date'], now: NOW });
  const ago = (min) => iso(NOW - min * 60000);
  const { db, DB } = await fresh();
  const P = 'l7';
  const rows = [
    ['B-181', 'building', ago(181)], ['B-179', 'building', ago(179)],
    ['A-1s', 'abandoned', iso(NOW - 1000)],
    ['M-10d', 'merged', ago(14400)], ['C-10d', 'closed', ago(14400)],
    ['T-10d', 'triaged', ago(14400)], ['PL-10d', 'planned', ago(14400)],
    ['Q-121', 'in_queue', ago(121)], ['Q-119', 'in_queue', ago(119)],
    ['PR-20', 'pr_open', ago(20)], ['TK-1441', 'plan_blocked', ago(1441)], ['E-31', 'ejected', ago(31)], ['E-29', 'ejected', ago(29)],
  ];
  for (const [k, ph, at] of rows) seedRow(db, P, k, ph, at, 'seed');
  seedRow(db, P, 'NULL-10d');
  db.prepare("UPDATE build_queue SET updated_at = ? WHERE ticket_key = 'NULL-10d'").run(ago(14400));
  seedRow(db, 'l7-other', 'B-OTHER', 'building', ago(500));
  const keys = (b) => b.rows.map((r) => r.ticket_key).sort();
  const get = async (q = `?project=${P}`) => {
    const r = await call(DB, `/api/lifecycle/stuck${q}`);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    return r.body;
  };
  let b = await get();
  assert.deepEqual(keys(b), ['A-1s', 'B-181', 'E-31', 'TK-1441', 'Q-121']);
  assert.deepEqual(b.thresholds, { plan_blocked: 1440, ejected: 30, abandoned: 0, building: 180, in_queue: 120, pr_open: 1440 });
  assert.equal(b.as_of, iso(NOW));
  const b181 = b.rows.find((r) => r.ticket_key === 'B-181');
  assert.deepEqual([b181.project, b181.phase, b181.age_min, b181.threshold_min, b181.phase_actor], [P, 'building', 181, 180, 'seed']);
  assert.ok(Object.values(b.truncated).every((v) => v === false));
  // no project: every project's rows, the other tenant's included
  assert.ok(keys(await get('')).includes('B-OTHER'));
  // a row change moves the answer, no deploy
  setting(db, 'lifecycle.stuck.pr_open_min', '10');
  b = await get();
  assert.ok(keys(b).includes('PR-20'), 'pr_open at 10 min reports the 20-min row');
  assert.equal(b.thresholds.pr_open, 10);
  // bad values fall back to the code default, never clamp
  for (const bad of ['abc', '-5', '1.5', '']) {
    setting(db, 'lifecycle.stuck.in_queue_min', bad);
    b = await get();
    assert.equal(b.thresholds.in_queue, 120, `in_queue_min=${JSON.stringify(bad)} falls back`);
    assert.ok(keys(b).includes('Q-121') && !keys(b).includes('Q-119'));
  }
  // 0 means stuck at once
  setting(db, 'lifecycle.stuck.in_queue_min', '0');
  assert.ok(keys(await get()).includes('Q-119'));
  // a row for a phase with no default turns it on
  setting(db, 'lifecycle.stuck.triaged_min', '60');
  assert.ok(keys(await get()).includes('T-10d'));
  // limit + 1 measures truncation
  setting(db, 'lifecycle.stuck.limit', '1');
  setting(db, 'lifecycle.stuck.ejected_min', '1');
  b = await get();
  assert.equal(b.truncated.ejected, true);
  assert.equal(b.rows.filter((r) => r.phase === 'ejected').length, 1);
  assert.equal(b.rows.filter((r) => r.phase === 'ejected')[0].ticket_key, 'E-31', 'oldest first');
  assert.equal(b.truncated.building, false);
  // bad query
  assert.equal((await call(DB, "/api/lifecycle/stuck?project=a'b")).status, 400);
});

test('L8 EXPLAIN QUERY PLAN at 10 000 tickets / 200 000 events: the new indexes, no SCAN', { skip: SKIP }, async () => {
  const { db } = await fresh();
  const M = await R();
  const projects = ['cromford', 'project-3', 'project-4', 'project-1', 'project-5'];
  const base = Date.parse('2026-04-01T00:00:00Z');
  db.exec('BEGIN');
  const q = db.prepare(`INSERT INTO build_queue (project, ticket_key, status, enqueued_at, updated_at, phase, phase_at, phase_actor)
    VALUES (?, ?, 'done', '2026-04-01T00:00:00Z', '2026-04-01T00:00:00Z', ?, ?, 'pool')`);
  for (let i = 0; i < 10000; i++) q.run(projects[i % 5], `T-${i}`, PHASES[i % 10], iso(base + i * 60000));
  const e = db.prepare(`INSERT INTO ticket_events (project, ticket_key, from_phase, to_phase, actor, reason, pr, at)
    VALUES (?, ?, 'building', 'pr_open', 'pool', 'r', NULL, ?)`);
  for (let i = 0; i < 200000; i++) e.run(projects[i % 5], `T-${i % 10000}`, iso(base + i * 30000));
  db.exec('COMMIT');
  db.exec('ANALYZE');
  const planOf = (sql, binds) => db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...binds).map((r) => r.detail);
  const ret = RULES.find((r) => r.rule === 'ticket_events.age');
  assert.ok(ret, 'retention RULES has ticket_events.age');
  for (const [name, sql, binds, idx] of [
    ['stuck', M.STUCK_SQL, ['building', '2026-04-03T00:00:00Z', 201], 'idx_build_queue_phase_at'],
    ['stuck+project', M.STUCK_PROJECT_SQL, ['building', '2026-04-03T00:00:00Z', 'project-3', 201], 'idx_build_queue_phase_at'],
    ['history', M.HISTORY_SQL, ['project-3', 'T-17', 201], 'idx_ticket_events_project_ticket_id'],
    ['retention ids', ret.ids, ['2026-04-10T00:00:00Z', 500], 'idx_ticket_events_at'],
  ]) {
    assert.equal(typeof sql, 'string', `${name}: SQL exported`);
    const lines = planOf(sql, binds);
    assert.ok(lines.some((l) => l.includes(idx)), `${name}: ${idx} not used: ${lines.join(' | ')}`);
    assert.ok(!lines.some((l) => /^SCAN (build_queue|ticket_events)\b/.test(l)), `${name}: a SCAN: ${lines.join(' | ')}`);
    assert.ok(!lines.some((l) => /TEMP B-TREE/.test(l)), `${name}: sorts outside the index: ${lines.join(' | ')}`);
  }
});

test('L9 /history: newest first, truncated at the settings limit + 1, 400 on bad params', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  seedRow(db, 'l9', 'TK-9');
  for (const [to, actor] of [['triaged', 'triage'], ['planned', 'pool'], ['building', 'pool']]) {
    assert.equal((await move(DB, { project: 'l9', ticket_key: 'TK-9', to_phase: to, actor, reason: to })).status, 200);
  }
  let h = await call(DB, '/api/lifecycle/history?project=l9&ticket_key=TK-9');
  assert.equal(h.status, 200);
  assert.deepEqual(h.body.events.map((e) => e.to_phase), ['building', 'planned', 'triaged']);
  assert.equal(h.body.truncated, false);
  setting(db, 'lifecycle.history.limit', '2');
  h = await call(DB, '/api/lifecycle/history?project=l9&ticket_key=TK-9');
  assert.deepEqual(h.body.events.map((e) => e.to_phase), ['building', 'planned']);
  assert.equal(h.body.truncated, true);
  setting(db, 'lifecycle.history.limit', '3');
  h = await call(DB, '/api/lifecycle/history?project=l9&ticket_key=TK-9');
  assert.equal(h.body.truncated, false, 'exactly limit rows is not truncated');
  for (const q of ['?project=l9', '?ticket_key=TK-9', '?project=l9&ticket_key=a;b', "?project=L'9&ticket_key=TK-9"]) {
    const r = await call(DB, `/api/lifecycle/history${q}`);
    assert.equal(r.status, 400, q);
  }
});

test('L10 retention: old events are archived, never only deleted', { skip: SKIP }, async (tt) => {
  const NOW = Date.parse('2026-10-28T12:00:00Z');
  tt.mock.timers.enable({ apis: ['Date'], now: NOW });
  const ago = (d) => iso(NOW - d * 86400e3);
  const { DatabaseSync } = await import('node:sqlite');
  const rule = RULES.find((r) => r.rule === 'ticket_events.age');
  assert.ok(rule);
  assert.equal(rule.def, 180);
  assert.equal(rule.key, 'retention.ticket_events.days');
  assert.equal(rule.archive, 'ticket_events');
  const seed = (db) => {
    const ins = db.prepare(`INSERT INTO ticket_events (project, ticket_key, from_phase, to_phase, actor, reason, pr, at)
      VALUES ('l10', ?, NULL, 'triaged', 'triage', 'r', NULL, ?)`);
    for (const [k, d] of [['old-200', 200], ['old-181', 181], ['new-179', 179]]) ins.run(k, ago(d));
  };
  const keys = (db) => db.prepare('SELECT ticket_key FROM ticket_events ORDER BY ticket_key').all().map((r) => r.ticket_key);
  const run = (DB, extra) => call(DB, '/api/retention/run', { method: 'POST', body: {}, extra });
  const ruleOf = (b) => (b.rules || []).find((x) => x.rule === 'ticket_events.age');
  {
    const { db, DB } = await openDb();
    seed(db);
    const r = await run(DB, { ARCHIVE: d1(new DatabaseSync(':memory:')) });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(ruleOf(r.body).counted, 2, JSON.stringify(ruleOf(r.body)));
    assert.equal(ruleOf(r.body).removed, 0);
    assert.equal(keys(db).length, 3, 'a dry run removes nothing');
  }
  {
    const { db, DB } = await openDb();
    seed(db);
    setting(db, 'retention.dry_run', '0');
    const r = await run(DB, {});
    assert.equal(r.status, 200);
    assert.equal(ruleOf(r.body).removed, 0);
    assert.equal(keys(db).length, 3, 'an unbound archive moves nothing');
  }
  {
    const { db, DB } = await openDb();
    seed(db);
    setting(db, 'retention.dry_run', '0');
    const adb = new DatabaseSync(':memory:');
    const r = await run(DB, { ARCHIVE: d1(adb) });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(ruleOf(r.body).error, null, JSON.stringify(ruleOf(r.body)));
    assert.equal(ruleOf(r.body).removed, 2);
    assert.deepEqual(keys(db), ['new-179']);
    assert.deepEqual(adb.prepare('SELECT ticket_key FROM ticket_events ORDER BY ticket_key').all().map((x) => x.ticket_key),
      ['old-181', 'old-200'], 'copied before the delete');
  }
});

test('L11 the body lifecycle.sh sends is accepted by the route', { skip: SKIP }, async () => {
  const { db, DB } = await fresh();
  seedRow(db, 'project-3', 'TK-1');
  // The exact body tests/lifecycle-client.bh-8731-test.sh C1 asserts the lib sends.
  const body = JSON.parse('{"project":"project-3","ticket_key":"TK-1","to_phase":"planned","actor":"pool","reason":"plan ok","pr":12}');
  const r = await move(DB, body);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(eventsOf(db, 'project-3', 'TK-1')[0].pr, 12);
  seedRow(db, 'project-3', 'TK-2', 'building', '2026-10-20T00:00:00Z');
  const q = JSON.parse('{"project":"project-3","ticket_key":"TK-2","to_phase":"plan_blocked","actor":"pool","reason":"needs answer","question":"which fee?"}');
  const rq = await move(DB, q);
  assert.equal(rq.status, 200, JSON.stringify(rq.body));
  assert.equal(rowOf(db, 'project-3', 'TK-2').question, 'which fee?');
});
