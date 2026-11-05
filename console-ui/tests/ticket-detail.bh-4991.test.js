// BH-4991 (BH-4947 wave 2): the ticket page, /t/<KEY>.
//
// The page is built from reads the console already makes: the ticket's job rows
// (api.jobs({ticket_id})), the newest build job's detail (api.job: phases,
// stage events, transcript index), the project row (api.projects) and, when a
// PR exists, the PR payload (api.pr: title, files). The pure parts are tested
// here; the view is rendered to a string. The scope's acceptance cases:
//   - the cost total equals the sum of the stage rows
//   - a station click targets the first event of that stage
//   - an unknown key renders a not-found state, not a blank page
// (File name per the scope update: console-ui runs tests/*.test.js only.)

import test from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';
import { assertNoRawHeaders, assertUsdLabelled } from './legibility.bh-3558.js';

globalThis.window = globalThis.window || {
  location: { pathname: '/t/BH-4991', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { render } = await import('preact-render-to-string');
const { jobRows } = await import('../src/lib/jobs.js');
const D = await import('../src/lib/ticket-detail.js');
const { TicketView } = await import('../src/screens/Ticket.js');

const NOW = Date.parse('2026-10-09T21:00:00Z');
const iso = (minAgo) => new Date(NOW - minAgo * 60000).toISOString();
const visible = (html) => html.replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/\s+/g, ' ');

const JOBS = {
  as_of: iso(0),
  jobs: [
    { id: 'tr-1', project: 'cromford', ticket_id: 'BH-4991', kind: 'triage', box: 'hub', stage: 'done', status: 'done',
      spent_usd: 0.14, created_at: iso(90), updated_at: iso(88), age_s: 5400 },
    { id: 'b-1', project: 'cromford', ticket_id: 'BH-4991', kind: 'build', box: 'pool-802e', stage: 'review', status: 'running',
      heartbeating: true, beat_age_s: 20, spent_usd: 12.5, budget_usd: 60, created_at: iso(60), updated_at: iso(1), age_s: 3600,
      meta: JSON.stringify({ build: 'bh-4991-1', ticket_id: 'BH-4991', pr_url: 'https://github.com/example-org/cromford/pull/5900' }) }
  ]
};
const DETAIL = {
  job: JOBS.jobs[1],
  phases: [
    { id: 1, phase: 'plan', runner: 'claude', model: 'claude-opus-5-5', status: 'done', rc: 0, spend_usd: 3.1, started_at: iso(58), finished_at: iso(50) },
    { id: 2, phase: 'execute', runner: 'claude', model: 'claude-opus-5-5', status: 'done', rc: 0, spend_usd: 6.4, started_at: iso(49), finished_at: iso(20) },
    { id: 3, phase: 'fix_round', runner: 'claude', model: 'claude-opus-5-5', status: 'done', rc: 0, spend_usd: 1.0, started_at: iso(19), finished_at: iso(12) },
    { id: 4, phase: 'review', runner: 'claude', model: 'claude-sonnet-5-5', status: 'running', rc: null, spend_usd: null, started_at: iso(10), finished_at: null }
  ],
  events: [
    { id: 11, created_at: iso(58), stage: 'plan', verdict: null, actor: 'pool-802e', detail: 'Scope: ticket page, steer notes.' },
    { id: 12, created_at: iso(49), stage: 'execute', verdict: null, actor: 'pool-802e', detail: 'tests red: 3 failing (expected)\n✗ T1\n✗ T2' },
    { id: 13, created_at: iso(30), stage: 'execute', verdict: null, actor: 'pool-802e', detail: 'tests green' },
    { id: 14, created_at: iso(10), stage: 'review', verdict: 'APPROVE', actor: 'pool-802e', detail: 'Lead: MERGE' }
  ],
  transcripts: [],
  ledgers: []
};
const PR = { gh: { title: 'Ticket detail page', state: 'open', head: { ref: 'ticket/bh-4991' } },
  files: [{ filename: 'console-ui/src/screens/Ticket.js', status: 'modified', additions: 300, deletions: 60 }], builds: [{ verdict: 'APPROVE' }] };
const PROJECT = { project: 'cromford', repo: 'example-org/cromford' };

test('T1 the cost total equals the sum of the stage rows, and each row names its station', () => {
  const c = D.stageCosts(DETAIL.phases);
  assert.deepEqual(c.rows.map((r) => r.stage), ['plan', 'execute', 'fix_round', 'review']);
  const sum = c.rows.reduce((n, r) => n + (r.cost ?? 0), 0);
  assert.equal(c.total, sum);
  assert.equal(Math.round(c.total * 100), 1050, 'review has no spend yet: not measured, never zero');
  assert.equal(c.rows.find((r) => r.stage === 'review').cost, null);
  assert.deepEqual(c.rows.map((r) => r.station), [1, 2, 2, 3]);
  const out = render(h(TicketView, { ticket: 'BH-4991', rows: jobRows(JOBS), detail: DETAIL, pr: PR, project: PROJECT, nowMs: NOW }));
  assert.match(visible(out), /Cost by stage/);
  assert.match(visible(out), /\$10\.50/, 'the card shows the same total');
  assertNoRawHeaders(out);
  assertUsdLabelled(out);
});

test('T2 a station click targets the first event of that stage', () => {
  const tl = D.eventTimeline(DETAIL.events);
  assert.deepEqual(tl.map((e) => e.station), [1, 2, 2, 3]);
  assert.equal(D.firstEventOf(tl, 2), 12, 'the first execute event, not the last');
  assert.equal(D.firstEventOf(tl, 3), 14);
  assert.equal(D.firstEventOf(tl, 6), null, 'a station with no event targets nothing');
  const out = render(h(TicketView, { ticket: 'BH-4991', rows: jobRows(JOBS), detail: DETAIL, pr: PR, project: PROJECT, nowMs: NOW }));
  // Each station with an event is a button aimed at its first event's anchor.
  assert.match(out, /data-target="ev-12"/);
  assert.match(out, /id="ev-12"/);
  assert.doesNotMatch(out, /data-target="ev-13"/);
  // Output longer than one line is folded under a summary.
  assert.match(out, /<details[^>]*><summary[^>]*>Output<\/summary><pre[^>]*>tests red: 3 failing/);
});

test('T3 the meta line links project, issue, PR, box; the actions link GitHub and the diff', () => {
  const f = D.ticketFacts({ ticket: 'BH-4991', rows: jobRows(JOBS), detail: DETAIL, pr: PR, project: PROJECT });
  assert.equal(f.issueUrl, 'https://github.com/example-org/cromford/issues/4991');
  assert.equal(f.prUrl, 'https://github.com/example-org/cromford/pull/5900');
  assert.equal(f.prNumber, 5900);
  assert.equal(f.title, 'Ticket detail page');
  assert.equal(f.branch, 'ticket/bh-4991');
  assert.equal(f.model, 'claude-sonnet-5-5', 'the model of the newest phase');
  assert.equal(Math.round(f.cost * 100), 1264, 'every job row of the ticket counts');
  assert.equal(f.runningJobId, 'b-1');
  const out = render(h(TicketView, { ticket: 'BH-4991', rows: jobRows(JOBS), detail: DETAIL, pr: PR, project: PROJECT, nowMs: NOW }));
  for (const href of ['/p/cromford', 'https://github.com/example-org/cromford/issues/4991',
    '/pr/cromford/5900', 'https://github.com/example-org/cromford/pull/5900/files',
    '/machines', '/jobs/b-1', '/jobs/tr-1']) {
    assert.ok(out.includes(`href="${href}"`), `links ${href}`);
  }
  assert.match(visible(out), /console-ui\/src\/screens\/Ticket\.js/);
  assert.match(out, /<h1 class="line-headline">BH-4991<br\/><span class="line-headline__dim">Ticket detail page<\/span>/);
});

test('T4 an unknown key renders a not-found state, not a blank page', () => {
  const out = render(h(TicketView, { ticket: 'BH-999999', rows: [], detail: null, pr: null, project: null, nowMs: NOW }));
  assert.match(visible(out), /No job has claimed BH-999999\./);
  assert.match(out, /<a href="\/jobs"/);
  assert.ok(visible(out).trim().length > 40, 'says something');
});

test('T5 a ticket with only job rows (no detail yet) still renders its jobs and track', () => {
  const out = render(h(TicketView, { ticket: 'BH-4991', rows: jobRows(JOBS), asOf: iso(0) }));
  assert.match(out, /aria-label="BH-4991 at Review \(now\)"/);
  assert.match(out, /<a href="\/jobs\/b-1"/);
});

// Lead review lr-5838-8d23460f4 BLOCK: only a project whose tickets ARE GitHub
// issues (no board API, fleet.conf board prefix "-") gets the issue link. project-3
// TK-70 lives on its own product board; github.com/<repo>/issues/70 would be an
// unrelated issue, shown as if it were the ticket.
test('T6 a board-API project gets no GitHub issue link; an unknown project gets none either', () => {
  const project_3Jobs = { as_of: iso(0), jobs: [{ ...JOBS.jobs[1], id: 'b-70', project: 'project-3', ticket_id: 'TK-70', meta: null }] };
  const project_3 = { project: 'project-3', repo: 'example-org/project-3', board_api_prefix: '/api/feature-board' };
  const f = D.ticketFacts({ ticket: 'TK-70', rows: jobRows(project_3Jobs), detail: null, pr: null, project: project_3 });
  assert.equal(f.issueUrl, null);
  const out = render(h(TicketView, { ticket: 'TK-70', rows: jobRows(project_3Jobs), project: project_3 }));
  assert.doesNotMatch(out, /github\.com\/example-org\/project-3\/issues/);
  assert.doesNotMatch(visible(out), /OPEN ON GITHUB|Issue #70/);
  // No project row: the board type is not known, so no issue link is guessed.
  const g = D.ticketFacts({ ticket: 'BH-4991', rows: jobRows(JOBS), detail: DETAIL, pr: PR, project: null });
  assert.equal(g.issueUrl, null);
  // A GitHub-issues project (no board API, or the "-" placeholder) keeps it.
  for (const p of [null, '', '-']) {
    const k = D.ticketFacts({ ticket: 'BH-4991', rows: jobRows(JOBS), detail: DETAIL, pr: PR, project: { ...PROJECT, board_api_prefix: p } });
    assert.equal(k.issueUrl, 'https://github.com/example-org/cromford/issues/4991', `board_api_prefix ${JSON.stringify(p)}`);
  }
});
