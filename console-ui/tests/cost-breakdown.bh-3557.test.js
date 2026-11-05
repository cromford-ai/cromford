import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { api } from '../src/api.js';
import {
  BREAKDOWN_WINDOWS, BREAKDOWN_VIEWS, windowParams, billingLabel, breakdownRows, filtersFor,
  ticketHref, rowHref, childRequest, leafRows
} from '../src/lib/cost-breakdown.js';
import { CostBreakdownSection, CostBreakdownView } from '../src/screens/CostBreakdown.js';

// BH-3557: the SPEND BREAKDOWN section on /costs. The payload shape is the one
// worker/jobs/src/routes/cost-breakdown.js returns (see its test for the
// server side); this file renders the real components server-side.

const projectData = {
  since: '2099-09-25T00:00:00Z', until: '2099-09-25T12:00:00Z', group: ['project'], filters: {},
  total: { usd: 21.5, cash_usd: 8.25, equiv_usd: 12, calls: 7, unpriced_calls: 1 },
  groups: [
    { project: 'project-4', usd: 15, cash_usd: 3, equiv_usd: 12, calls: 3, unpriced_calls: 0, last_ts: '2099-09-25T11:00:00Z' },
    { project: null, usd: 0.75, cash_usd: 0.75, equiv_usd: 0, calls: 1, unpriced_calls: 0, last_ts: '2099-09-25T06:00:00Z' },
    { project: 'project-5', usd: null, cash_usd: 0, equiv_usd: 0, calls: 1, unpriced_calls: 1, last_ts: '2099-09-25T05:00:00Z' }
  ],
  truncated: false, as_of: '2099-09-25T12:00:00Z'
};

test('D1: api.costBreakdown keeps a present-empty filter and drops null/undefined', async () => {
  const seen = [];
  const prev = globalThis.fetch;
  globalThis.fetch = async (url) => { seen.push(String(url)); return new Response('{}', { status: 200 }); };
  try {
    await api.costBreakdown({ group: 'rows', project: '', stage: null, runner: undefined, since: '2099-09-25T00:00:00Z' });
  } finally { globalThis.fetch = prev; }
  const u = seen[0];
  assert.ok(u.startsWith('/api/coord/metrics/cost-breakdown?'), u);
  const q = new URLSearchParams(u.split('?')[1]);
  assert.equal(q.get('group'), 'rows');
  assert.equal(q.has('project'), true, 'the empty project filter (IS NULL) was dropped');
  assert.equal(q.get('project'), '');
  assert.equal(q.has('stage'), false);
  assert.equal(q.has('runner'), false);
  assert.equal(q.get('since'), '2099-09-25T00:00:00Z');
});

test('D2: windowParams gives UTC midnight for today and now-7d for 7d', () => {
  const now = Date.parse('2099-09-25T12:34:56Z');
  assert.deepEqual(BREAKDOWN_WINDOWS.map((w) => w.key), ['today', '7d']);
  assert.deepEqual(windowParams('today', now), { since: '2099-09-25T00:00:00Z' });
  assert.deepEqual(windowParams('7d', now), { since: '2099-09-18T12:34:56.000Z' });
});

test('D3: billing labels say which dollars are not cash', () => {
  assert.equal(billingLabel('subscription'), 'API-equivalent, not cash');
  assert.equal(billingLabel('metered'), 'cash');
  assert.equal(billingLabel(null), 'unknown');
  assert.equal(billingLabel('unknown'), 'unknown');
});

test('D4: breakdownRows labels nulls, renders null usd as — and keys two-dim groups uniquely', () => {
  const rows = breakdownRows(projectData, ['project']);
  assert.deepEqual(rows.map((r) => r.label), ['project-4', '(no project)', 'project-5']);
  assert.equal(rows[2].usdText, '—');
  assert.equal(rows[2].usd, null);
  assert.equal(rows[0].usdText, '$15.00');
  const t = breakdownRows({ groups: [{ ticket: null, usd: 1 }] }, ['ticket']);
  assert.equal(t[0].label, '(no ticket)');
  const two = breakdownRows({ groups: [
    { runner: 'codex', model: 'a', usd: 1 }, { runner: 'codex', model: 'b', usd: 2 },
    { runner: null, model: 'a', usd: 3 }, { runner: 'a', model: null, usd: 4 }
  ] }, ['runner', 'model']);
  assert.equal(new Set(two.map((r) => r.key)).size, 4);
  assert.equal(two[2].label, '(none) · a');
  const bill = breakdownRows({ groups: [{ billing_mode: 'subscription', usd: 1 }] }, ['billing_mode']);
  assert.equal(bill[0].label, 'API-equivalent, not cash');
});

test('D5: filtersFor turns a null dim into "" (IS NULL) and keeps the parent filters', () => {
  const [project_4, none] = breakdownRows(projectData, ['project']);
  assert.deepEqual(filtersFor(project_4, ['project'], {}), { project: 'project-4' });
  assert.deepEqual(filtersFor(none, ['project'], {}), { project: '' });
  const [stage] = breakdownRows({ groups: [{ stage: 'triage', usd: 1 }] }, ['stage']);
  assert.deepEqual(filtersFor(stage, ['stage'], { project: '' }), { project: '', stage: 'triage' });
});

test('D6: ticketHref and rowHref prefer the build, then the job, then nothing', () => {
  assert.equal(ticketHref({ last_run_id: 'r1', last_job_id: 'j1' }), '/builds/r1');
  assert.equal(ticketHref({ last_run_id: null, last_job_id: 'j1' }), '/jobs/j1');
  assert.equal(ticketHref({}), null);
  assert.equal(rowHref({ run_id: 'r 2', job_id: 'j' }), '/builds/r%202');
  assert.equal(rowHref({ job_id: 'j' }), '/jobs/j');
  assert.equal(rowHref({}), null);
});

test('D6b: every view drills to rows; childRequest walks the levels', () => {
  assert.deepEqual(BREAKDOWN_VIEWS.map((v) => v.key), ['project', 'runner', 'billing', 'ticket']);
  const [project_4] = breakdownRows(projectData, ['project']);
  const c1 = childRequest('project', 0, project_4, {});
  assert.deepEqual(c1.params, { project: 'project-4', group: 'stage' });
  const [stage] = breakdownRows({ groups: [{ stage: 'triage', usd: 1 }] }, ['stage']);
  const c2 = childRequest('project', 1, stage, c1.filters);
  assert.deepEqual(c2.params, { project: 'project-4', stage: 'triage', group: 'rows' });
  assert.notEqual(c1.key, c2.key);
  const [t] = breakdownRows({ groups: [{ ticket: 'BH-1', usd: 1 }] }, ['ticket']);
  assert.deepEqual(childRequest('ticket', 0, t, {}).params, { ticket: 'BH-1', group: 'rows' });
});

const noop = () => {};
const base = { data: projectData, error: null, loading: false, reload: noop, win: 'today', onWin: noop,
  view: 'project', onView: noop, open: [], onOpen: noop, kids: {} };
const view = (over = {}) => render(h(CostBreakdownView, { ...base, ...over }));

test('D7a: the section renders its title, switchers, sortable headers and expand buttons', () => {
  const out = view();
  assert.ok(out.includes('SPEND BREAKDOWN'));
  assert.ok(out.includes('API-equivalent, not cash'), 'the note labels the subscription dollars');
  assert.ok(out.includes('$21.50'));
  for (const w of ['TODAY', '7D', 'PROJECT → STAGE', 'RUNNER · MODEL', 'BILLING', 'TOP TICKETS']) {
    assert.ok(out.includes(`>${w}<`), `no ${w} button`);
  }
  assert.ok((out.match(/aria-pressed="true"/g) || []).length === 2, 'one window and one view pressed');
  assert.match(out, /<th[^>]*aria-sort="descending"[^>]*>[\s\S]*?\$</, 'the $ header is the sorted one');
  assert.equal((out.match(/aria-expanded="false"/g) || []).length, 3, 'every group row expands');
  assert.ok(out.includes('href="/p/project-4"'), 'a project links to its page');
  assert.ok(out.includes('(no project)'));
});

test('D7b: empty, error, loading and truncated states', () => {
  const empty = view({ data: { ...projectData, groups: [], total: { usd: null, cash_usd: 0, equiv_usd: 0, calls: 0, unpriced_calls: 0 } } });
  assert.ok(empty.includes('no spend in this window'));
  const err = view({ data: null, error: new Error('http_500') });
  assert.ok(err.includes('RETRY'));
  assert.ok(err.includes('http_500'));
  const loading = view({ data: null, loading: true });
  assert.ok(!loading.includes('no spend in this window'));
  const capped = view({ data: { ...projectData, truncated: true } });
  assert.ok(capped.includes('capped'));
});

test('D7c: an open row drills to stages, then to cost rows that link to their build', () => {
  const [project_4] = breakdownRows(projectData, ['project']);
  const c1 = childRequest('project', 0, project_4, {});
  const [stage] = breakdownRows({ groups: [{ stage: 'triage', usd: 5 }] }, ['stage']);
  const c2 = childRequest('project', 1, stage, c1.filters);
  const kids = {
    [c1.key]: { data: { group: ['stage'], groups: [{ stage: 'triage', usd: 5, cash_usd: 3, equiv_usd: 2, calls: 2, unpriced_calls: 0 }], total: {}, truncated: false } },
    [c2.key]: { data: { rows: [
      { ts: '2099-09-25T11:00:00Z', project: 'project-4', stage: 'triage', runner: 'codex', model: 'model-x',
        billing_mode: 'subscription', ticket: 'BH-1', run_id: 'run-a2', job_id: 'job-a2', cost_usd: 2 },
      { ts: '2099-09-25T10:00:00Z', project: 'project-4', stage: 'triage', runner: 'codex', model: 'model-x',
        billing_mode: 'metered', ticket: null, run_id: null, job_id: 'job-a1', cost_usd: 3 }
    ], truncated: true } }
  };
  const out = view({ open: [project_4.key, stage.key], kids });
  assert.ok(out.includes('aria-expanded="true"'));
  assert.ok(out.includes('>triage<'), 'the stage level rendered');
  assert.ok(out.includes('href="/builds/run-a2"'), 'a leaf row links to its build');
  assert.ok(out.includes('href="/jobs/job-a1"'), 'a row with no build links to its job');
  assert.ok(out.includes('capped: newest 2 rows'));
  for (const hdr of ['WHEN', 'RUNNER', 'MODEL', 'BILLING', 'TICKET']) assert.ok(out.includes(hdr), hdr);
  // a child still loading shows a skeleton; a child error shows an ErrorBox
  const loadingOut = view({ open: [project_4.key], kids: { [c1.key]: { loading: true } } });
  assert.match(loadingOut, /class="skel"/, "a loading child shows the Skeleton");
  const errOut = view({ open: [project_4.key], kids: { [c1.key]: { error: new Error('child_down') } } });
  assert.ok(errOut.includes('child_down'));
});

test('D7d: the TOP TICKETS view links each ticket to its newest build or job', () => {
  const data = { ...projectData, group: ['ticket'], groups: [
    { ticket: 'BH-1', usd: 5, last_run_id: 'run-a2', last_job_id: 'job-a2', calls: 2 },
    { ticket: 'BH-9', usd: 1, last_run_id: null, last_job_id: 'job-9', calls: 1 },
    { ticket: null, usd: 1, last_run_id: null, last_job_id: null, calls: 1 }
  ] };
  const out = view({ view: 'ticket', data });
  assert.ok(out.includes('href="/builds/run-a2"'));
  assert.ok(out.includes('href="/jobs/job-9"'));
  assert.ok(out.includes('(no ticket)'));
  assert.equal((out.match(/aria-expanded=/g) || []).length, 3, 'a ticket with no link still expands');
});

test('D8: the production entry renders and Costs.js mounts it under the spend headline', () => {
  const out = render(h(CostBreakdownSection));
  assert.ok(out.includes('SPEND BREAKDOWN'));
  const costs = readFileSync(new URL('../src/screens/Costs.js', import.meta.url), 'utf8');
  assert.ok(costs.includes("import { CostBreakdownSection } from './CostBreakdown.js';"));
  const spend = costs.indexOf('<${SpendSection}');
  const at = costs.indexOf('<${CostBreakdownSection}/>');
  assert.ok(spend > -1 && at > -1, 'both sections are rendered');
  assert.equal(costs.slice(spend, at).split('\n').length, 2, 'directly under SpendSection');
});
