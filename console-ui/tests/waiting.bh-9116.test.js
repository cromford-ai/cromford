// BH-9116: the "To do (waiting)" view. The pure classifier
// (src/lib/waiting.js), the Pages Function
// (functions/api/dash/kanban/waiting.js) with the jobs worker's real
// POST /api/waiting/state route over a seeded node:sqlite D1, and the
// rendered table.
//   C1 the plan's decision table, one assert per row
//   C2 the deferral matcher: positives and negatives
//   C3 the stale-claim knob flips the same claim with no deploy
//   C4 one ticket per reason: each key once, counts sum to rows
//   C5 dropStaleClaims: removes the exact pair, keeps another project's
//   C6 the reconcile block adds up to the total
//   F1 the snapshot read answers 401: 401 back, no jobs call
//   F2 the seeded board end to end (acceptance 1): every reason once
//   F3 the jobs read fails: ok:false, no rows
//   F4 ?project= filters; a bad name is 400; a non-GET is 405
//   R1 the rendered table: counts, sort headers, links, the warn banner
import test from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';
import { renderToString } from 'preact-render-to-string';

import {
  WAITING_REASONS, classifyWaiting, dropStaleClaims, isDeferral, openTickets
} from '../src/lib/waiting.js';
import { onRequest } from '../functions/api/dash/kanban/waiting.js';
import { WaitingView } from '../src/screens/WaitingPanel.js';

// The route module, not the worker entry: worker/jobs/src/index.js imports
// catalog/lanes.json (a git-ignored render the SPA CI job does not write), and
// a console-ui import of index.js would put the SPA job on every worker change
// (tests/ci-plan-spa-worker.bh-4969-test.sh B2). worker/jobs/test/
// waiting.bh-9116.test.js drives the same route through index.js. If the
// modules do not import, the F cases that drive the route skip and say why;
// every other case still runs.
let waitingRoutes = null;
let openDb = null;
let wSkip = '';
try {
  ({ routes: waitingRoutes } = await import('../../worker/jobs/src/routes/waiting.js'));
  ({ openDb } = await import('../../worker/jobs/test/lib/d1-sqlite.bh-1030.js'));
} catch (e) {
  wSkip = `the worker modules do not import here (${e.code || e.message})`;
  console.log(`# SKIP worker cases: ${wSkip}`);
}
// The jobs worker's dispatch for this one route: the bearer gate
// (lib/http.js bearerOk), the JSON body, then the route's handler.
async function workerFetch(req, env) {
  const auth = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!env.HARNESS_SECRET || auth !== env.HARNESS_SECRET) return jsonRes(401, { error: 'unauthorized' });
  const url = new URL(req.url);
  const hit = waitingRoutes.find(([m, path]) => m === req.method && path === url.pathname);
  if (!hit) return jsonRes(404, { error: 'unknown endpoint', worker: 'harness-jobs' });
  let body = {};
  try { body = await req.json(); } catch { body = {}; }
  const t = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'); // determinism: ok — the worker's nowIso(); the seeded rows are offsets from the same clock
  return hit[2]({ req, env, url, path: url.pathname, t, body });
}

const NOW = Date.parse('2026-11-05T22:00:00Z');
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (m) => iso(NOW - m * 60000);
const P = 'project-3';

const tk = (key, o = {}) => ({
  key, status: 'todo', title: `title ${key}`, updatedAt: ago(120), triage_verdict: 'untriaged',
  waiting_on: '', id: '', url: '', ...o
});
const snap = (projects, ageS = 300) => ({
  generated_at: Math.floor(NOW / 1000) - ageS,
  projects: Object.fromEntries(Object.entries(projects).map(([p, tickets]) => [p, { board_id: 'b-fixture', tickets }]))
});
const state = (o = {}) => ({
  triage: [], queue: [], positions: [], live_jobs: [], parked_jobs: [], edges: [],
  knobs: { stale_claim_min: 30, max_tickets: 2000, defer_lookback_min: 10080 },
  truncated: false, positions_truncated: false, as_of: iso(NOW), ...o
});
const tri = (key, verdict, o = {}) => ({
  project: P, ticket_key: key, input_hash: 'h1', verdict, verdict_hash: 'h1', waiting_on: null,
  triaged_at: ago(60), reason: 'DECISION', updated_at: ago(60), ...o
});
const q = (key, status, o = {}) => ({
  project: P, ticket_key: key, status, claimed_by: null, claimed_at: null, enqueued_at: ago(90),
  finished_at: null, reason: null, machine: null, updated_at: ago(90), ...o
});
const run = (snapshot, st, opts = {}) => classifyWaiting(snapshot, st, { now: NOW, ...opts });
const rowOf = (out, key, project = P) => out.rows.find((r) => r.key === key && r.project === project);

// ------------------------------------------------------------------ C1

test('C1 the decision table, one row each', () => {
  const B = 'buildable';
  // [name, tickets (project-3), state, extra projects, key, expected]
  // expected: a reason, 'excluded' (in flight), or 'absent' (not a candidate)
  const cases = [
    ['todo, no triage row, board untriaged', [tk('K')], state(), {}, 'K', 'not-triaged'],
    ['stale hash, board untriaged', [tk('K')], state({ triage: [tri('K', B, { verdict_hash: 'h0' })] }), {}, 'K', 'not-triaged'],
    ['stale hash, board buildable', [tk('K', { triage_verdict: B })], state({ triage: [tri('K', B, { verdict_hash: 'h0' })] }), {}, 'K', 'ready-not-queued'],
    ['needs_clarification, requester', [tk('K', { waiting_on: 'requester' })], state({ triage: [tri('K', 'needs_clarification')] }), {}, 'K', 'needs-clarification'],
    ['review, waiting_on Client', [tk('K', { status: 'review', waiting_on: 'Client', triage_verdict: B })], state(), {}, 'K', 'needs-clarification'],
    ['review, waiting_on team', [tk('K', { status: 'review', waiting_on: 'team', triage_verdict: B })], state(), {}, 'K', 'excluded'],
    ['review, waiting_on empty', [tk('K', { status: 'review', triage_verdict: B })], state(), {}, 'K', 'excluded'],
    ['hard parent open', [tk('K'), tk('PAR')], state({ triage: [tri('K', B)], edges: [{ project: P, parent: 'PAR', child: 'K', kind: 'hard' }] }), {}, 'K', 'blocked-by'],
    ['hard parent done', [tk('K'), tk('PAR', { status: 'done' })], state({ triage: [tri('K', B)], edges: [{ project: P, parent: 'PAR', child: 'K', kind: 'hard' }] }), {}, 'K', 'ready-not-queued'],
    ['soft parent open', [tk('K'), tk('PAR')], state({ triage: [tri('K', B)], edges: [{ project: P, parent: 'PAR', child: 'K', kind: 'soft' }] }), {}, 'K', 'ready-not-queued'],
    ['parent key open only in another project', [tk('K')], state({ triage: [tri('K', B)], edges: [{ project: P, parent: 'PAR', child: 'K', kind: 'hard' }, { project: 'project-4', parent: 'PAR', child: 'K', kind: 'hard' }] }), { 'project-4': [tk('PAR')] }, 'K', 'ready-not-queued'],
    ['buildable, no queue row', [tk('K')], state({ triage: [tri('K', B)] }), {}, 'K', 'ready-not-queued'],
    ['buildable, done PR_MERGED', [tk('K')], state({ triage: [tri('K', B)], queue: [q('K', 'done', { reason: 'PR_MERGED' })] }), {}, 'K', 'ready-not-queued'],
    ['queued, ready status', [tk('K')], state({ triage: [tri('K', B)], queue: [q('K', 'ready')] }), {}, 'K', 'queued'],
    ['failed BUILD_DEFERRED OVERLAP_DEFER', [tk('K')], state({ triage: [tri('K', B)], queue: [q('K', 'failed', { reason: 'BUILD_DEFERRED OVERLAP_DEFER sibling BH-1' })] }), {}, 'K', 'deferred'],
    ['done BUILD_DEFERRED lock held', [tk('K')], state({ triage: [tri('K', B)], queue: [q('K', 'done', { reason: 'BUILD_DEFERRED lock held on partner-office-2' })] }), {}, 'K', 'deferred'],
    ['newest job parked', [tk('K')], state({ triage: [tri('K', B)], parked_jobs: [{ id: 'build-project-3-K-1', project: P, ticket_id: 'K', status: 'parked', updated_at: ago(30), reason: 'ci repair rounds out' }] }), {}, 'K', 'deferred'],
    ['parked older than lookback (not sent)', [tk('K')], state({ triage: [tri('K', B)] }), {}, 'K', 'ready-not-queued'],
    ['done "deferred to the user"', [tk('K')], state({ triage: [tri('K', B)], queue: [q('K', 'done', { reason: 'deferred to the user' })] }), {}, 'K', 'ready-not-queued'],
    ['failed "review BLOCK: budget table missing"', [tk('K')], state({ triage: [tri('K', B)], queue: [q('K', 'failed', { reason: 'review BLOCK: budget table missing' })] }), {}, 'K', 'ready-not-queued'],
    ['claimed 45 min, no live job', [tk('K')], state({ triage: [tri('K', B)], queue: [q('K', 'claimed', { claimed_at: ago(45), claimed_by: 'fly-1' })] }), {}, 'K', 'stale-claim'],
    ['claimed 45 min, live job beat 2 min', [tk('K')], state({ triage: [tri('K', B)], queue: [q('K', 'claimed', { claimed_at: ago(45) })], live_jobs: [{ id: 'j1', project: P, ticket_id: 'K', status: 'running', updated_at: ago(40), beat_at: ago(2) }] }), {}, 'K', 'excluded'],
    ['claimed 45 min, job beat 40 min ago', [tk('K')], state({ triage: [tri('K', B)], queue: [q('K', 'claimed', { claimed_at: ago(45) })], live_jobs: [{ id: 'j1', project: P, ticket_id: 'K', status: 'running', updated_at: ago(44), beat_at: ago(40) }] }), {}, 'K', 'stale-claim'],
    ['claimed 5 min, no job yet', [tk('K')], state({ triage: [tri('K', B)], queue: [q('K', 'claimed', { claimed_at: ago(5) })] }), {}, 'K', 'excluded'],
    ['in_progress, claimed 45, no live job', [tk('K', { status: 'in_progress' })], state({ triage: [tri('K', B)], queue: [q('K', 'claimed', { claimed_at: ago(45) })] }), {}, 'K', 'stale-claim'],
    ['in_progress, no claim', [tk('K', { status: 'in_progress' })], state({ triage: [tri('K', B)] }), {}, 'K', 'excluded'],
    ['verdict triaged (no rule)', [tk('K')], state({ triage: [tri('K', 'triaged')] }), {}, 'K', 'other'],
    ['done', [tk('K', { status: 'done' })], state({ triage: [tri('K', B)] }), {}, 'K', 'absent'],
  ];
  for (const [name, tickets, st, extra, key, want] of cases) {
    const out = run(snap({ [P]: tickets, ...extra }), st);
    const row = rowOf(out, key);
    if (want === 'excluded') {
      assert.equal(row, undefined, `${name}: must not be a row`);
      assert.ok(out.in_flight >= 1, `${name}: counted in flight`);
    } else if (want === 'absent') {
      assert.equal(row, undefined, `${name}: must not be a row`);
      assert.equal(out.in_flight, 0, `${name}: not counted in flight either`);
    } else {
      assert.ok(row, `${name}: no row`);
      assert.equal(row.reason, want, `${name}`);
    }
  }

  // The detail each reason row carries.
  const qd = run(snap({ [P]: [tk('A'), tk('B'), tk('C')] }), state({
    triage: ['A', 'B', 'C'].map((k) => tri(k, 'buildable')),
    queue: [q('A', 'queued', { enqueued_at: ago(10) }), q('B', 'queued', { enqueued_at: ago(20) }), q('C', 'queued', { enqueued_at: ago(5) })],
    positions: [
      { project: P, ticket_key: 'X-OLD', enqueued_at: ago(30) }, { project: P, ticket_key: 'B', enqueued_at: ago(20) },
      { project: P, ticket_key: 'A', enqueued_at: ago(10) }, { project: P, ticket_key: 'C', enqueued_at: ago(5) }
    ]
  }));
  assert.equal(rowOf(qd, 'C').position, 4);
  assert.equal(rowOf(qd, 'A').position, 3, 'the 3rd oldest of the project is position 3');
  assert.equal(rowOf(qd, 'A').age_min, 10, 'queued age runs from enqueued_at');

  const bl = run(snap({ [P]: [tk('K'), tk('PAR', { url: 'https://board.example/t/PAR' })] }),
    state({ triage: [tri('K', 'buildable')], edges: [{ project: P, parent: 'PAR', child: 'K', kind: 'hard' }] }));
  assert.deepEqual(rowOf(bl, 'K').blocker, { key: 'PAR', url: 'https://board.example/t/PAR', route: '/t/PAR' });

  const nc = run(snap({ [P]: [tk('K', { waiting_on: 'requester' })] }), state({ triage: [tri('K', 'needs_clarification')] }));
  assert.equal(rowOf(nc, 'K').waiting_on, 'requester');

  const df = run(snap({ [P]: [tk('K')] }), state({ triage: [tri('K', 'buildable')], queue: [q('K', 'failed', { reason: 'BUILD_DEFERRED OVERLAP_DEFER sibling BH-1 ' + 'x'.repeat(400) })] }));
  assert.match(rowOf(df, 'K').reason_text, /^BUILD_DEFERRED OVERLAP_DEFER sibling BH-1/);
  assert.ok(rowOf(df, 'K').reason_text.length <= 200);
  // The cut is the knob waiting.reason_text_max, read from the jobs answer.
  const df20 = run(snap({ [P]: [tk('K')] }), state({ triage: [tri('K', 'buildable')], queue: [q('K', 'failed', { reason: 'BUILD_DEFERRED OVERLAP_DEFER sibling BH-1' })],
    knobs: { stale_claim_min: 30, max_tickets: 2000, defer_lookback_min: 10080, reason_text_max: 14 } }));
  assert.equal(rowOf(df20, 'K').reason_text, 'BUILD_DEFERRED');
});

// ------------------------------------------------------------------ C2

test('C2 the deferral matcher', () => {
  for (const s of ['BUILD_DEFERRED file overlap', 'x OVERLAP_DEFER y', 'REFUSED budget :: stage-day', 'spawn cap reached',
    'spawn-hold', 'wip limit 3', 'WIP-limit', 'lock held on partner-office-2', 'budget cap hit', 'budget-project-day',
    'usd-cap-day', 'job parked']) {
    assert.equal(isDeferral(s), true, s);
  }
  for (const s of ['deferred to the user', 'review BLOCK: budget table missing', 'PR_MERGED', 'parkedcar', 'wip: notes',
    'a BUILD_DEFERRED later', '', null, undefined, 42]) {
    assert.equal(isDeferral(s), false, String(s));
  }
});

// ------------------------------------------------------------------ C3

test('C3 stale_claim_min decides the same claim, no deploy', () => {
  const tickets = [tk('K', { triage_verdict: 'buildable' })];
  const queue = [q('K', 'claimed', { claimed_at: ago(45) })];
  const at30 = run(snap({ [P]: tickets }), state({ queue }));
  assert.equal(rowOf(at30, 'K').reason, 'stale-claim');
  assert.deepEqual(at30.stale_claims, [{ project: P, key: 'K', id: null }]);
  const at60 = run(snap({ [P]: tickets }), state({ queue, knobs: { stale_claim_min: 60, max_tickets: 2000, defer_lookback_min: 10080 } }));
  assert.equal(rowOf(at60, 'K'), undefined);
  assert.equal(at60.in_flight, 1);
  assert.deepEqual(at60.stale_claims, []);
  // A junk knob falls back to 30, never to "everything is stale".
  const junk = run(snap({ [P]: tickets }), state({ queue, knobs: { stale_claim_min: 'x' } }));
  assert.equal(junk.knobs.stale_claim_min, 30);
  assert.equal(rowOf(junk, 'K').reason, 'stale-claim');
});

// ------------------------------------------------------------------ C4 / C6

// One ticket per reason, plus three in flight, one done, and a same-key
// ticket in another project with nothing on record.
export function seededBoard() {
  const tickets = [
    tk('NT-1'),
    tk('NC-2', { waiting_on: 'client', triage_verdict: 'needs_clarification' }),
    tk('BB-3', { triage_verdict: 'buildable' }),
    tk('RQ-4', { triage_verdict: 'buildable' }),
    tk('QU-5', { triage_verdict: 'buildable' }),
    tk('DF-6', { triage_verdict: 'buildable' }),
    tk('SC-7', { triage_verdict: 'buildable', status: 'in_progress', claim: { pr: 77, pr_url: 'https://github.com/o/r/pull/77' } }),
    tk('OT-8', { triage_verdict: 'triaged' }),
    tk('RV-9', { status: 'review', waiting_on: 'team', triage_verdict: 'buildable' }),
    tk('RC-10', { status: 'review', waiting_on: 'client', triage_verdict: 'needs_clarification' }),
    tk('IF-11', { triage_verdict: 'buildable' }),
    tk('DN-12', { status: 'done' })
  ];
  return {
    snapshot: snap({ [P]: tickets, 'project-4': [tk('NT-1', { triage_verdict: 'buildable' })] }),
    rows: {
      triage: [], // the board's own verdicts carry this board
      queue: [
        { ...q('QU-5', 'queued', { enqueued_at: ago(15) }) },
        { ...q('DF-6', 'failed', { reason: 'BUILD_DEFERRED spawn cap 4', finished_at: ago(25) }) },
        { ...q('SC-7', 'claimed', { claimed_at: ago(45), claimed_by: 'fly-1' }) },
        { ...q('IF-11', 'claimed', { claimed_at: ago(50), claimed_by: 'box-2' }) }
      ],
      positions: [{ project: P, ticket_key: 'QU-5', enqueued_at: ago(15) }],
      live_jobs: [{ id: 'build-project-3-IF-11-1', project: P, ticket_id: 'IF-11', status: 'running', updated_at: ago(49), beat_at: ago(1) }],
      parked_jobs: [{ id: 'build-project-3-DF-6-1', project: P, ticket_id: 'DF-6', status: 'parked', updated_at: ago(25), reason: 'BUILD_DEFERRED spawn cap 4' }],
      edges: [{ project: P, parent: 'NT-1', child: 'BB-3', kind: 'hard' }]
    }
  };
}

test('C4 one ticket per reason: each key once, counts sum to rows', () => {
  const { snapshot, rows } = seededBoard();
  const out = run(snapshot, state(rows), { project: P });
  const keys = out.rows.map((r) => r.key);
  assert.deepEqual([...keys].sort(), ['BB-3', 'DF-6', 'NC-2', 'NT-1', 'OT-8', 'QU-5', 'RC-10', 'RQ-4', 'SC-7'].sort());
  assert.equal(new Set(keys).size, keys.length, 'each key once');
  const by = Object.fromEntries(out.rows.map((r) => [r.key, r.reason]));
  assert.deepEqual(by, {
    'NT-1': 'not-triaged', 'NC-2': 'needs-clarification', 'RC-10': 'needs-clarification', 'BB-3': 'blocked-by',
    'RQ-4': 'ready-not-queued', 'QU-5': 'queued', 'DF-6': 'deferred', 'SC-7': 'stale-claim', 'OT-8': 'other'
  });
  const sum = Object.values(out.counts).reduce((a, b) => a + b, 0);
  assert.equal(sum, out.rows.length);
  assert.equal(out.total, out.rows.length);
  assert.deepEqual(Object.keys(out.counts), WAITING_REASONS);
  assert.equal(out.in_flight, 2, 'RV-9 (review on team) and IF-11 (live job)');
  assert.ok(out.rows.every((r) => r.project === P), 'the ?project filter keeps one project');
  // Links: ticket page, board url, job and PR.
  assert.equal(by['SC-7'], 'stale-claim');
  const sc = rowOf(out, 'SC-7');
  assert.equal(sc.ticket_route, '/t/SC-7');
  assert.equal(sc.pr_route, '/pr/project-3/77');
  assert.equal(rowOf(out, 'DF-6').job_route, '/jobs/build-project-3-DF-6-1');
  assert.equal(rowOf(out, 'DF-6').reason_text, 'BUILD_DEFERRED spawn cap 4');
  // Without the filter the project-4 ticket of the same key is its own row.
  const all = run(snapshot, state(rows));
  assert.equal(rowOf(all, 'NT-1', 'project-4').reason, 'ready-not-queued');
  assert.equal(rowOf(all, 'NT-1', P).reason, 'not-triaged');
});

test('C6 the reconcile block adds up to the total', () => {
  const { snapshot, rows } = seededBoard();
  const out = run(snapshot, state(rows), { project: P });
  const r = out.reconcile;
  assert.equal(r.todo, 8);
  assert.equal(r.review_waiting_client, 1);
  assert.equal(r.in_progress_stale, 1);
  assert.equal(r.todo_in_flight, 1);
  assert.equal(r.todo + r.review_waiting_client + r.in_progress_stale - r.todo_in_flight, out.total);
});

// ------------------------------------------------------------------ C5

test('C5 dropStaleClaims removes the exact pair only', () => {
  const board = {
    columns: {
      building: [
        { id: 'b1', project: P, ticket: 'SC-7' },
        { id: 'b2', project: 'project-4', ticket: 'SC-7' },
        { id: 'b3', project: P, ticket: 'LIVE-1' }
      ],
      queued: [{ project: P, queue_depth: 2 }]
    },
    counts: { building: 3, queued: 2 }
  };
  const waiting = { ok: true, stale_claims: [{ project: P, key: 'SC-7', id: null }] };
  const out = dropStaleClaims(board, waiting);
  assert.deepEqual(out.columns.building.map((c) => c.id), ['b2', 'b3']);
  assert.equal(out.counts.building, 2);
  assert.equal(out.building_excluded_stale, 1);
  assert.equal(out.counts.queued, 2, 'other counts untouched');
  assert.equal(board.columns.building.length, 3, 'the input board is not mutated');
  for (const w of [null, undefined, { ok: false, unavailable: 'x' }, { ok: true }]) {
    assert.equal(dropStaleClaims(board, w), board, `unchanged on ${JSON.stringify(w)}`);
  }
  // A stale claim recorded by the board's internal id matches the card's ticket id.
  const byId = dropStaleClaims({ columns: { building: [{ id: 'b9', project: P, ticket: '#55', ticket_id: 'abc' }] }, counts: { building: 1 } },
    { ok: true, stale_claims: [{ project: P, key: 'KX', id: 'abc' }] });
  assert.equal(byId.counts.building, 0);
});

// ------------------------------------------------------------------ F1-F4

const SNAPSHOT_URL = 'https://harness-console.operator.workers.dev/api/dash/tickets-snapshot';
const STATE_URL = 'https://harness-jobs.operator.workers.dev/api/waiting/state';
const SECRET = 'test-secret-fixture';

function stubFetch(handler) {
  const calls = [];
  const prev = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), init });
    return handler(String(url), init);
  };
  return { calls, restore: () => { globalThis.fetch = prev; } };
}
const reqOf = (path, init = {}) => new Request(`https://console.test${path}`, { headers: { cookie: 'dash=fixture' }, ...init });
const jsonRes = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

test('F1 the snapshot read answers 401: 401 back, no jobs call', async () => {
  const s = stubFetch((u) => (u === SNAPSHOT_URL ? jsonRes(401, { error: 'unauthorized' }) : jsonRes(200, {})));
  try {
    const res = await onRequest({ request: reqOf('/api/dash/kanban/waiting'), env: { HARNESS_SECRET: SECRET } });
    assert.equal(res.status, 401);
    assert.equal((await res.json()).error, 'unauthorized', 'the refusal body is passed back');
    assert.deepEqual(s.calls.map((c) => c.url), [SNAPSHOT_URL]);
    assert.equal(s.calls[0].init.headers.get('cookie'), 'dash=fixture', 'the caller cookie is the credential');
    assert.equal(s.calls[0].init.headers.get('authorization'), null, 'no secret on the snapshot read');
  } finally { s.restore(); }
});

// Seed the jobs D1 with the rows seededBoard() describes, through real SQL.
function seedJobsDb(db) {
  const { rows } = seededBoard();
  const qi = db.prepare(`INSERT INTO build_queue (project, ticket_key, status, claimed_by, claimed_at, enqueued_at, finished_at, reason, updated_at)
    VALUES (?,?,?,?,?,?,?,?,?)`);
  for (const r of rows.queue) qi.run(r.project, r.ticket_key, r.status, r.claimed_by, r.claimed_at, r.enqueued_at, r.finished_at, r.reason, r.updated_at);
  // The route reads its lookback off the server clock, and the function
  // classifies against it: these rows are offsets from one anchor on it.
  const anchor = Date.now(); // determinism: ok — the single anchor; every time below is an offset from it
  const now = iso(anchor);
  const recent = (m) => iso(anchor - m * 60000);
  // Times relative to the worker's own clock: the route reads its lookback off it.
  db.prepare("UPDATE build_queue SET claimed_at = ? WHERE ticket_key = 'SC-7'").run(recent(45));
  db.prepare("UPDATE build_queue SET claimed_at = ? WHERE ticket_key = 'IF-11'").run(recent(50));
  db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?)`)
    .run('build-project-3-IF-11-1', P, 'IF-11', 'build', 'box-2', 'execute', 'running', recent(50), recent(49));
  db.prepare('INSERT INTO job_heartbeats (job_id, beat_at) VALUES (?,?)').run('build-project-3-IF-11-1', recent(1));
  db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at, meta) VALUES (?,?,?,?,?,?,?,?,?,?)`)
    .run('build-project-3-DF-6-1', P, 'DF-6', 'build', 'box-2', 'execute', 'parked', recent(30), recent(25), JSON.stringify({ reason: 'BUILD_DEFERRED spawn cap 4' }));
  db.prepare(`INSERT INTO ticket_edges (project, parent, child, kind, source, at) VALUES (?,?,?,?,?,?)`).run(P, 'NT-1', 'BB-3', 'hard', 'planner', now);
}

async function withSeededWorker(fn, { jobsStatus = null, snapshot = seededBoard().snapshot } = {}) {
  if (!waitingRoutes) return 'skip';
  const opened = await openDb();
  if (!opened) return 'skip';
  seedJobsDb(opened.db);
  const s = stubFetch(async (u, init) => {
    if (u === SNAPSHOT_URL) return jsonRes(200, snapshot);
    if (u === STATE_URL) {
      if (jobsStatus) return jsonRes(jobsStatus, { error: 'jobs_fixture_down' });
      return workerFetch(new Request(u, init), { DB: opened.DB, HARNESS_SECRET: SECRET });
    }
    throw new Error(`unexpected fetch ${u}`);
  });
  try { return await fn(s); } finally { s.restore(); }
}

test('F2 the seeded board end to end (acceptance 1)', async (t) => {
  const r = await withSeededWorker(async (s) => {
    const res = await onRequest({ request: reqOf('/api/dash/kanban/waiting'), env: { HARNESS_SECRET: SECRET } });
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('cache-control'), 'no-store');
    const body = await res.json();
    assert.equal(body.ok, true, JSON.stringify(body));
    const project-3 = body.rows.filter((x) => x.project === P);
    const by = Object.fromEntries(project-3.map((x) => [x.key, x.reason]));
    assert.deepEqual(by, {
      'NT-1': 'not-triaged', 'NC-2': 'needs-clarification', 'RC-10': 'needs-clarification', 'BB-3': 'blocked-by',
      'RQ-4': 'ready-not-queued', 'QU-5': 'queued', 'DF-6': 'deferred', 'SC-7': 'stale-claim', 'OT-8': 'other'
    });
    assert.equal(project-3.length, 9, 'each ticket once');
    for (const reason of WAITING_REASONS) assert.ok(body.counts[reason] >= 1, `${reason} counted`);
    assert.equal(project-3.find((x) => x.key === 'QU-5').position, 1);
    assert.deepEqual(body.stale_claims, [{ project: P, key: 'SC-7', id: null }]);
    assert.deepEqual(s.calls.map((c) => c.url), [SNAPSHOT_URL, STATE_URL], 'only the two reads');
    const sent = JSON.parse(s.calls[1].init.body);
    assert.ok(sent.tickets.every((x) => x.project && x.key), 'the open tickets are sent');
    assert.ok(!sent.tickets.some((x) => x.key === 'DN-12'), 'a done ticket is not sent');
    assert.equal(s.calls[1].init.headers.authorization, `Bearer ${SECRET}`);
    return 'ran';
  });
  if (r === 'skip') t.skip(wSkip || 'node:sqlite unavailable');
});

test('F3 the jobs read fails: ok:false, no rows', async (t) => {
  const r = await withSeededWorker(async () => {
    const res = await onRequest({ request: reqOf('/api/dash/kanban/waiting'), env: { HARNESS_SECRET: SECRET } });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.ok, false);
    assert.match(body.unavailable, /jobs state read failed \(500\)/);
    assert.equal(body.rows, undefined);
    assert.equal(body.counts, undefined);
    return 'ran';
  }, { jobsStatus: 500 });
  if (r === 'skip') t.skip(wSkip || 'node:sqlite unavailable');
  // No secret: 503, and still no jobs call.
  const s = stubFetch((u) => (u === SNAPSHOT_URL ? jsonRes(200, seededBoard().snapshot) : jsonRes(200, {})));
  try {
    const res = await onRequest({ request: reqOf('/api/dash/kanban/waiting'), env: {} });
    assert.equal(res.status, 503);
    assert.equal((await res.json()).ok, false);
    assert.deepEqual(s.calls.map((c) => c.url), [SNAPSHOT_URL]);
  } finally { s.restore(); }
  // An unusable snapshot: ok:false, no jobs call.
  const u = stubFetch((url) => (url === SNAPSHOT_URL ? jsonRes(200, { ok: true, projects: {} }) : jsonRes(200, {})));
  try {
    const res = await onRequest({ request: reqOf('/api/dash/kanban/waiting'), env: { HARNESS_SECRET: SECRET } });
    const body = await res.json();
    assert.equal(body.ok, false);
    assert.equal(body.rows, undefined);
    assert.deepEqual(u.calls.map((c) => c.url), [SNAPSHOT_URL]);
  } finally { u.restore(); }
});

test('F4 ?project= filters; a bad name is 400; non-GET is 405', async (t) => {
  const r = await withSeededWorker(async (s) => {
    const res = await onRequest({ request: reqOf('/api/dash/kanban/waiting?project=project-3'), env: { HARNESS_SECRET: SECRET } });
    const body = await res.json();
    assert.ok(body.rows.length > 0);
    assert.ok(body.rows.every((x) => x.project === P));
    const sent = JSON.parse(s.calls[1].init.body);
    assert.ok(sent.tickets.every((x) => x.project === P), 'only that project is sent');
    // A project with no OS board: ok, no rows, and it says so.
    const none = await (await onRequest({ request: reqOf('/api/dash/kanban/waiting?project=cromford'), env: { HARNESS_SECRET: SECRET } })).json();
    assert.equal(none.ok, true);
    assert.equal(none.project_in_snapshot, false);
    assert.deepEqual(none.rows, []);
    return 'ran';
  });
  if (r === 'skip') t.skip(wSkip || 'node:sqlite unavailable');
  const s = stubFetch(() => jsonRes(200, seededBoard().snapshot));
  try {
    const bad = await onRequest({ request: reqOf('/api/dash/kanban/waiting?project=Bad%20Name'), env: { HARNESS_SECRET: SECRET } });
    assert.equal(bad.status, 400);
    const post = await onRequest({ request: reqOf('/api/dash/kanban/waiting', { method: 'POST', body: '{}' }), env: { HARNESS_SECRET: SECRET } });
    assert.equal(post.status, 405);
    assert.deepEqual(s.calls, [], 'a refused request reads nothing');
  } finally { s.restore(); }
});

test('openTickets: open only, valid keys only, one order', () => {
  const s = snap({ [P]: [tk('A'), tk('B', { status: 'done' }), tk('bad key'), tk('C', { id: 'x/y' })], 'project-4': [tk('D', { id: '42' })] });
  assert.deepEqual(openTickets(s).map((x) => [x.project, x.key, x.id]),
    [['project-4', 'D', '42'], [P, 'A', null], [P, 'C', null]]);
  assert.deepEqual(openTickets(s, P).map((x) => x.key), ['A', 'C']);
});

// ------------------------------------------------------------------ R1

const html = (vnode) => renderToString(vnode);
const waitingPayload = () => {
  const { snapshot, rows } = seededBoard();
  return run(snapshot, state(rows));
};

test('R1 the rendered table: counts, sort headers, links, the warn banner', () => {
  const data = waitingPayload();
  const out = html(h(WaitingView, { state: { data, loading: false, error: null }, fleetProjects: [P, 'project-4', 'cromford'] }));
  // Counts at the top: one tag per non-zero reason.
  for (const reason of WAITING_REASONS) {
    const n = data.counts[reason];
    const tag = new RegExp(`<span class="tag[^"]*"[^>]*>${reason.replace('-', '\\-')} ${n}</span>`);
    if (n > 0) assert.match(out, tag, reason);
  }
  assert.match(out, /in flight 2/);
  assert.match(out, /stale claims 1/);
  // PROJECT, REASON and AGE are sort buttons inside a header with aria-sort.
  for (const label of ['PROJECT', 'REASON', 'AGE']) {
    assert.match(out, new RegExp(`<th[^>]*aria-sort="[a-z]+"[^>]*><button[^>]*>\\s*${label}`), label);
  }
  // The table scrolls inside its own box.
  assert.match(out, /class="tablewrap tablewrap--wide"/);
  // Links: the ticket page, the job, the PR, the blocker.
  assert.match(out, /href="\/t\/SC-7"/);
  assert.match(out, /href="\/jobs\/build-project-3-DF-6-1"/);
  assert.match(out, /href="\/pr\/project-3\/77"/);
  assert.match(out, /blocked by <a[^>]*href="\/t\/NT-1"/);
  assert.match(out, /href="\/p\/project-3"/);
  // The project with no board snapshot is named, not shown as empty.
  assert.match(out, /not covered: cromford/);

  const board = { ...data, rows: data.rows.map((r) => (r.key === 'NT-1' && r.project === P ? { ...r, board_url: 'https://board.example/t/NT-1' } : r)) };
  assert.match(html(h(WaitingView, { state: { data: board, loading: false, error: null } })), /href="https:\/\/board.example\/t\/NT-1"/);

  const down = html(h(WaitingView, { state: { data: { ok: false, unavailable: 'jobs state read failed (500)' }, loading: false, error: null } }));
  assert.match(down, /banner--warn/);
  assert.match(down, /jobs state read failed \(500\)/);
  assert.doesNotMatch(down, /nothing waiting/i);
  assert.doesNotMatch(down, /<table/);

  const empty = html(h(WaitingView, { state: { data: { ...data, rows: [], counts: {}, total: 0 }, loading: false, error: null } }));
  assert.match(empty, /nothing waiting/i);

  const absent = html(h(WaitingView, { project: 'cromford', state: { data: { ok: true, project_in_snapshot: false, rows: [], counts: {}, total: 0 }, loading: false, error: null } }));
  assert.match(absent, /no OS board snapshot for cromford/);
  assert.doesNotMatch(absent, /nothing waiting/i);

  const loading = html(h(WaitingView, { state: { data: null, loading: true, error: null } }));
  assert.match(loading, /class="skel"/);
});
