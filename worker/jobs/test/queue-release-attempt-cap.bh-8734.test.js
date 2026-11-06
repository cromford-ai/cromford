import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';

// BH-8734 (slice C0): PATCH /api/queue with count_attempt — a release that
// COUNTS, and the cap that ends the row failed, driven through the worker's
// real fetch handler.
//
// THE CASE. BH-8841 ran 17 times for $15.73. Each run ended in a refused
// apply, the row stayed claimed, an orphan release put it back to `queued`,
// and the pool spawned it again. build_queue.attempt stayed at 2 the whole
// time, because the release PATCH never touched it. The counted release
// adds 1 to attempt, and the release that would pass
// queue.release_attempt_max writes `failed` instead of `queued`.
//
// THE FAKE D1 IS STATEFUL: the row read, today's PATCH statement and the
// counted statement each act on state.queue, and the counted statement is a
// compare-and-set on status='claimed', as the route writes it.

const SECRET = 'test-secret';
const P = 'cromford';

function fakeDB(state) {
  state.queue = state.queue || [];
  state.settings = state.settings || [];
  const calls = [];
  const norm = (sql) => sql.replace(/\s+/g, ' ').trim();
  const row = (p, k) => state.queue.find((q) => q.project === p && q.ticket_key === k);
  const exec = (sql, b) => {
    const s = norm(sql);
    calls.push({ sql: s, binds: b });
    if (/^PRAGMA table_info\(build_queue\)$/.test(s)) return { rows: [] };
    if (/^ALTER TABLE build_queue ADD COLUMN/.test(s)) return { changes: 0 };
    if (/^CREATE INDEX IF NOT EXISTS/.test(s)) return { changes: 0 };
    if (/^SELECT \* FROM settings ORDER BY key ASC$/.test(s)) return { rows: state.settings.map((r) => ({ ...r })) };
    if (/^SELECT \* FROM build_queue WHERE project=\?1 AND ticket_key=\?2$/.test(s)) {
      const r = row(b[0], b[1]);
      return { rows: r ? [{ ...r }] : [] };
    }
    // The counted release: one CAS UPDATE on status='claimed'.
    if (/^UPDATE build_queue SET status=\?3, reason=\?4, attempt=\?5, .* WHERE project=\?1 AND ticket_key=\?2 AND status='claimed'$/.test(s)) {
      const r = row(b[0], b[1]);
      if (state.moveBeforeWrite && r) r.status = 'done';
      if (!r || r.status !== 'claimed') return { changes: 0 };
      const q = b[2] === 'queued';
      Object.assign(r, {
        status: b[2], reason: b[3], attempt: b[4],
        claimed_by: q ? null : r.claimed_by, claimed_at: q ? null : r.claimed_at,
        machine: q ? null : r.machine,
        finished_at: b[2] === 'failed' ? b[5] : null, updated_at: b[5],
      });
      state.writes = (state.writes || 0) + 1;
      return { changes: 1 };
    }
    // Today's PATCH statement (no count_attempt).
    if (/^UPDATE build_queue SET status=\?3, reason=\?4, claimed_by=CASE/.test(s)) {
      const r = row(b[0], b[1]);
      if (!r) return { changes: 0 };
      const q = b[2] === 'queued';
      Object.assign(r, {
        status: b[2], reason: b[3],
        claimed_by: q ? null : r.claimed_by, claimed_at: q ? null : r.claimed_at,
        ...(/machine=NULL/.test(s) ? { machine: null } : {}),
        finished_at: b[4] === 1 ? b[5] : null, updated_at: b[5],
      });
      state.writes = (state.writes || 0) + 1;
      return { changes: 1 };
    }
    return { rows: [] };
  };
  const stmt = (sql) => {
    const bound = (binds) => ({
      first: async () => (exec(sql, binds).rows || [])[0] || null,
      all: async () => ({ results: exec(sql, binds).rows || [] }),
      run: async () => ({ meta: { changes: exec(sql, binds).changes ?? 0, last_row_id: 1 } }),
    });
    return { bind: (...b) => bound(b), ...bound([]) };
  };
  return { prepare: stmt, _calls: calls };
}

const patch = async (state, body) => {
  const db = fakeDB(state);
  const req = new Request('https://jobs.test/api/queue', {
    method: 'PATCH',
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: JSON.stringify({ project: P, ...body }),
  });
  const res = await worker.fetch(req, { DB: db, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json().catch(() => null), calls: db._calls };
};

// The live shape of BH-8841's row on 2026-11-03 (GET /api/queue).
const claimed = (key, attempt, extra = {}) => ({
  project: P, ticket_key: key, status: 'claimed', target: 'fly', attempt,
  claimed_by: 'box-hub', claimed_at: '2026-11-03T08:00:00Z', machine: 'm-dead',
  reason: null, finished_at: null, updated_at: '2026-11-03T08:00:00Z', ...extra,
});
const reclaim = (state, key) => Object.assign(state.queue.find((q) => q.ticket_key === key),
  { status: 'claimed', claimed_by: 'box-hub', claimed_at: '2026-11-03T09:00:00Z', machine: 'm2' });
const updates = (calls) => calls.filter((c) => /^UPDATE build_queue/.test(c.sql));
const WHY = 'orphan release: claimed by hub 1200s ago, machine m-dead absent, no hub owner';

test('W1 claimed attempt 0 + count_attempt -> queued, attempt 1, claimant and machine cleared', async () => {
  const state = { queue: [claimed('BH-1', 0)] };
  const r = await patch(state, { key: 'BH-1', status: 'queued', reason: WHY, count_attempt: true });
  assert.equal(r.status, 200);
  assert.equal(r.body.queued.status, 'queued');
  assert.equal(r.body.queued.attempt, 1);
  assert.equal(r.body.capped, false);
  assert.equal(r.body.attempt_max, 3);
  const q = state.queue[0];
  assert.deepEqual([q.status, q.attempt, q.claimed_by, q.machine], ['queued', 1, null, null]);
});

test('W2 (repro) attempt 2 -> queued 3; claimed again -> failed 4, capped, finished_at set', async () => {
  const state = { queue: [claimed('BH-8841', 2)] };
  let r = await patch(state, { key: 'BH-8841', status: 'queued', reason: WHY, count_attempt: true });
  assert.equal(r.status, 200);
  assert.equal(r.body.queued.status, 'queued');
  assert.equal(state.queue[0].attempt, 3, 'the release counts: attempt 2 -> 3');
  reclaim(state, 'BH-8841');
  r = await patch(state, { key: 'BH-8841', status: 'queued', reason: WHY, count_attempt: true });
  assert.equal(r.status, 200);
  assert.equal(r.body.queued.status, 'failed');
  assert.equal(r.body.queued.attempt, 4);
  assert.equal(r.body.capped, true);
  assert.equal(r.body.attempt_max, 3);
  const q = state.queue[0];
  assert.equal(q.status, 'failed');
  assert.equal(q.attempt, 4);
  assert.match(q.reason, /^release cap: attempt 4 of 3 \(queue\.release_attempt_max\); orphan release/);
  assert.ok(q.finished_at, 'a capped row is terminal: finished_at set');
});

test('W3 the loop: a fresh row is counted-released 4 times with N 3 -> 3 queued, then failed', async () => {
  const state = { queue: [claimed('BH-77', 0)] };
  const seen = [];
  for (let i = 0; i < 4; i++) {
    if (i > 0) reclaim(state, 'BH-77');
    const r = await patch(state, { key: 'BH-77', status: 'queued', reason: WHY, count_attempt: true });
    assert.equal(r.status, 200);
    seen.push(r.body.queued.status);
  }
  assert.deepEqual(seen, ['queued', 'queued', 'queued', 'failed']);
  assert.equal(state.queue[0].attempt, 4);
});

test('W4 attempt null -> attempt 1', async () => {
  const state = { queue: [claimed('BH-4', null)] };
  const r = await patch(state, { key: 'BH-4', status: 'queued', reason: WHY, count_attempt: true });
  assert.equal(r.body.queued.attempt, 1);
  assert.equal(state.queue[0].attempt, 1);
});

test('W5 count_attempt "true" (a string) -> today\'s statement, attempt unchanged', async () => {
  const s1 = { queue: [claimed('BH-5', 2)] };
  const a = await patch(s1, { key: 'BH-5', status: 'queued', reason: WHY, count_attempt: 'true' });
  const s2 = { queue: [claimed('BH-5', 2)] };
  const b = await patch(s2, { key: 'BH-5', status: 'queued', reason: WHY });
  assert.equal(a.status, 200);
  assert.equal(s1.queue[0].attempt, 2);
  assert.equal(s1.queue[0].status, 'queued');
  assert.deepEqual(updates(a.calls).map((c) => c.sql), updates(b.calls).map((c) => c.sql));
  assert.equal(a.body.capped, undefined, 'the uncounted answer is today\'s shape');
});

test('W6 count_attempt true + status failed -> today\'s path', async () => {
  const state = { queue: [claimed('BH-6', 2)] };
  const r = await patch(state, { key: 'BH-6', status: 'failed', reason: 'x', count_attempt: true });
  assert.equal(r.status, 200);
  assert.equal(state.queue[0].status, 'failed');
  assert.equal(state.queue[0].attempt, 2);
  assert.ok(!updates(r.calls).some((c) => /attempt=/.test(c.sql)));
});

test('W7 count_attempt true on a row that is not claimed -> 409 stale, nothing written', async () => {
  // A lane read the row claimed, then the reap ended it failed. failed->queued
  // is a legal transition, so without this the orphan release would re-queue
  // the failed row: the exact loop BH-8841 ran.
  for (const st of ['failed', 'done', 'queued']) {
    const state = { queue: [claimed('BH-7', 1, { status: st })] };
    const r = await patch(state, { key: 'BH-7', status: 'queued', reason: WHY, count_attempt: true });
    assert.equal(r.status, 409, st);
    assert.equal(r.body.error, 'stale');
    assert.equal(r.body.current, st);
    assert.equal(state.writes || 0, 0, st);
    assert.equal(state.queue[0].status, st);
    assert.equal(state.queue[0].attempt, 1);
  }
});

test('W8 settings row 5 -> cap at 5', async () => {
  const state = { queue: [claimed('BH-8', 4)], settings: [{ key: 'queue.release_attempt_max', value: '5' }] };
  let r = await patch(state, { key: 'BH-8', status: 'queued', reason: WHY, count_attempt: true });
  assert.equal(r.body.queued.status, 'queued');
  assert.equal(r.body.attempt_max, 5);
  reclaim(state, 'BH-8');
  r = await patch(state, { key: 'BH-8', status: 'queued', reason: WHY, count_attempt: true });
  assert.equal(r.body.queued.status, 'failed');
  assert.match(state.queue[0].reason, /^release cap: attempt 6 of 5/);
});

for (const bad of ['0', 'abc', '-1']) {
  test(`W9 settings row ${JSON.stringify(bad)} -> code default 3`, async () => {
    const state = { queue: [claimed('BH-9', 3)], settings: [{ key: 'queue.release_attempt_max', value: bad }] };
    const r = await patch(state, { key: 'BH-9', status: 'queued', reason: WHY, count_attempt: true });
    assert.equal(r.body.attempt_max, 3);
    assert.equal(r.body.queued.status, 'failed');
  });
}

test('W10 no settings row -> 3', async () => {
  const state = { queue: [claimed('BH-10', 2)] };
  const r = await patch(state, { key: 'BH-10', status: 'queued', reason: WHY, count_attempt: true });
  assert.equal(r.body.attempt_max, 3);
  assert.equal(r.body.queued.status, 'queued');
});

test('W11 CAS: the row moved to done between read and write -> 409 stale, nothing written', async () => {
  const state = { queue: [claimed('BH-11', 0)], moveBeforeWrite: true };
  const r = await patch(state, { key: 'BH-11', status: 'queued', reason: WHY, count_attempt: true });
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'stale');
  assert.equal(r.body.current, 'done');
  assert.equal(state.writes || 0, 0);
  assert.equal(state.queue[0].attempt, 0);
});

test('W12 a capped reason never reads as a deferral or a refusal to the watchdog sweep', async () => {
  const state = { queue: [claimed('BH-12', 3)] };
  const r = await patch(state, { key: 'BH-12', status: 'queued', reason: WHY, count_attempt: true });
  assert.equal(r.body.capped, true);
  assert.doesNotMatch(state.queue[0].reason, /refused|BUILD_DEFERRED/i);
});

test('W13 (adversarial) no count_attempt on a claimed row -> attempt unchanged (every existing caller)', async () => {
  const state = { queue: [claimed('BH-13', 3)] };
  const r = await patch(state, { key: 'BH-13', status: 'queued', reason: WHY });
  assert.equal(r.status, 200);
  assert.equal(state.queue[0].status, 'queued');
  assert.equal(state.queue[0].attempt, 3);
});

// W14 the composed schema seeds queue.release_attempt_max = 3, and the counted
// statement runs as real SQL (node:sqlite through the D1 shim), not a pattern.
test('W14 real SQL: the seeded row caps a counted release at 3', async (t) => {
  let DatabaseSync;
  try { ({ DatabaseSync } = await import('node:sqlite')); } catch { t.skip('node:sqlite unavailable'); return; }
  const { d1 } = await import('./lib/d1-sqlite.bh-1030.js');
  const { jobsSchemaSql } = await import('./lib/jobs-schema.js');
  const db = new DatabaseSync(':memory:');
  db.exec(jobsSchemaSql());
  assert.equal(db.prepare("SELECT value FROM settings WHERE key='queue.release_attempt_max'").get()?.value, '3');
  const put = (attempt) => {
    db.prepare('DELETE FROM build_queue WHERE project=? AND ticket_key=?').run(P, 'BH-14');
    db.prepare(`INSERT INTO build_queue (project, ticket_key, ticket_id, status, target, attempt, requested_by, claimed_by, claimed_at, machine, enqueued_at, updated_at)
      VALUES (?,?,?,'claimed','fly',?,'t','hub','2026-11-03T08:00:00Z','m1','2026-11-03T00:00:00Z','2026-11-03T00:00:00Z')`).run(P, 'BH-14', '14', attempt);
  };
  const env = { DB: d1(db), HARNESS_SECRET: SECRET };
  const send = async () => {
    const res = await worker.fetch(new Request('https://jobs.test/api/queue', {
      method: 'PATCH', headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
      body: JSON.stringify({ project: P, key: 'BH-14', status: 'queued', reason: WHY, count_attempt: true }),
    }), env);
    return { status: res.status, body: await res.json() };
  };
  put(2);
  let r = await send();
  assert.equal(r.body.queued.status, 'queued');
  let row = db.prepare('SELECT * FROM build_queue WHERE ticket_key=?').get('BH-14');
  assert.deepEqual([row.status, row.attempt, row.claimed_by, row.machine], ['queued', 3, null, null]);
  put(3);
  r = await send();
  assert.equal(r.body.capped, true);
  row = db.prepare('SELECT * FROM build_queue WHERE ticket_key=?').get('BH-14');
  assert.equal(row.status, 'failed');
  assert.equal(row.attempt, 4);
  assert.ok(row.finished_at);
  assert.equal(row.claimed_by, 'hub', 'a terminal row keeps its claimant as ledger');
  // A second counted release of the failed row is refused: never back to queued.
  r = await send();
  assert.equal(r.status, 409);
  row = db.prepare('SELECT * FROM build_queue WHERE ticket_key=?').get('BH-14');
  assert.deepEqual([row.status, row.attempt], ['failed', 4]);
});

// W15 two releasers (the pool and the watchdog) send a counted release for
// ONE claim: one 200, one 409 stale, and attempt moves by 1 only.
test('W15 two counted releases for one claim -> one 200, one 409 stale, attempt +1 once', async () => {
  const state = { queue: [claimed('BH-15', 1)] };
  const body = { key: 'BH-15', status: 'queued', reason: WHY, count_attempt: true };
  const [a, b] = await Promise.all([patch(state, body), patch(state, body)]);
  assert.deepEqual([a.status, b.status].sort(), [200, 409]);
  assert.equal((a.status === 409 ? a : b).body.error, 'stale');
  assert.equal(state.writes, 1);
  assert.equal(state.queue[0].attempt, 2);
  assert.equal(state.queue[0].status, 'queued');
});

// W16 the smallest legal N: settings row 1 caps at the 2nd counted release.
test('W16 settings row 1 -> the 2nd counted release ends the row failed', async () => {
  const state = { queue: [claimed('BH-16', 0)], settings: [{ key: 'queue.release_attempt_max', value: '1' }] };
  let r = await patch(state, { key: 'BH-16', status: 'queued', reason: WHY, count_attempt: true });
  assert.equal(r.body.queued.status, 'queued');
  assert.equal(r.body.attempt_max, 1);
  reclaim(state, 'BH-16');
  r = await patch(state, { key: 'BH-16', status: 'queued', reason: WHY, count_attempt: true });
  assert.equal(r.body.queued.status, 'failed');
  assert.equal(r.body.capped, true);
  assert.match(state.queue[0].reason, /^release cap: attempt 2 of 1 \(queue\.release_attempt_max\);/);
});
