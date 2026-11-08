// BH-3704 (BH-3688 slice 2 of 5): the daily-digest core sections.
//
// WHAT IS PINNED
//   U1/U2 (pure): core-pure.js — filingToMerge's attribution (earliest non-review
//     job, MIN issue_created_at, nearest-rank p50, unmeasured never averaged)
//     and isHumanActor's adversarial negatives.
//   W* (route): GET /api/metrics/daily-digest through the real worker.fetch on a
//     REAL schema.sql database, seeded with the row shapes the writers produce:
//     br_record keys/detail from blocked-resolver's br_save, batch_member keys
//     from batch-resolve, the merge-conductor queue-ejected reason, and a
//     stage_events row written through POST /api/jobs/:id/events.
//
// D = 2026-09-29 is a fixed past day. The one clock read is W3's, which asks
// the route for the day its own POST stamped.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { isHumanActor, filingToMerge } from '../src/lib/daily-digest/core-pure.js';

const SECRET = 'test-secret';
const D = '2026-09-29';
const NEXT = '2026-09-30';
const URL_ = `/api/metrics/daily-digest?day=${D}`;
const EMPTY = JSON.parse(readFileSync(
  new URL('../../../tests/fixtures/daily-digest/empty-day.json', import.meta.url), 'utf8'));
const BY_TABLE_KEYS = Object.keys(EMPTY.autonomy.human_interventions.by_table);

const call = (DB, path, init = {}) => worker.fetch(
  new Request(`https://jobs.test${path}`, {
    ...init,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json', ...(init.headers || {}) },
  }),
  { DB, HARNESS_SECRET: SECRET },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

const pr = (repo, n) => `https://github.com/example-org/${repo}/pull/${n}`;

// ── seed helpers (row shapes as the writers produce them) ────────────────────
function job(db, { id, project, ticket, kind = 'build', created, issue = null }) {
  db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at, issue_created_at)
              VALUES (?,?,?,?,?,?,?,?,?,?)`).run(id, project, ticket, kind, 'hub', 'done', 'done', created, created, issue);
}
function artifact(db, jobId, url, at) {
  db.prepare(`INSERT INTO job_artifacts (job_id, artifact_kind, artifact_ref, actor, created_at, updated_at)
              VALUES (?, 'pr_url', ?, 'hub', ?, ?)`).run(jobId, url, at, at);
}
function ledger(db, kind, key, status, at, detail = null) {
  db.prepare(`INSERT INTO ledgers (kind, key, status, actor, detail, created_at, updated_at)
              VALUES (?,?,?,?,?,?,?)`).run(kind, key, status, 'hub', detail, at, at);
}
let rowN = 0;
function cost(db, { ts, usd, ticket = null, project = 'cromford', jobId = null }) {
  rowN += 1;
  db.prepare(`INSERT INTO cost_rows (box, row_hash, line_no, ts, project, cost_usd, ticket, job_id, inserted_at)
              VALUES ('hub', ?, ?, ?, ?, ?, ?, ?, ?)`).run(`h${rowN}`, rowN, ts, project, usd, ticket, jobId, ts);
}
function stageEvent(db, { jobId, verdict, actor, at }) {
  db.prepare(`INSERT INTO stage_events (job_id, stage, verdict, actor, created_at) VALUES (?, 'build', ?, ?, ?)`)
    .run(jobId, verdict, actor, at);
}
const brDetail = (rebuilds) => JSON.stringify({
  rebuilds, fixrounds: 1, mechanicals: 0, regens: 0, adjudications: 0, rereviews: 0, first_seen: `${D}T01:00:00Z`,
});

// W1a: two measured merges (1 h and 2 h), costs across 4 tickets, both dequeue
// sources, a rebuild loop among malformed/under-threshold/out-of-window rows.
function seedW1a(db) {
  // cromford: issue 09:00 -> merge 10:00 = 3600 s. A review job on the same
  // PR, created earlier and on a ticket filed earlier, must not be the one used.
  job(db, { id: 'j-bh', project: 'cromford', ticket: 'BH-10', created: '2026-09-28T09:30:00Z', issue: `${D}T09:00:00Z` });
  artifact(db, 'j-bh', pr('cromford', 1), `${D}T09:45:00Z`);
  job(db, { id: 'j-rev', project: 'cromford', ticket: 'BH-1', kind: 'review', created: '2026-09-01T00:00:00Z', issue: '2026-08-01T00:00:00Z' });
  artifact(db, 'j-rev', pr('cromford', 1), `${D}T09:50:00Z`);
  ledger(db, 'merge', pr('cromford', 1), 'merged', `${D}T10:00:00Z`);
  // project-5: issue 10:00 -> merge 12:00 = 7200 s.
  job(db, { id: 'j-ts', project: 'project-5', ticket: 'TK-20', created: `${D}T10:05:00Z`, issue: `${D}T10:00:00Z` });
  artifact(db, 'j-ts', pr('project-5', 2), `${D}T11:00:00Z`);
  ledger(db, 'merge', pr('project-5', 2), 'merged', `${D}T12:00:00Z`);
  // Not merges of the day: a parked merge row and yesterday's merge.
  ledger(db, 'merge', pr('project-5', 3), 'parked', `${D}T13:00:00Z`);
  ledger(db, 'merge', pr('project-5', 4), 'merged', '2026-09-28T23:59:59Z');

  cost(db, { ts: `${D}T01:00:00Z`, usd: 5, ticket: 'BH-A', jobId: 'job-a1' });
  cost(db, { ts: `${D}T02:00:00Z`, usd: 2.5, ticket: 'BH-A', jobId: 'job-a2' });
  cost(db, { ts: `${D}T03:00:00Z`, usd: 1.25, ticket: 'BH-B', jobId: 'job-b' });
  cost(db, { ts: `${D}T04:00:00Z`, usd: 0.5, ticket: 'BH-C', jobId: 'job-c' });
  cost(db, { ts: `${D}T05:00:00Z`, usd: 0.25, ticket: 'BH-D', jobId: 'job-d' });
  cost(db, { ts: `${D}T06:00:00Z`, usd: 1, ticket: null });
  cost(db, { ts: `${D}T07:00:00Z`, usd: null, ticket: 'BH-A', jobId: 'job-a3' });
  cost(db, { ts: `${NEXT}T00:00:00Z`, usd: 100, ticket: 'BH-Z' });

  db.prepare(`INSERT INTO pr_state_events (repo, number, state, since, reason, at, actor)
              VALUES ('example-org/cromford', 5, 'WAIT_CI', ?, ?, ?, 'merge-conductor')`)
    .run(`${D}T10:00:00Z`, 'queue-ejected — push a fix; the next head is enqueued on its own merits', `${D}T11:00:00Z`);
  db.prepare(`INSERT INTO pr_state_events (repo, number, state, since, reason, at, actor)
              VALUES ('example-org/cromford', 8, 'WAIT_CI', ?, 'ci pending', ?, 'merge-conductor')`)
    .run(`${D}T10:00:00Z`, `${D}T11:30:00Z`);
  ledger(db, 'batch_member', 'example-org/cromford#6@abc1234', 'abandoned', `${D}T12:00:00Z`);
  ledger(db, 'batch_member', 'example-org/cromford#7@def5678', 'landed', `${D}T12:30:00Z`);

  ledger(db, 'br_record', 'cromford/BH-1', 'open', `${D}T16:42:00Z`, brDetail(3));
  ledger(db, 'br_record', 'cromford/BH-2', 'open', `${D}T16:43:00Z`, brDetail(1));
  ledger(db, 'br_record', 'cromford/BH-3', 'open', `${D}T16:44:00Z`, 'not json');
  ledger(db, 'br_record', 'cromford/BH-4', 'open', `${D}T16:45:00Z`, JSON.stringify({ rebuilds: '3' }));
  ledger(db, 'br_record', 'cromford/BH-5', 'open', `${D}T16:46:00Z`, JSON.stringify({ fixrounds: 4 }));
  ledger(db, 'br_record', 'cromford/BH-6', 'open', `${NEXT}T00:00:00Z`, brDetail(5));
  ledger(db, 'abandoned', 'cromford BH-9', 'abandoned', `${D}T17:00:00Z`);
}

// ── U1 filingToMerge ─────────────────────────────────────────────────────────
test('U1: filingToMerge attributes to the earliest non-review job and never averages the unmeasured', () => {
  const M = (key, at) => ({ key, created_at: at });
  const A = (ref, job_id, project, ticket_id, job_created_at, job_kind = 'build') =>
    ({ artifact_ref: ref, job_id, job_kind, project, ticket_id, job_created_at });
  const J = (project, ticket_id, issue_created_at) => ({ project, ticket_id, issue_created_at });

  const merges = [
    M('u1', `${D}T10:00:00Z`), M('u2', `${D}T12:00:00Z`),
    M('u3', `${D}T13:00:00Z`), M('u4', `${D}T14:00:00Z`), M('u5', `${D}T15:00:00Z`),
  ];
  const artifacts = [
    A('u1', 'rev', 'p', 'T-OLD', '2026-01-01T00:00:00Z', 'review'),
    A('u1', 'rv', 'p', 'T-OLD', '2026-01-01T00:00:00Z', 'review-verdict'),
    A('u1', 'b1', 'p', 'T-1', `${D}T09:30:00Z`),
    // Two build jobs on u2: the EARLIER one's ticket (T-2, issue 10:00) is used,
    // not the rebuild's (T-2b, issue 11:30, which would give 1800).
    A('u2', 'b2-new', 'q', 'T-2b', `${D}T11:40:00Z`),
    A('u2', 'b2-old', 'q', 'T-2', `${D}T10:30:00Z`),
    A('u3', 'b3', 'q', 'T-3', `${D}T12:00:00Z`),   // T-3 has no issue_created_at
    A('u4', 'b4', 'p', 'T-4', `${D}T13:00:00Z`),   // issue after the merge: negative
    // u5 has no artifact at all
  ];
  const jobs = [
    J('p', 'T-OLD', '2025-01-01T00:00:00Z'), J('p', 'T-1', `${D}T09:00:00Z`),
    J('q', 'T-2', `${D}T10:00:00Z`), J('q', 'T-2b', `${D}T11:30:00Z`),
    J('p', 'T-4', `${D}T20:00:00Z`),
  ];
  const r = filingToMerge(merges, artifacts, jobs);
  // spans 3600 (u1) and 7200 (u2): nearest-rank p50 of two is the lower.
  assert.deepEqual(r.filing_to_merge, { p50_s: 3600, measured_n: 2, unmeasured_n: 3 });
  assert.deepEqual(r.by_project, [
    { project: 'p', merged: 2 }, { project: 'q', merged: 2 }, { project: null, merged: 1 },
  ]);

  // Three measured: the median is the middle one, not the mean.
  const three = filingToMerge(
    [M('a', `${D}T01:00:00Z`), M('b', `${D}T02:00:00Z`), M('c', `${D}T10:00:00Z`)],
    [A('a', 'ja', 'p', 'A', `${D}T00:00:00Z`), A('b', 'jb', 'p', 'B', `${D}T00:00:00Z`), A('c', 'jc', 'p', 'C', `${D}T00:00:00Z`)],
    [J('p', 'A', `${D}T00:00:00Z`), J('p', 'B', `${D}T00:00:00Z`), J('p', 'C', `${D}T00:00:00Z`)],
  );
  assert.equal(three.filing_to_merge.p50_s, 7200);

  assert.deepEqual(filingToMerge([], [], []), {
    filing_to_merge: { p50_s: null, measured_n: 0, unmeasured_n: 0 }, by_project: [],
  });
  const bad = filingToMerge([M('x', 'not a date')], [A('x', 'jx', 'p', 'X', `${D}T00:00:00Z`)], [J('p', 'X', `${D}T00:00:00Z`)]);
  assert.deepEqual(bad.filing_to_merge, { p50_s: null, measured_n: 0, unmeasured_n: 1 });
});

// ── U2 isHumanActor ──────────────────────────────────────────────────────────
test('U2: isHumanActor is true only for an @ address or a listed name, never the watchdog', () => {
  for (const a of ['jobs-watchdog', 'hub', 'merge-conductor', 'console', 'review-prs', '', '  ', null, undefined, 42, 'operator']) {
    assert.equal(isHumanActor(a, []), false, `${JSON.stringify(a)} with no list`);
  }
  assert.equal(isHumanActor('jobs-watchdog', ['jobs-watchdog']), false, 'the watchdog is never human');
  assert.equal(isHumanActor('JOBS-WATCHDOG', ['jobs-watchdog']), false);
  assert.equal(isHumanActor('hub', ['operator']), false);
  assert.equal(isHumanActor('operator@example.com', []), true);
  assert.equal(isHumanActor('OPERATOR@example.com', []), true);
  assert.equal(isHumanActor(' operator ', ['operator']), true);
  assert.equal(isHumanActor('operator', [' OPERATOR ']), true, 'a caller that forgot to normalize the list');
  assert.equal(isHumanActor('operator', undefined), false);
});

// ── route, on a real schema ──────────────────────────────────────────────────
test('BH-3704 core sections through GET /api/metrics/daily-digest on a real schema', async (t) => {
  if ((await openDb()) === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }

  await t.test('W1a: the fixture day answers every core counter from its source rows', async () => {
    const { db, DB } = await openDb();
    seedW1a(db);
    const r = await call(DB, URL_);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const { throughput: th, spend: sp, autonomy: au } = r.body;
    for (const k of ['throughput', 'spend', 'autonomy']) assert.equal(r.body[k].ok, true, `${k}: ${JSON.stringify(r.body[k])}`);

    assert.equal(th.merged, 2);
    assert.deepEqual(th.filing_to_merge, { p50_s: 3600, measured_n: 2, unmeasured_n: 0 });
    assert.deepEqual(th.by_project, [{ project: 'cromford', merged: 1 }, { project: 'project-5', merged: 1 }]);

    assert.equal(sp.calls, 7);
    assert.equal(sp.unpriced_calls, 1);
    assert.equal(sp.usd, 5 + 2.5 + 1.25 + 0.5 + 0.25 + 1);
    assert.equal(sp.usd_per_merged_pr, sp.usd / 2);
    assert.deepEqual(sp.top_tickets, {
      rows: [
        { project: 'cromford', ticket: 'BH-A', usd: 7.5, job_id: 'job-a2' },
        { project: 'cromford', ticket: 'BH-B', usd: 1.25, job_id: 'job-b' },
        { project: 'cromford', ticket: 'BH-C', usd: 0.5, job_id: 'job-c' },
      ],
      truncated: true,
    });

    const bd = au.batch_dequeues;
    assert.equal(bd.n, 2);
    assert.match(bd.basis, /pr_state_events/);
    assert.match(bd.basis, /batch_member/);
    assert.deepEqual(bd.rows, [
      { source: 'batch_member', project: null, key: 'example-org/cromford#6@abc1234', at: `${D}T12:00:00Z` },
      { source: 'pr_state_events', project: null, key: 'example-org/cromford#5', at: `${D}T11:00:00Z` },
    ]);
    assert.equal(bd.truncated, false);

    assert.deepEqual(au.rebuild_loops, {
      n: 1, abandoned: 1,
      rows: [{ project: 'cromford', key: 'BH-1', rebuilds: 3, at: `${D}T16:42:00Z` }],
      truncated: false,
    });
    assert.deepEqual(au.manual_requeues, { n: 0, rows: [], truncated: false });
    assert.deepEqual(Object.keys(au.human_interventions.by_table), BY_TABLE_KEYS);
    assert.equal(r.body.empty, false);
  });

  await t.test('W1a: loop_min is the rebuild threshold, inclusive', async () => {
    const { db, DB } = await openDb();
    seedW1a(db);
    const r3 = await call(DB, `${URL_}&loop_min=3`);
    assert.equal(r3.body.autonomy.rebuild_loops.n, 1);
    const r4 = await call(DB, `${URL_}&loop_min=4`);
    assert.equal(r4.body.autonomy.rebuild_loops.n, 0);
  });

  await t.test('W1b: a third merge with no issue_created_at counts in merged and unmeasured_n only', async () => {
    const { db, DB } = await openDb();
    seedW1a(db);
    job(db, { id: 'j-om', project: 'project-3', ticket: 'TK-1', created: `${D}T08:00:00Z`, issue: null });
    artifact(db, 'j-om', pr('project-3', 9), `${D}T13:00:00Z`);
    ledger(db, 'merge', pr('project-3', 9), 'merged', `${D}T14:00:00Z`);
    const r = await call(DB, URL_);
    assert.equal(r.body.throughput.merged, 3);
    assert.deepEqual(r.body.throughput.filing_to_merge, { p50_s: 3600, measured_n: 2, unmeasured_n: 1 });
    assert.deepEqual(r.body.throughput.by_project, [
      { project: 'cromford', merged: 1 }, { project: 'project-3', merged: 1 }, { project: 'project-5', merged: 1 },
    ]);
    assert.equal(r.body.spend.usd_per_merged_pr, r.body.spend.usd / 3);
  });

  await t.test('W2-core: an empty day is real zeros, null ratios, and the empty fixture', async () => {
    const { DB } = await openDb();
    const r = await call(DB, URL_);
    assert.equal(r.status, 200);
    const { throughput: th, spend: sp, autonomy: au } = r.body;
    for (const k of ['throughput', 'spend', 'autonomy']) assert.equal(r.body[k].ok, true, `${k}: ${JSON.stringify(r.body[k])}`);
    assert.equal(th.merged, 0);
    assert.deepEqual(th.by_project, []);
    assert.deepEqual(th.filing_to_merge, { p50_s: null, measured_n: 0, unmeasured_n: 0 });
    assert.equal(sp.usd, 0);
    assert.equal(sp.calls, 0);
    assert.equal(sp.unpriced_calls, 0);
    assert.equal(sp.usd_per_merged_pr, null, 'never 0 on zero merges');
    assert.deepEqual(sp.top_tickets, { rows: [], truncated: false });
    for (const k of ['batch_dequeues', 'manual_requeues', 'rebuild_loops', 'human_interventions']) assert.equal(au[k].n, 0, k);
    assert.equal(au.rebuild_loops.abandoned, 0);
    for (const v of Object.values(au.human_interventions.by_table)) assert.equal(v, 0);

    const want = JSON.parse(JSON.stringify({ throughput: EMPTY.throughput, spend: EMPTY.spend, autonomy: EMPTY.autonomy }));
    want.autonomy.batch_dequeues.basis = au.batch_dequeues.basis;
    assert.deepEqual({ throughput: th, spend: sp, autonomy: au }, want);
  });

  await t.test('W2b: an all-unpriced day is usd null, never 0', async () => {
    const { db, DB } = await openDb();
    cost(db, { ts: `${D}T01:00:00Z`, usd: null, ticket: 'BH-A' });
    cost(db, { ts: `${D}T02:00:00Z`, usd: null, ticket: 'BH-B' });
    ledger(db, 'merge', pr('cromford', 1), 'merged', `${D}T10:00:00Z`);
    const r = await call(DB, URL_);
    assert.equal(r.body.spend.ok, true);
    assert.equal(r.body.spend.usd, null);
    assert.equal(r.body.spend.usd_per_merged_pr, null);
    assert.equal(r.body.spend.calls, 2);
    assert.equal(r.body.spend.unpriced_calls, 2);
    assert.deepEqual(r.body.spend.top_tickets, { rows: [], truncated: false });
    assert.equal(r.body.throughput.merged, 1);
  });

  await t.test('W3: the window is [D 00:00, D+1 00:00), and stage_events stamps match it', async () => {
    const { db, DB } = await openDb();
    ledger(db, 'merge', pr('cromford', 1), 'merged', `${D}T00:00:00Z`);
    ledger(db, 'merge', pr('cromford', 2), 'merged', `${NEXT}T00:00:00Z`);
    cost(db, { ts: `${D}T00:00:00Z`, usd: 1 });
    cost(db, { ts: `${NEXT}T00:00:00Z`, usd: 1 });
    const r = await call(DB, URL_);
    assert.equal(r.body.throughput.merged, 1);
    assert.equal(r.body.spend.calls, 1);

    job(db, { id: 'j-ev', project: 'cromford', ticket: 'BH-77', created: `${D}T00:00:00Z` });
    const ev = await call(DB, '/api/jobs/j-ev/events', {
      method: 'POST', body: JSON.stringify({ verdict: 'REQUEUED', actor: 'operator@example.com' }),
    });
    assert.equal(ev.status, 201, JSON.stringify(ev.body));
    const stored = db.prepare(`SELECT created_at FROM stage_events WHERE job_id='j-ev'`).get().created_at;
    assert.match(stored, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    const day = await call(DB, `/api/metrics/daily-digest?day=${stored.slice(0, 10)}`);
    assert.equal(day.body.autonomy.manual_requeues.n, 1);
    assert.deepEqual(day.body.autonomy.manual_requeues.rows,
      [{ project: 'cromford', key: 'BH-77', verdict: 'REQUEUED', actor: 'operator@example.com', at: stored }]);
  });

  await t.test('W5: actors — the watchdog and blanks are never a requeue, humans are @ or listed', async () => {
    const { db, DB } = await openDb();
    job(db, { id: 'j-5', project: 'project-5', ticket: 'TK-5', created: `${D}T00:00:00Z` });
    stageEvent(db, { jobId: 'j-5', verdict: 'REQUEUED', actor: 'jobs-watchdog', at: `${D}T09:00:00Z` });
    stageEvent(db, { jobId: 'j-5', verdict: 'REQUEUED', actor: '', at: `${D}T09:01:00Z` });
    stageEvent(db, { jobId: 'j-5', verdict: 'REQUEUED', actor: '   ', at: `${D}T09:02:00Z` });
    stageEvent(db, { jobId: 'j-5', verdict: 'REQUEUE_CAPPED', actor: 'OPERATOR@example.com', at: `${D}T09:03:00Z` });
    stageEvent(db, { jobId: 'j-5', verdict: 'APPROVE', actor: 'hub', at: `${D}T09:04:00Z` });
    stageEvent(db, { jobId: 'j-5', verdict: 'RELEASED', actor: 'hub', at: `${D}T09:05:00Z` });
    stageEvent(db, { jobId: 'j-5', verdict: 'REQUEUED', actor: 'operator@example.com', at: `${D}T13:20:00Z` });
    db.prepare(`INSERT INTO verdicts (repo, pr, head_sha, verdict, source, created_at) VALUES (?,?,?,?,?,?)`)
      .run('example-org/project-5', 1, 'a'.repeat(40), 'MERGE', 'human', `${D}T10:00:00Z`);
    db.prepare(`INSERT INTO verdicts (repo, pr, head_sha, verdict, source, created_at) VALUES (?,?,?,?,?,?)`)
      .run('example-org/project-5', 2, 'b'.repeat(40), 'MERGE', 'lead', `${D}T10:00:00Z`);
    db.prepare(`INSERT INTO config_changes (kind, name, after_json, actor, at) VALUES ('knob','x','{}','operator',?)`)
      .run(`${D}T11:00:00Z`);

    const r = await call(DB, URL_);
    const mr = r.body.autonomy.manual_requeues;
    assert.equal(mr.n, 2, JSON.stringify(mr));
    assert.deepEqual(mr.rows, [
      { project: 'project-5', key: 'TK-5', verdict: 'REQUEUED', actor: 'operator@example.com', at: `${D}T13:20:00Z` },
      { project: 'project-5', key: 'TK-5', verdict: 'RELEASED', actor: 'hub', at: `${D}T09:05:00Z` },
    ]);
    const hi = r.body.autonomy.human_interventions;
    assert.equal(hi.by_table.stage_events, 2, 'operator@example.com and OPERATOR@example.com; hub and the watchdog are not human');
    assert.equal(hi.by_table.verdicts, 0, "a raw unsigned source='human' row is not proven (BH-3905), and source='lead' is not human");
    assert.equal(hi.by_table.config_changes, 0, "'operator' is not human until listed");
    assert.equal(hi.n, 2);

    const listed = await call(DB, `${URL_}&human=operator`);
    const hl = listed.body.autonomy.human_interventions;
    assert.equal(hl.by_table.config_changes, 1);
    assert.equal(hl.n, Object.values(hl.by_table).reduce((a, b) => a + b, 0));
    assert.equal(hl.n, 3);
  });

  await t.test('W6-core: a failed spend read is spend ok:false only, never a zero elsewhere', async () => {
    const { db, DB } = await openDb();
    seedW1a(db);
    const before = await call(DB, URL_);
    db.exec('DROP TABLE cost_rows');
    const r = await call(DB, URL_);
    assert.equal(r.status, 200);
    assert.equal(r.body.spend.ok, false);
    assert.equal(typeof r.body.spend.error, 'string');
    assert.ok(r.body.spend.error.length > 0);
    assert.equal(r.body.spend.usd, undefined, 'no zero rides on a failed read');
    assert.deepEqual(r.body.throughput, before.body.throughput);
    assert.deepEqual(r.body.autonomy, before.body.autonomy);
    assert.equal(r.body.throughput.ok, true);
    assert.equal(r.body.autonomy.ok, true);
    assert.equal(r.body.empty, false);
  });

  await t.test('W7: limit caps the list and n stays the true count', async () => {
    const { db, DB } = await openDb();
    job(db, { id: 'j-7', project: 'project-3', ticket: 'TK-7', created: `${D}T00:00:00Z` });
    stageEvent(db, { jobId: 'j-7', verdict: 'REQUEUED', actor: 'operator@example.com', at: `${D}T01:00:00Z` });
    stageEvent(db, { jobId: 'j-7', verdict: 'DROPPED', actor: 'operator@example.com', at: `${D}T02:00:00Z` });
    const r = await call(DB, `${URL_}&limit=1`);
    const mr = r.body.autonomy.manual_requeues;
    assert.equal(mr.n, 2);
    assert.equal(mr.rows.length, 1);
    assert.equal(mr.rows[0].verdict, 'DROPPED');
    assert.equal(mr.truncated, true);
  });

  await t.test('W8: every one of the 11 human-intervention sources is read', async () => {
    const { db, DB } = await openDb();
    const at = `${D}T08:00:00Z`;
    const who = 'operator@example.com';
    db.prepare(`INSERT INTO config_changes (kind, name, after_json, actor, at) VALUES ('k','n','{}',?,?)`).run(who, at);
    db.prepare(`INSERT INTO model_route_changes (scope, role, position, actor, at) VALUES ('hub','stage.execute',0,?,?)`).run(who, at);
    db.prepare(`INSERT INTO routing_changes (project, after_builder, after_halted, actor, at) VALUES ('project-3','pool',0,?,?)`).run(who, at);
    db.prepare(`INSERT INTO cost_cap_changes (key, after_value, actor, at) VALUES ('cap','5',?,?)`).run(who, at);
    db.prepare(`INSERT INTO route_rule_changes (name, actor, at) VALUES ('r',?,?)`).run(who, at);
    db.prepare(`INSERT INTO flaky_quarantine_changes (repo, test, after_active, actor, reason, at) VALUES ('r','t',1,?,'x',?)`).run(who, at);
    db.prepare(`INSERT INTO alert_actions (alert_id, action, actor, outcome, at) VALUES ('a','ack',?,'ok',?)`).run(who, at);
    job(db, { id: 'j-8', project: 'project-3', ticket: 'TK-8', created: at });
    stageEvent(db, { jobId: 'j-8', verdict: 'APPROVE', actor: who, at });
    db.prepare(`INSERT INTO pauses (scope, what, reason, actor, created_at, expires_at) VALUES ('fleet','builds','x',?,?,?)`)
      .run(who, at, `${NEXT}T08:00:00Z`);
    ledger(db, 'ticket_hold', 'project-3#12', 'held', at);
    // Out of window and non-human rows in the same tables stay out.
    db.prepare(`INSERT INTO config_changes (kind, name, after_json, actor, at) VALUES ('k','n','{}',?,?)`).run(who, `${NEXT}T00:00:00Z`);
    db.prepare(`INSERT INTO alert_actions (alert_id, action, actor, outcome, at) VALUES ('a','ack','console','ok',?)`).run(at);

    const r = await call(DB, URL_);
    const hi = r.body.autonomy.human_interventions;
    assert.deepEqual(Object.keys(hi.by_table), BY_TABLE_KEYS);
    for (const k of BY_TABLE_KEYS) assert.equal(hi.by_table[k], k === 'verdicts' ? 0 : 1, k);
    assert.equal(hi.n, 10);
  });
});
