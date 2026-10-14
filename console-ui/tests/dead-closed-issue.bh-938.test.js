import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import {
  onRequest, archiveDead, excludeClosedIssues, _resetClosedCache, _resetHeldCache, _resetStageCache
} from '../functions/api/dash/kanban/pipeline.js';
import { filterPipeline, pipelineRows } from '../src/lib/kanban.js';
import { PipelineBoard, PipelineList } from '../src/screens/Kanban.js';

// BH-938. The DEAD column counted build rows whose GitHub issue had long since
// closed (project-5: dead_failed=29, every issue merged or superseded). The hub
// lane bin/issue-state-ledger.sh records each issue's state in
// ledgers(kind=issue_state, key=<project>#<n>); the Pages Function joins it at
// read time and holds those rows back, counted, one SHOW ALL away.
//
// What these pin:
//   - a closed issue's build rows leave the default view, any dead stage,
//   - nothing else leaves: other projects, other numbers, suffixes, command
//     cards and reopened issues all stay,
//   - an unread ledger hides NOTHING (fail open), and says it could not read,
//   - the audit view returns every row, flagged,
//   - the count reaches the screen.

const build = (id, project, ticket, stage = 'plan_blocked', extra = {}) =>
  ({ id, project, ticket, stage, age_min: 60, ...extra });

const payload = (dead) => ({
  columns: {
    queued: [], building: [], merge_queue: [], review: [], merged_deployed: [],
    dead_failed: dead
  },
  counts: { queued: 0, building: 0, merge_queue: 0, review: 0, merged_deployed: 0, dead_failed: dead.length },
  building_stale: 0,
  snapshot_age_min: 1
});

const closed = (...keys) => new Set(keys);

// --- the pure rule ----------------------------------------------------------

test('1. closed-issue build rows leave the DEAD column, plan_blocked and executing both', () => {
  const p = payload([
    build(1, 'project-5', 'TK-551', 'plan_blocked'),
    build(2, 'project-5', 'TK-551', 'executing'),
    build(3, 'project-5', 'TK-552', 'plan_blocked')
  ]);
  const out = excludeClosedIssues(p, closed('project-5#551'));
  assert.deepEqual(out.columns.dead_failed.map((c) => c.id), [3]);
  assert.equal(out.counts.dead_failed, 1);
  assert.equal(out.dead_closed, 2);
  assert.equal(out.dead_closed_known, true);
  // Nothing but the dead column moves.
  assert.deepEqual(out.columns.building, []);
  assert.equal(out.snapshot_age_min, 1);
});

test('2. adversarial negatives all stay', () => {
  const keep = [
    build(10, 'project-1', 'TK-551'),                     // another project, same number
    build(11, 'project-5', 'TK-55'),                        // prefix of the closed number
    build(12, 'project-5', 'TK-5510'),                      // extension of it
    build(13, 'project-5', 'TK-551a'),                      // suffix
    build(14, 'project-5', null),                           // no ticket
    build(15, 'project-5', ''),                             // empty ticket
    build(16, 'pool:project-5', 'TK-551'),                  // not the project value the key is built from
    { command_id: 17, ckey: 'project-5:TK-551:merge_pr', project: 'project-5', stage: 'dead_letter' },
    // A command card that also carries a ticket and an id is still a command
    // (cardKind reads command_id first), and a dead command is its own failure.
    { command_id: 19, id: 19, ticket: 'TK-551', ckey: 'project-5:TK-551:merge_pr', project: 'project-5', stage: 'dead_letter' },
    build(18, 'project-5', 'TK-600')                        // reopened: its row says open
  ];
  const out = excludeClosedIssues(payload(keep), closed('project-5#551', 'project-5#120'));
  assert.equal(out.columns.dead_failed.length, keep.length);
  assert.equal(out.dead_closed, 0);
  // A key like TK-12 must not match project-5#120.
  const twelve = excludeClosedIssues(payload([build(20, 'project-5', 'TK-12')]), closed('project-5#120'));
  assert.equal(twelve.columns.dead_failed.length, 1);
});

test('the ticket_key field is read when ticket is absent', () => {
  const out = excludeClosedIssues(payload([{ id: 30, project: 'project-5', ticket_key: 'TK-9', stage: 'executing' }]),
    closed('project-5#9'));
  assert.equal(out.columns.dead_failed.length, 0);
  assert.equal(out.dead_closed, 1);
});

test('3. the audit view returns every row and flags the closed ones', () => {
  const p = payload([build(1, 'project-5', 'TK-551'), build(2, 'project-5', 'TK-7'), build(3, 'project-5', 'TK-551', 'executing')]);
  const out = excludeClosedIssues(p, closed('project-5#551'), { includeArchived: true });
  assert.equal(out.columns.dead_failed.length, 3);
  assert.deepEqual(out.columns.dead_failed.map((c) => Boolean(c.closed_issue)), [true, false, true]);
  assert.equal(out.dead_closed, 2);
  assert.equal(out.counts.dead_failed, 3);
});

test('a null closed set changes nothing and says it could not read', () => {
  const p = payload([build(1, 'project-5', 'TK-551')]);
  const out = excludeClosedIssues(p, null);
  assert.deepEqual(out.columns, p.columns);
  assert.equal(out.dead_closed_known, false);
});

// --- the function around it -------------------------------------------------

function withFetch(route, fn) {
  const real = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    const a = route(String(url));
    if (a instanceof Error) throw a;
    return a;
  };
  _resetClosedCache();
  _resetHeldCache();
  _resetStageCache();
  return Promise.resolve(fn(calls)).finally(() => { globalThis.fetch = real; _resetClosedCache(); _resetHeldCache(); _resetStageCache(); });
}

const jsonRes = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

const req = (search = '') => new Request(`https://console.example/api/dash/kanban/pipeline${search}`, {
  headers: { cookie: 'dash=tok' }
});

const DEAD = [
  build(1, 'project-5', 'TK-551', 'plan_blocked'),
  build(2, 'project-5', 'TK-551', 'executing'),
  build(3, 'project-5', 'TK-600', 'plan_blocked'),
  build(4, 'project-1', 'TK-551', 'plan_blocked')
];
const LEDGER = {
  ledgers: [
    { kind: 'issue_state', key: 'project-5#551', status: 'closed' },
    { kind: 'issue_state', key: 'project-5#600', status: 'open' }
  ]
};
const isJobs = (u) => u.startsWith('https://harness-jobs.operator.workers.dev/');
// The issue_state read, as opposed to the BH-2326.2 ticket_hold read that the
// same request now also makes to the jobs worker.
const isClosedRead = (u) => u.startsWith('https://harness-jobs.operator.workers.dev/api/ledger?kind=issue_state');

test('4. onRequest joins the ledger: Bearer read, filtered body, include still stripped', () =>
  withFetch((u) => (isJobs(u) ? jsonRes(LEDGER) : jsonRes(payload(DEAD))), async (calls) => {
    const res = await onRequest({ request: req('?include=nope&project=project-5'), env: { HARNESS_SECRET: 's' } });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.deepEqual(body.columns.dead_failed.map((c) => c.id), [3, 4]);
    assert.equal(body.counts.dead_failed, 2);
    assert.equal(body.dead_closed, 2);
    assert.equal(body.dead_closed_known, true);
    assert.equal(body.dead_closed_complete, true);
    const jobs = calls.filter((c) => isClosedRead(c.url));
    assert.equal(jobs.length, 1);
    assert.equal(jobs[0].url, 'https://harness-jobs.operator.workers.dev/api/ledger?kind=issue_state&limit=1000');
    assert.equal(jobs[0].init.headers.authorization, 'Bearer s');
    const consoleCall = calls.find((c) => !isJobs(c.url));
    assert.doesNotMatch(consoleCall.url, /include/);
    // The secret never rides the console call.
    assert.equal(consoleCall.init.headers.get('authorization'), null);
  }));

test('4b. onRequest audit view flags rather than drops', () =>
  withFetch((u) => (isJobs(u) ? jsonRes(LEDGER) : jsonRes(payload(DEAD))), async () => {
    const res = await onRequest({ request: req('?include=archived'), env: { HARNESS_SECRET: 's' } });
    const body = await res.json();
    assert.equal(body.columns.dead_failed.length, 4);
    assert.deepEqual(body.columns.dead_failed.filter((c) => c.closed_issue).map((c) => c.id), [1, 2]);
    assert.equal(body.dead_closed, 2);
  }));

test('the closed set is cached for a minute: two requests, one ledger read', () =>
  withFetch((u) => (isJobs(u) ? jsonRes(LEDGER) : jsonRes(payload(DEAD))), async (calls) => {
    await onRequest({ request: req(), env: { HARNESS_SECRET: 's' } });
    await onRequest({ request: req(), env: { HARNESS_SECRET: 's' } });
    assert.equal(calls.filter((c) => isClosedRead(c.url)).length, 1);
  }));

const baseline = async () => {
  // Every DEAD card carries age_min, which archiveDead reads before any clock,
  // so a fixed anchor gives the same answer as the function's own real clock.
  const b = archiveDead(payload(DEAD), { now: Date.parse('2026-09-24T12:00:00Z'), includeArchived: false });
  // The hold read fails the same way, so it marks nothing and says so too,
  // and so does the ticket_stage read (BH-6536).
  return JSON.parse(JSON.stringify({ ...b, dead_closed_known: false, held_known: false, stage_known: false }));
};

test('5. fail open: no env makes exactly one fetch and hides nothing', () =>
  withFetch(() => jsonRes(payload(DEAD)), async (calls) => {
    const res = await onRequest({ request: req() });
    assert.equal(calls.length, 1);
    assert.deepEqual(await res.json(), await baseline());
  }));

for (const [name, answer] of [
  ['jobs 403', () => new Response('no', { status: 403 })],
  ['jobs 500', () => new Response('boom', { status: 500 })],
  ['jobs non-JSON', () => new Response('<html>', { status: 200 })],
  ['jobs {}', () => jsonRes({})],
  ['jobs fetch throws', () => new Error('down')]
]) {
  test(`5. fail open: ${name} hides nothing and says so`, () =>
    withFetch((u) => (isJobs(u) ? answer() : jsonRes(payload(DEAD))), async () => {
      const res = await onRequest({ request: req(), env: { HARNESS_SECRET: 's' } });
      assert.equal(res.status, 200);
      assert.deepEqual(await res.json(), await baseline());
    }));
}

test('6. an upstream 403 makes no ledger read', () =>
  withFetch((u) => (isJobs(u) ? jsonRes(LEDGER) : new Response('forbidden', { status: 403 })), async (calls) => {
    const res = await onRequest({ request: req(), env: { HARNESS_SECRET: 's' } });
    assert.equal(res.status, 403);
    assert.equal(await res.text(), 'forbidden');
    assert.equal(calls.filter((c) => isJobs(c.url)).length, 0);
  }));

test('7. a full 1000-row ledger page is flagged incomplete', () => {
  const rows = Array.from({ length: 1000 }, (_, i) => ({ kind: 'issue_state', key: `project-5#${i + 1000}`, status: 'closed' }));
  return withFetch((u) => (isJobs(u) ? jsonRes({ ledgers: rows }) : jsonRes(payload(DEAD))), async () => {
    const body = await (await onRequest({ request: req(), env: { HARNESS_SECRET: 's' } })).json();
    assert.equal(body.dead_closed_known, true);
    assert.equal(body.dead_closed_complete, false);
  });
});

// --- carried to the screen --------------------------------------------------

const joined = (includeArchived = false) =>
  excludeClosedIssues(payload(DEAD), closed('project-5#551'), { includeArchived });

test('8. filterPipeline carries dead_closed, fleet-wide under a project filter', () => {
  const all = filterPipeline(joined(), null);
  assert.equal(all.dead_closed, 2);
  assert.equal(all.dead_closed_is_fleet_wide, false);
  assert.equal(all.dead_closed_known, true);
  const one = filterPipeline(joined(), 'project-5');
  assert.equal(one.dead_closed, 2);
  assert.equal(one.dead_closed_is_fleet_wide, true);
  // An older payload with no join says nothing about closed rows.
  const old = filterPipeline(payload(DEAD), null);
  assert.equal(old.dead_closed, null);
  assert.equal(old.dead_closed_known, false);
});

const boardProps = (view) => ({
  board: view, external: [], shipped: null, showEmpty: false, emptyNote: '', onToggleAudit: () => {}
});

test('9. the board states the closed-issue count and offers SHOW ALL when nothing is archived', () => {
  const view = filterPipeline({ ...joined(), dead_closed: 3, dead_archived: 0 }, null);
  const html = render(h(PipelineBoard, boardProps(view)));
  assert.match(html, /3 closed-issue/);
  assert.match(html, />SHOW ALL</);
  assert.match(html, /GitHub issue is closed are hidden/);
});

test('9b. the list view states it too', () => {
  const view = filterPipeline({ ...joined(), dead_closed: 3, dead_archived: 0 }, null);
  const html = render(h(PipelineList, { ...boardProps(view), board: view }));
  assert.match(html, /3 closed-issue/);
  assert.match(html, />SHOW ALL</);
});

test('9e. a capped ledger read is said on screen', () => {
  const capped = filterPipeline({ ...joined(), dead_closed_complete: false }, null);
  assert.equal(capped.dead_closed_complete, false);
  assert.match(render(h(PipelineBoard, boardProps(capped))), /1000-row cap/);
  const full = filterPipeline(joined(), null);
  assert.equal(full.dead_closed_complete, true);
  assert.doesNotMatch(render(h(PipelineBoard, boardProps(full))), /1000-row cap/);
});

test('9c. no join, no closed-issue copy', () => {
  const html = render(h(PipelineBoard, boardProps(filterPipeline(payload(DEAD), null))));
  assert.doesNotMatch(html, /closed-issue/);
});

test('9d. audit view tags ISSUE CLOSED on board cards and list rows', () => {
  const view = filterPipeline({ ...joined(true), dead_archive_include: true }, null);
  const board = render(h(PipelineBoard, boardProps(view)));
  assert.equal((board.match(/ISSUE CLOSED/g) || []).length, 2);
  const list = render(h(PipelineList, { ...boardProps(view), board: view }));
  assert.equal((list.match(/ISSUE CLOSED/g) || []).length, 2);
  assert.equal(pipelineRows(view).filter((r) => r.closedIssue).length, 2);
});
