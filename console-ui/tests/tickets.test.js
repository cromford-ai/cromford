import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  TICKET_STATUSES, ticketColumns, ticketProjects, projectInSnapshot,
  snapshotAgeMinFromEpochSeconds, snapshotUsable, ticketTriage
} from '../src/lib/tickets.js';

const t = (key, status) => ({ key, status, title: `t ${key}`, updatedAt: '2026-08-24T00:00:00Z' });

// ------------------------------------------------------------ the epoch unit

// determinism: ok-file clock-now-js the unit under test IS an age against now, so every case is an
// offset from one captured read (or a deliberate ms-for-seconds value) — never a date.
test('generated_at_epoch is SECONDS, not milliseconds', () => {
  // Treating seconds as ms dates the snapshot to 1970 and renders an age of
  // ~29 million minutes; treating ms as seconds puts it 50,000 years ahead.
  // Either way the banner is confidently, absurdly wrong, so the unit is pinned.
  const nowSec = Math.floor(Date.now() / 1000);
  assert.equal(snapshotAgeMinFromEpochSeconds(nowSec), 0);
  assert.equal(snapshotAgeMinFromEpochSeconds(nowSec - 240), 4);
  assert.equal(snapshotAgeMinFromEpochSeconds(nowSec - 3600), 60);
});

test('a millisecond value is rejected rather than rendered as the far future', () => {
  // If the contract ever changes under us, a wrong-by-1000x age must not be
  // presented as fact.
  assert.equal(snapshotAgeMinFromEpochSeconds(Date.now()), null);
});

test('a missing or unusable epoch is unknown, never zero', () => {
  assert.equal(snapshotAgeMinFromEpochSeconds(null), null);
  assert.equal(snapshotAgeMinFromEpochSeconds(undefined), null);
  assert.equal(snapshotAgeMinFromEpochSeconds('nonsense'), null);
  assert.equal(snapshotAgeMinFromEpochSeconds(0), null);
});

test('a clock skewed slightly ahead reads as now, not as negative', () => {
  const aheadSec = Math.floor(Date.now() / 1000) + 30;
  assert.equal(snapshotAgeMinFromEpochSeconds(aheadSec), 0);
});

// --------------------------------------------------------------- the columns

test('the four statuses render in pipeline order, always', () => {
  assert.deepEqual(TICKET_STATUSES, ['todo', 'in_progress', 'review', 'done']);
  const cols = ticketColumns([t('A', 'done'), t('B', 'todo')]);
  assert.deepEqual(cols.map((c) => c.key), ['todo', 'in_progress', 'review', 'done']);
});

test('an empty status still gets a column, so a board never looks truncated', () => {
  const cols = ticketColumns([t('A', 'done')]);
  const inProgress = cols.find((c) => c.key === 'in_progress');
  assert.equal(inProgress.count, 0);
  assert.deepEqual(inProgress.tickets, []);
});

test('counts and grouping match the real board shape', () => {
  // project-1: 180 done / 60 review / 5 in_progress / 2 todo of 247
  const tickets = [
    ...Array.from({ length: 180 }, (_, i) => t(`D${i}`, 'done')),
    ...Array.from({ length: 60 }, (_, i) => t(`R${i}`, 'review')),
    ...Array.from({ length: 5 }, (_, i) => t(`P${i}`, 'in_progress')),
    ...Array.from({ length: 2 }, (_, i) => t(`T${i}`, 'todo'))
  ];
  const cols = ticketColumns(tickets);
  const by = Object.fromEntries(cols.map((c) => [c.key, c.count]));
  assert.deepEqual(by, { todo: 2, in_progress: 5, review: 60, done: 180 });
  assert.equal(cols.reduce((n, c) => n + c.count, 0), 247);
});

test('an unrecognised status is surfaced, never silently dropped', () => {
  // A ticket that vanishes because its status is new is a silent cap: the
  // column totals would stop adding up to the board total and nobody would know.
  const cols = ticketColumns([t('A', 'done'), t('B', 'archived'), t('C', null)]);
  const keys = cols.map((c) => c.key);
  assert.equal(keys.includes('archived'), true, 'unknown status gets its own column');
  assert.equal(cols.reduce((n, c) => n + c.count, 0), 3, 'every ticket is still accounted for');
  const unknown = cols.find((c) => c.key === 'unknown');
  assert.equal(unknown.count, 1, 'a null status is its own honest bucket');
});

test('extra statuses sort after the four known ones', () => {
  const cols = ticketColumns([t('A', 'archived'), t('B', 'todo')]);
  assert.equal(cols.findIndex((c) => c.key === 'archived') > cols.findIndex((c) => c.key === 'done'), true);
});

// -------------------------------------------------------------- the projects

test('a project the snapshot does not carry is honestly absent', () => {
  // gh-issues and jira projects have no OS board, so they are not in the
  // snapshot at all — that is a normal state, not a fetch failure.
  const snap = { projects: { 'project-1': { board_id: 'b', tickets: [] } } };
  assert.equal(projectInSnapshot(snap, 'project-1'), true);
  assert.equal(projectInSnapshot(snap, 'project-6'), false);
  assert.equal(projectInSnapshot(null, 'project-1'), false);
});

test('the snapshot project list is whatever it carries', () => {
  const snap = { projects: { 'project-1': {}, 'project-4': {} } };
  assert.deepEqual(ticketProjects(snap).sort(), ['project-1', 'project-4']);
  assert.deepEqual(ticketProjects(null), []);
  assert.deepEqual(ticketProjects({}), []);
});

test('a project present but with no tickets is empty, not missing', () => {
  const snap = { projects: { 'project-3': { board_id: 'b', tickets: [] } } };
  assert.equal(projectInSnapshot(snap, 'project-3'), true);
  assert.equal(ticketColumns(snap.projects['project-3'].tickets).reduce((n, c) => n + c.count, 0), 0);
});

// ------------------------------------------- the snapshot itself can be absent

test('ok:false with a reason is unusable, however healthy the HTTP status was', () => {
  // The console answers 200 with {ok:false, unavailable:"..."} when the
  // watchdog read fails. Guarding only on loading/error lets that through as a
  // successful empty snapshot.
  const s = snapshotUsable({ ok: false, unavailable: 'watchdog unreachable', projects: {} });
  assert.equal(s.usable, false);
  assert.equal(s.reason, 'watchdog unreachable');
});

test('ok:true with no projects means the hub has not pushed yet, not that no boards exist', () => {
  // Before the hub's 10-min cron first fires, the KV key does not exist and the
  // route answers 200 {ok:true, projects:{}}. Falling through to the per-project
  // map renders "no OS board for this project" for four projects that HAVE one —
  // a confident, false, and very believable statement.
  const s = snapshotUsable({ ok: true, projects: {} });
  assert.equal(s.usable, false);
  assert.match(s.reason, /has not pushed .*yet/i, 'the reason must say the hub has not pushed yet');
});

test('a snapshot carrying projects is usable', () => {
  const s = snapshotUsable({ ok: true, projects: { 'project-1': { tickets: [] } } });
  assert.equal(s.usable, true);
  assert.equal(s.reason, null);
});

test('a missing or malformed payload is unusable rather than assumed empty', () => {
  assert.equal(snapshotUsable(null).usable, false);
  assert.equal(snapshotUsable({}).usable, false);
  assert.equal(snapshotUsable({ ok: true }).usable, false);
});

test('unavailable wins over emptiness so the operator gets the REAL reason', () => {
  const s = snapshotUsable({ ok: false, unavailable: 'KV read timed out', projects: {} });
  assert.equal(s.reason, 'KV read timed out');
});

// ------------------------------------ triage fields, before AND after the hub ships them

test('a block is never invented from half the fields', () => {
  // Rendering a block (or a clearance) from partial data would invent a triage
  // verdict. Only the full pair blocks.
  assert.equal(ticketTriage({ key: 'A' }).blockedOnClient, false);
  assert.equal(ticketTriage({ key: 'A', triage_verdict: 'needs_clarification' }).blockedOnClient, false);
  assert.equal(ticketTriage({ key: 'A', waiting_on: 'client' }).blockedOnClient, false);
  assert.equal(ticketTriage({ key: 'A', waiting_on: 'client' }).state, 'untriaged');
  const t = ticketTriage({ key: 'A', triage_verdict: 'needs_clarification', waiting_on: 'client' });
  assert.equal(t.blockedOnClient, true);
  assert.equal(t.state, 'blocked_on_client');
});

test('needs_clarification + waiting on client is NOT buildable — the standing rule', () => {
  const t = ticketTriage({ key: 'A', triage_verdict: 'needs_clarification', waiting_on: 'client' });
  assert.equal(t.blockedOnClient, true);
});

test('the same verdict waiting on the TEAM is ours to act on, not the client', () => {
  const t = ticketTriage({ key: 'A', triage_verdict: 'needs_clarification', waiting_on: 'team' });
  assert.equal(t.blockedOnClient, false);
  assert.equal(t.assessed, true);
  assert.equal(t.state, 'assessed');
});

test('a cleared verdict is not blocked', () => {
  const t = ticketTriage({ key: 'A', triage_verdict: 'ready', waiting_on: 'team' });
  assert.equal(t.blockedOnClient, false);
});

test('triage fields are read in BOTH casings', () => {
  // The hub's push and the client board APIs do not agree on casing, and a
  // camelCase-only payload read as snake_case yields "no verdict" — which
  // renders a blocked ticket as though nothing were wrong.
  const snake = ticketTriage({ key: 'A', triage_verdict: 'needs_clarification', waiting_on: 'client' });
  const camel = ticketTriage({ key: 'A', triageVerdict: 'needs_clarification', waitingOn: 'client' });
  assert.equal(snake.blockedOnClient, true);
  assert.equal(camel.blockedOnClient, true);
  assert.equal(camel.assessed, true);
});

test('mixed casing on one ticket still resolves', () => {
  const mixed = ticketTriage({ key: 'A', triageVerdict: 'needs_clarification', waiting_on: 'client' });
  assert.equal(mixed.blockedOnClient, true);
});

test('casing does not change the not-blocked answers', () => {
  assert.equal(ticketTriage({ triageVerdict: 'needs_clarification', waitingOn: 'team' }).blockedOnClient, false);
  assert.equal(ticketTriage({ triageVerdict: 'ready', waitingOn: 'client' }).blockedOnClient, false);
  assert.equal(ticketTriage({ waitingOn: 'client' }).state, 'untriaged', 'one field alone is still not a verdict');
});

// ------------------------------------- three states, and untriaged is explicit

test('an explicit "untriaged" verdict is its own state, not a real verdict', () => {
  // The hub now names it instead of sending "". Rendering "untriaged" as though
  // it were an assessment would let 89 unassessed tickets read as looked-at.
  const t = ticketTriage({ key: 'A', triage_verdict: 'untriaged', waiting_on: 'team' });
  assert.equal(t.state, 'untriaged');
  assert.equal(t.assessed, false);
  assert.equal(t.blockedOnClient, false);
});

test('absent fields land in the SAME untriaged state as the named value', () => {
  // Old snapshots and new ones must look identical to an operator: both mean
  // "nobody has assessed this yet".
  assert.equal(ticketTriage({ key: 'A' }).state, 'untriaged');
  assert.equal(ticketTriage({ key: 'A', triage_verdict: '' }).state, 'untriaged');
  assert.equal(ticketTriage({ key: 'A', waiting_on: 'client' }).state, 'untriaged',
    'waiting_on alone is not an assessment — there is no verdict to act on');
  assert.equal(ticketTriage(null).state, 'untriaged');
});

test('untriaged is NEVER a buildable signal', () => {
  // The invariant. If this ever flips, an unassessed ticket looks ready to build.
  for (const ticket of [
    { triage_verdict: 'untriaged', waiting_on: 'team' },
    { triageVerdict: 'untriaged', waitingOn: 'client' },
    {},
    { waiting_on: 'team' }
  ]) {
    const t = ticketTriage(ticket);
    assert.equal(t.assessed, false, JSON.stringify(ticket));
    assert.equal(t.blockedOnClient, false, JSON.stringify(ticket));
    assert.equal(t.state, 'untriaged', JSON.stringify(ticket));
  }
});

test('untriaged in either casing is still untriaged', () => {
  assert.equal(ticketTriage({ triageVerdict: 'untriaged', waitingOn: 'team' }).state, 'untriaged');
});

test('a real verdict is assessed and keeps its existing handling', () => {
  const t = ticketTriage({ key: 'A', triage_verdict: 'ready', waiting_on: 'team' });
  assert.equal(t.state, 'assessed');
  assert.equal(t.assessed, true);
  assert.equal(t.blockedOnClient, false);
  assert.equal(t.verdict, 'ready');
  assert.equal(t.waitingOn, 'team');
});

test('blocked-on-client stays its own state, above assessed', () => {
  const t = ticketTriage({ key: 'A', triage_verdict: 'needs_clarification', waiting_on: 'client' });
  assert.equal(t.state, 'blocked_on_client');
  assert.equal(t.blockedOnClient, true);
  assert.equal(t.assessed, true, 'it HAS been assessed — the assessment is what blocks it');
});

test('a real verdict without waiting_on is still assessed, just not blocked', () => {
  // triage_verdict coverage is ~80-90% while waiting_on is 100%, so the reverse
  // gap is the likelier one — but neither may invent a block.
  const t = ticketTriage({ key: 'A', triage_verdict: 'needs_clarification' });
  assert.equal(t.state, 'assessed');
  assert.equal(t.blockedOnClient, false, 'a block needs BOTH halves');
});

test('the three states are exhaustive', () => {
  const seen = new Set([
    ticketTriage({ triage_verdict: 'needs_clarification', waiting_on: 'client' }).state,
    ticketTriage({ triage_verdict: 'ready', waiting_on: 'team' }).state,
    ticketTriage({ triage_verdict: 'untriaged', waiting_on: 'team' }).state,
    ticketTriage({}).state
  ]);
  assert.deepEqual([...seen].sort(), ['assessed', 'blocked_on_client', 'untriaged']);
});

// -------------------------------- values are compared case- and space-insensitively

test('an upper-case "Client" still blocks — the dangerous direction', () => {
  // The hub normalises field NAMES across the four board APIs but passes
  // VALUES verbatim. A board returning "Client" would otherwise classify a
  // genuine client-block as merely "assessed" — downgrading a not-buildable
  // ticket into one that looks actionable. That is the direction that costs.
  for (const t of [
    { triage_verdict: 'needs_clarification', waiting_on: 'Client' },
    { triage_verdict: 'Needs_Clarification', waiting_on: 'client' },
    { triage_verdict: 'NEEDS_CLARIFICATION', waiting_on: 'CLIENT' },
    { triageVerdict: 'Needs_Clarification', waitingOn: 'Client' }
  ]) {
    const r = ticketTriage(t);
    assert.equal(r.blockedOnClient, true, JSON.stringify(t));
    assert.equal(r.state, 'blocked_on_client', JSON.stringify(t));
  }
});

test('surrounding whitespace never changes the classification', () => {
  const r = ticketTriage({ triage_verdict: '  needs_clarification  ', waiting_on: ' client ' });
  assert.equal(r.blockedOnClient, true);
});

test('a capitalised "Untriaged" is untriaged, not a real verdict', () => {
  // Otherwise it prints as though someone had assessed the ticket.
  for (const v of ['Untriaged', 'UNTRIAGED', ' untriaged ']) {
    const r = ticketTriage({ triage_verdict: v, waiting_on: 'team' });
    assert.equal(r.state, 'untriaged', v);
    assert.equal(r.assessed, false, v);
  }
});

test('normalised values are what render, so boards that disagree look the same', () => {
  const r = ticketTriage({ triage_verdict: 'Needs_Clarification', waiting_on: 'Team' });
  assert.equal(r.verdict, 'needs_clarification');
  assert.equal(r.waitingOn, 'team');
});

test('casing does not manufacture a block that was not there', () => {
  // The safe direction must stay safe too: normalising must not turn a
  // team-waiting ticket into a client-block.
  assert.equal(ticketTriage({ triage_verdict: 'Needs_Clarification', waiting_on: 'Team' }).blockedOnClient, false);
  assert.equal(ticketTriage({ triage_verdict: 'Ready', waiting_on: 'Client' }).blockedOnClient, false);
});

test('a malformed value falls to the SAFE state, never to a real-looking verdict', () => {
  // A board returning a number or a boolean must not crash the tab — and must
  // not coerce into an assessment either: String(0) is "0", which would read as
  // "someone assessed this". Garbage in means unassessed, not cleared.
  assert.equal(ticketTriage({ triage_verdict: 0, waiting_on: 'client' }).state, 'untriaged');
  assert.equal(ticketTriage({ triage_verdict: true, waiting_on: 'client' }).state, 'untriaged');
  assert.equal(ticketTriage({ triage_verdict: {}, waiting_on: 'client' }).state, 'untriaged');
  assert.equal(ticketTriage({ triage_verdict: 'needs_clarification', waiting_on: 1 }).blockedOnClient, false,
    'a malformed waiting_on cannot complete a block');
});

test('a whitespace-only value counts as absent, not as a verdict', () => {
  assert.equal(ticketTriage({ triage_verdict: '   ', waiting_on: 'client' }).state, 'untriaged');
});
