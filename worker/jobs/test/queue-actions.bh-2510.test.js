import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';

// BH-3151 (BH-2510.1): POST /api/queue/action, the operator's audited RELEASE
// of a dead claim and DROP of a waiting row, driven through the worker's real
// fetch handler.
//
// THE FAKE D1 IS STATEFUL AND MODELS THE GUARDS (the job-abandon.bh-2406
// style): the row write is a compare-and-set on the status AND updated_at the
// route read, the stage_events INSERT only lands when the row is in the new
// state stamped with this request's clock, and both ride one batch. It also
// models the queue.js SQL a dropped or released row must then behave correctly
// against (enqueue, list with ?reason_deferred=1, keyed and unkeyed claim), so
// "a dropped row never builds" is asked of the real routes, not asserted.

const SECRET = 'test-secret';
const P = 'cromford';
const K = 'BH-9';
const T0 = '2026-09-25T10:00:00Z';
const DROPPED = 'DROPPED by operator (queue-action)';

function fakeDB(state) {
  state.queue = state.queue || [];
  state.events = state.events || [];
  if (state.hasMachine === undefined) state.hasMachine = true;
  if (state.hasHarnessCommit === undefined) state.hasHarnessCommit = state.hasMachine;
  // TEST-CHANGE (BH-8731): ensureColumns also adds the four lifecycle columns
  // (core.d/bh-8731-lifecycle.js); the fake reports them as harness_commit is.
  if (state.hasLifecycle === undefined) state.hasLifecycle = state.hasMachine;
  const calls = [];
  const batches = [];
  const norm = (sql) => sql.replace(/\s+/g, ' ').trim();
  const row = (p, k) => state.queue.find((q) => q.project === p && q.ticket_key === k);
  const like = (v, pat) => v != null && new RegExp(`^${pat.split('%').map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*')}$`, 's').test(String(v));
  const exec = (sql, b) => {
    const s = norm(sql);
    calls.push({ sql: s, binds: b });
    if (/^PRAGMA table_info\(build_queue\)$/.test(s)) {
      const cols = ['project', 'ticket_key', 'status', 'claimed_by', 'claimed_at', 'reason', 'updated_at'];
      return { rows: [...cols, ...(state.hasMachine ? ['machine'] : []), ...(state.hasHarnessCommit ? ['harness_commit'] : []),
        ...(state.hasLifecycle ? ['phase', 'phase_at', 'phase_actor', 'question'] : [])].map((name) => ({ name })) };
    }
    if (/^ALTER TABLE build_queue ADD COLUMN machine TEXT$/.test(s)) { state.hasMachine = true; return { changes: 0 }; }
    // BH-7302: ensureColumns also adds harness_commit; the fake reports it after.
    if (/^ALTER TABLE build_queue ADD COLUMN harness_commit TEXT$/.test(s)) { state.hasHarnessCommit = true; return { changes: 0 }; }
    // TEST-CHANGE (BH-8731): the lifecycle columns and their index.
    if (/^ALTER TABLE build_queue ADD COLUMN (phase|phase_at|phase_actor|question) TEXT$/.test(s)) {
      state.lifecycleAdded = [...(state.lifecycleAdded || []), s.split(' ')[5]];
      if (state.lifecycleAdded.length === 4) state.hasLifecycle = true;
      return { changes: 0 };
    }
    if (/^CREATE INDEX IF NOT EXISTS idx_build_queue_phase_at ON build_queue\(phase, phase_at\)$/.test(s)) return { changes: 0 };
    if (/^SELECT \* FROM build_queue WHERE project=\?1 AND ticket_key=\?2$/.test(s)) {
      const r = row(b[0], b[1]);
      return { rows: r ? [{ ...r }] : [] };
    }
    // RELEASE: claimed -> queued, CAS on status and the updated_at read.
    if (/^UPDATE build_queue SET status='queued', claimed_by=NULL, claimed_at=NULL, machine=NULL, reason=\?1, updated_at=\?2 WHERE project=\?3 AND ticket_key=\?4 AND status='claimed' AND updated_at=\?5$/.test(s)) {
      if (!state.hasMachine) throw new Error('D1_ERROR: no such column: machine');
      const r = row(b[2], b[3]);
      if (!r || r.status !== 'claimed' || r.updated_at !== b[4]) return { changes: 0 };
      Object.assign(r, { status: 'queued', claimed_by: null, claimed_at: null, machine: null, reason: b[0], updated_at: b[1] });
      return { changes: 1 };
    }
    // DROP: ready|queued -> failed, CAS on status and the updated_at read.
    if (/^UPDATE build_queue SET status='failed', finished_at=\?1, reason=\?2, updated_at=\?1 WHERE project=\?3 AND ticket_key=\?4 AND status=\?5 AND updated_at=\?6$/.test(s)) {
      const r = row(b[2], b[3]);
      if (!r || r.status !== b[4] || r.updated_at !== b[5]) return { changes: 0 };
      Object.assign(r, { status: 'failed', finished_at: b[0], reason: b[1], updated_at: b[0] });
      return { changes: 1 };
    }
    // The audit event, guarded on the row being in the new state at t.
    if (/^INSERT INTO stage_events \(job_id, stage, verdict, actor, detail, created_at\) SELECT \?1, 'queue', \?2, \?3, \?4, \?5 WHERE EXISTS \(SELECT 1 FROM build_queue WHERE project=\?6 AND ticket_key=\?7 AND status=\?8 AND reason=\?9 AND updated_at=\?5\)$/.test(s)) {
      const r = row(b[5], b[6]);
      if (!r || r.status !== b[7] || r.reason !== b[8] || r.updated_at !== b[4]) return { changes: 0 };
      state.events.push({ job_id: b[0], stage: 'queue', verdict: b[1], actor: b[2], detail: b[3], created_at: b[4] });
      return { changes: 1 };
    }
    // ---- queue.js, verbatim shapes ----
    if (/^INSERT INTO build_queue .* ON CONFLICT\(project, ticket_key\) DO UPDATE SET/.test(s)) {
      const r = row(b[0], b[1]);
      const fresh = { status: b[8], target: b[3], attempt: b[4], claimed_by: null, claimed_at: null, machine: null, enqueued_at: b[6], finished_at: null, reason: null, updated_at: b[6] };
      if (r) Object.assign(r, fresh); else state.queue.push({ project: b[0], ticket_key: b[1], ...fresh });
      return { changes: 1 };
    }
    if (/^SELECT \* FROM build_queue WHERE project=\?1 AND ticket_key=\?2 AND status='queued'$/.test(s)) {
      const r = row(b[0], b[1]);
      return { rows: r && r.status === 'queued' ? [{ ...r }] : [] };
    }
    if (/^SELECT \* FROM build_queue WHERE project=\?1 AND status='queued' ORDER BY/.test(s)) {
      return { rows: state.queue.filter((q) => q.project === b[0] && q.status === 'queued').map((q) => ({ ...q })) };
    }
    if (/^UPDATE build_queue SET status='claimed', claimed_by=\?3, claimed_at=\?4, updated_at=\?4 WHERE project=\?1 AND ticket_key=\?2 AND status='queued'$/.test(s)) {
      const r = row(b[0], b[1]);
      if (!r || r.status !== 'queued') return { changes: 0 };
      Object.assign(r, { status: 'claimed', claimed_by: b[2], claimed_at: b[3], updated_at: b[3] });
      return { changes: 1 };
    }
    if (/^SELECT \* FROM build_queue WHERE project=\?1 AND \(reason LIKE \?2 OR reason LIKE \?3\) ORDER BY enqueued_at ASC LIMIT \d+$/.test(s)) {
      return { rows: state.queue.filter((q) => q.project === b[0] && (like(q.reason, b[1]) || like(q.reason, b[2]))).map((q) => ({ ...q })) };
    }
    throw new Error(`fake D1: unmodelled statement: ${s}`);
  };
  const bound = (sql, binds) => ({
    _sql: sql, _binds: binds,
    first: async () => (exec(sql, binds).rows || [])[0] || null,
    all: async () => ({ results: exec(sql, binds).rows || [] }),
    run: async () => ({ meta: { changes: exec(sql, binds).changes || 0, last_row_id: 1 } }),
  });
  return {
    prepare: (sql) => ({ ...bound(sql, []), bind: (...binds) => bound(sql, binds) }),
    // D1's batch is one transaction: run in order, all-or-nothing.
    batch: async (stmts) => {
      if (state.beforeBatch) state.beforeBatch();
      const snap = JSON.stringify({ q: state.queue, e: state.events });
      batches.push(stmts.map((st) => norm(st._sql)));
      try {
        return stmts.map((st) => ({ meta: { changes: exec(st._sql, st._binds).changes || 0 } }));
      } catch (e) {
        const back = JSON.parse(snap);
        state.queue.splice(0, state.queue.length, ...back.q);
        state.events.splice(0, state.events.length, ...back.e);
        throw e;
      }
    },
    _calls: calls, _batches: batches,
  };
}

const call = (path, { method = 'POST', body = {}, state = {} } = {}) => {
  const db = fakeDB(state);
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: method === 'GET' ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB: db, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null), db, state,
  }));
};

const Q = (over) => ({
  project: P, ticket_key: K, ticket_id: 'id-9', status: 'queued', target: 'fly', attempt: 2,
  requested_by: 'hub-1', claimed_by: null, claimed_at: null, machine: null,
  enqueued_at: T0, finished_at: null, reason: null, meta: null, updated_at: T0, ...over,
});
const act = (body, state) => call('/api/queue/action', { body: { project: P, key: K, actor: 'console', ...body }, state });
const writes = (db) => db._calls.filter((c) => /^(UPDATE|INSERT|DELETE|ALTER)/.test(c.sql));

// ---- 1: RELEASE ---------------------------------------------------------------
test('1: RELEASE a claimed row hands it back to the claim path, with one audited event', async () => {
  const state = { queue: [Q({ status: 'claimed', claimed_by: 'fly-pool', claimed_at: T0, machine: 'm-1' })] };
  const r = await act({ action: 'release', reason: '  box died mid-build  ' }, state);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.decision, 'released');
  assert.equal(r.body.previous_status, 'claimed');
  assert.equal(r.body.status, 'queued');
  assert.equal(r.body.reason, 'box died mid-build');
  assert.equal(r.body.actor, 'console');
  const row = state.queue[0];
  assert.equal(row.status, 'queued');
  assert.equal(row.claimed_by, null);
  assert.equal(row.claimed_at, null);
  assert.equal(row.machine, null);
  assert.equal(row.attempt, 2, 'attempt is untouched');
  assert.equal(row.reason, 'RELEASED by operator');
  assert.equal(r.db._batches.length, 1, 'one batch');
  assert.equal(state.events.length, 1);
  const ev = state.events[0];
  assert.deepEqual({ job_id: ev.job_id, stage: ev.stage, verdict: ev.verdict, actor: ev.actor },
    { job_id: `queue:${P}/${K}`, stage: 'queue', verdict: 'RELEASED', actor: 'console' });
  assert.deepEqual(JSON.parse(ev.detail), { reason: 'box died mid-build', from: 'claimed', to: 'queued' });

  const c = await call('/api/queue/claim', { body: { project: P, box: 'hub-2' }, state });
  assert.equal(c.status, 200, JSON.stringify(c.body));
  assert.equal(c.body.claimed, true);
  assert.equal(state.queue[0].claimed_by, 'hub-2');
});

test('1b: RELEASE on a table that predates `machine` widens it first', async () => {
  const state = { hasMachine: false, queue: [Q({ status: 'claimed', claimed_by: 'hub-1', claimed_at: T0 })] };
  const r = await act({ action: 'release', reason: 'dead' }, state);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(state.hasMachine, true);
  assert.equal(state.queue[0].status, 'queued');
  assert.equal(state.events.length, 1);
});

// ---- 2: RELEASE refused -------------------------------------------------------
for (const status of ['queued', 'ready', 'done', 'failed']) {
  test(`2: RELEASE on a ${status} row is a 409, row unchanged, no event`, async () => {
    const state = { queue: [Q({ status, reason: status === 'failed' ? 'died 3 times' : null })] };
    const before = JSON.stringify(state.queue);
    const r = await act({ action: 'release', reason: 'dead' }, state);
    assert.equal(r.status, 409, JSON.stringify(r.body));
    assert.equal(r.body.refused, true);
    assert.equal(r.body.status, status);
    assert.equal(JSON.stringify(state.queue), before);
    assert.equal(state.events.length, 0);
    assert.deepEqual(writes(r.db), []);
  });
}

// ---- 3: DROP ------------------------------------------------------------------
for (const status of ['queued', 'ready']) {
  test(`3: DROP a ${status} row: failed with the FIXED reason, one event, and it never builds`, async () => {
    const state = { queue: [Q({ status })] };
    const r = await act({ action: 'drop', reason: 'REFUSED by client' }, state);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.decision, 'dropped');
    assert.equal(r.body.previous_status, status);
    assert.equal(r.body.status, 'failed');
    const row = state.queue[0];
    assert.equal(row.status, 'failed');
    assert.equal(row.reason, DROPPED, 'the operator text never reaches the row');
    assert.ok(row.finished_at && row.finished_at === row.updated_at && row.updated_at !== T0, 'finished_at = t');
    assert.equal(state.events.length, 1);
    assert.equal(state.events[0].verdict, 'DROPPED');
    assert.equal(state.events[0].job_id, `queue:${P}/${K}`);
    assert.deepEqual(JSON.parse(state.events[0].detail), { reason: 'REFUSED by client', from: status, to: 'failed' });

    const unkeyed = await call('/api/queue/claim', { body: { project: P, box: 'hub-2' }, state });
    assert.equal(unkeyed.status, 404, JSON.stringify(unkeyed.body));
    const keyed = await call('/api/queue/claim', { body: { project: P, box: 'hub-2', key: K }, state });
    assert.equal(keyed.status, 404, JSON.stringify(keyed.body));
    assert.notEqual(keyed.body.claimed, true);
    assert.equal(state.queue[0].status, 'failed');

    const ready = await call('/api/queue', { body: { project: P, key: K, status: 'ready' }, state });
    assert.equal(ready.status, 200, JSON.stringify(ready.body));
    assert.equal(ready.body.duplicate, true);
    assert.equal(state.queue[0].status, 'failed');

    const deferred = await call(`/api/queue?project=${P}&reason_deferred=1`, { method: 'GET', state });
    assert.equal(deferred.status, 200);
    assert.deepEqual(deferred.body.queue.map((q) => q.ticket_key), [], 'the watchdog never re-queues a DROP');
  });
}

test('3: the reason_deferred probe is live: a REFUSED row is listed (so the exclusion above is real)', async () => {
  const state = { queue: [Q({ status: 'failed', reason: 'REFUSED by client' })] };
  const r = await call(`/api/queue?project=${P}&reason_deferred=1`, { method: 'GET', state });
  assert.deepEqual(r.body.queue.map((q) => q.ticket_key), [K]);
});

test('3: an explicit build enqueue re-queues a dropped row (the relaunch the DROP copy promises)', async () => {
  const state = { queue: [Q({ status: 'failed', reason: DROPPED, finished_at: T0 })] };
  const r = await call('/api/queue', { body: { project: P, key: K }, state });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(state.queue[0].status, 'queued');
});

test('3b: DROP again answers already, writes nothing, still one event', async () => {
  const state = { queue: [Q({ status: 'queued' })] };
  const first = await act({ action: 'drop', reason: 'dup' }, state);
  assert.equal(first.status, 200);
  const again = await act({ action: 'drop', reason: 'dup' }, state);
  assert.equal(again.status, 200, JSON.stringify(again.body));
  assert.equal(again.body.decision, 'already');
  assert.deepEqual(writes(again.db), []);
  assert.equal(state.events.length, 1);
});

for (const [status, reason] of [['failed', 'died 3 times'], ['done', 'RESULT: merged'], ['dropped', null]]) {
  test(`3b: DROP on a ${status} row (${reason}) is a 409 and the ledger reason survives`, async () => {
    const state = { queue: [Q({ status, reason })] };
    const before = JSON.stringify(state.queue);
    const r = await act({ action: 'drop', reason: 'x' }, state);
    assert.equal(r.status, 409, JSON.stringify(r.body));
    assert.equal(r.body.refused, true);
    assert.equal(JSON.stringify(state.queue), before);
    assert.equal(state.events.length, 0);
    assert.deepEqual(writes(r.db), []);
  });
}

// ---- 4: DROP refused on a live claim ------------------------------------------
test('4: DROP on a claimed row is a 409 pointing at ABANDON, row unchanged, no event', async () => {
  const state = { queue: [Q({ status: 'claimed', claimed_by: 'fly-pool', claimed_at: T0, machine: 'm-1' })] };
  const before = JSON.stringify(state.queue);
  const r = await act({ action: 'drop', reason: 'stop it' }, state);
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.refused, true);
  assert.match(r.body.error, /ABANDON the job instead/);
  assert.equal(JSON.stringify(state.queue), before);
  assert.equal(state.events.length, 0);
  assert.deepEqual(writes(r.db), []);
});

// ---- 5: validation before any DB touch ----------------------------------------
for (const [name, body] of [
  ['blank reason', { action: 'drop', reason: '' }],
  ['whitespace reason', { action: 'drop', reason: '   ' }],
  ['missing reason', { action: 'drop' }],
  ['missing actor', { action: 'drop', reason: 'x', actor: undefined }],
  ['blank actor', { action: 'drop', reason: 'x', actor: '  ' }],
  ['unknown action hold', { action: 'hold', reason: 'x' }],
  ['action with trailing space', { action: 'release ', reason: 'x' }],
  ['action abandon', { action: 'abandon', reason: 'x' }],
  ['project a/b', { action: 'drop', reason: 'x', project: 'a/b' }],
  ['key with a space', { action: 'drop', reason: 'x', key: 'BH 9' }],
]) {
  test(`5: ${name} is a 400 and nothing is read or written`, async () => {
    const state = { queue: [Q({ status: 'queued' })] };
    const before = JSON.stringify(state.queue);
    const r = await act(body, state);
    assert.equal(r.status, 400, JSON.stringify(r.body));
    assert.deepEqual(r.db._calls, [], 'validation runs before any statement');
    assert.equal(JSON.stringify(state.queue), before);
    assert.equal(state.events.length, 0);
  });
}

test('5: a missing row is a 404 with nothing written', async () => {
  const r = await act({ action: 'drop', reason: 'x', key: 'BH-404' }, { queue: [Q()] });
  assert.equal(r.status, 404, JSON.stringify(r.body));
  assert.deepEqual(writes(r.db), []);
});

// ---- 6: a lost CAS -----------------------------------------------------------
for (const [action, status, to] of [['release', 'claimed', 'claimed'], ['drop', 'queued', 'claimed']]) {
  test(`6: ${action} that loses its CAS (row moved between read and batch) is a 409 with zero events`, async () => {
    const state = { queue: [Q({ status, claimed_by: status === 'claimed' ? 'hub-1' : null })] };
    // Another box re-claims the row after the route read it.
    state.beforeBatch = () => Object.assign(state.queue[0], { status: to, claimed_by: 'hub-3', updated_at: '2026-09-25T10:05:00Z' });
    const r = await act({ action, reason: 'dead' }, state);
    assert.equal(r.status, 409, JSON.stringify(r.body));
    assert.equal(r.body.error, 'row moved, reload');
    assert.equal(r.body.refused, true);
    assert.equal(state.queue[0].status, to);
    assert.equal(state.queue[0].claimed_by, 'hub-3', 'the new claim is not released');
    assert.equal(state.events.length, 0);
  });
}
