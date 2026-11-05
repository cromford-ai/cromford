import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import {
  fmtSeconds, fmtRate, fmtFrequency, projectRows, slowRows, basisNote, isThin, THIN_SAMPLE
} from '../src/lib/dora.js';
import { sortRows } from '../src/lib/sort.js';
import { DoraProjectTable, DoraSlowestTable, projectColumns, slowColumns } from '../src/screens/DORA.js';

// The DORA panel's failure mode is not a crash — it is a confident wrong
// number that somebody then goes and optimises. What is pinned here:
//
//   * a duration the worker could not measure renders `—`, never "0s";
//   * a rate that does not exist renders `—`, never "0%" (which is the OPPOSITE
//     claim: "nothing came back" about a window in which nothing went out);
//   * every column sorts on the RAW number, so "2h" never sorts above "1d";
//   * a thin sample is MARKED — a p90 over two PRs is the slower of the two;
//   * no dead rows: every PR, project and job cell is a link.

// --- formatting --------------------------------------------------------------

test('a duration nobody measured is — and never zero', () => {
  assert.equal(fmtSeconds(null), '—');
  assert.equal(fmtSeconds(undefined), '—');
  assert.equal(fmtSeconds(NaN), '—');
  assert.equal(fmtSeconds('not a number'), '—');
  // A real zero is a real zero: a PR merged the same second its job opened.
  assert.equal(fmtSeconds(0), '0s');
});

test('durations read in the unit a human would use', () => {
  assert.equal(fmtSeconds(45), '45s');
  assert.equal(fmtSeconds(90), '2m');
  assert.equal(fmtSeconds(3600), '1h');
  assert.equal(fmtSeconds(3600 + 1800), '1h 30m');
  assert.equal(fmtSeconds(86400), '1d');
  assert.equal(fmtSeconds(86400 * 3 + 3600 * 4), '3d 4h');
});

test('a rate that does not exist is — and never 0%', () => {
  assert.equal(fmtRate(null), '—');
  assert.equal(fmtRate(undefined), '—');
  // A measured zero is a real fact and must still render as one.
  assert.equal(fmtRate(0), '0.0%');
  assert.equal(fmtRate(0.25), '25%');
  // Under 10% a whole percent hides the difference between 1 bad merge in 40
  // and 3 in 40, which is the range these repos actually live in.
  assert.equal(fmtRate(0.025), '2.5%');
  assert.equal(fmtRate(1), '100%');
});

test('below one a day, frequency reads as an interval rather than a fraction', () => {
  assert.equal(fmtFrequency(null), '—');
  assert.equal(fmtFrequency(0), 'none');
  assert.equal(fmtFrequency(0.5), 'every 2.0d');
  assert.equal(fmtFrequency(2.4), '2.4/day');
  assert.equal(fmtFrequency(14), '14/day');
});

// --- rows --------------------------------------------------------------------

const payload = {
  window: { days: 14 },
  projects: [
    {
      project: 'project-3', repos: ['example-org/project-3'], merged: 8,
      lead_time: { p50_s: 7200, p90_s: 86400 * 3, n: 8, from_job_n: 6, from_pr_seen_n: 1, unattributed_n: 1, deploy_verified: false, evidence: 'jobs.created_at → ledgers' },
      deployment_frequency: { per_day: 0.571, count: 8, days: 14, deploy_verified: false, evidence: 'ledgers(kind=merge)' },
      change_failure: { rate: 0.25, bad: 2, merges: 8, main_red: 1, evidence: 'outcome_metrics ÷ ledgers' },
      time_to_restore: { p50_s: 86400, p90_s: 86400 * 2, n: 2, unrestored: 1, evidence: 'outcome_metrics → ledgers' },
      merge_lane: { p50_s: 1800, p90_s: 7200, n: 7, evidence: 'job_artifacts(verdict) → ledgers' },
      slowest: [
        { pr: 'https://github.com/example-org/project-3/pull/9', repo: 'example-org/project-3', number: 9, lead_s: 86400 * 3, approval_to_merge_s: 7200, job_id: 'build-project-3-9', ticket_id: 'TK-9', lead_basis: 'job_created', merged_at: '2026-09-11T08:00:00Z' },
        { pr: 'https://github.com/example-org/project-3/pull/4', repo: 'example-org/project-3', number: 4, lead_s: 3600, approval_to_merge_s: null, job_id: null, ticket_id: null, lead_basis: 'pr_first_seen', merged_at: '2026-09-10T08:00:00Z' }
      ]
    },
    {
      // The shape that breaks a naive screen: nothing measurable at all.
      project: 'project-4', repos: [], merged: 0,
      lead_time: { p50_s: null, p90_s: null, n: 0, from_job_n: 0, from_pr_seen_n: 0, unattributed_n: 0, deploy_verified: false },
      deployment_frequency: { per_day: 0, count: 0, days: 14, deploy_verified: false },
      change_failure: { rate: null, bad: 0, merges: 0, main_red: 0 },
      time_to_restore: { p50_s: null, p90_s: null, n: 0, unrestored: 3 },
      merge_lane: { p50_s: null, p90_s: null, n: 0 },
      slowest: []
    }
  ],
  totals: { merged: 8 },
  gaps: []
};

test('a payload with a null metric becomes a row with null, not zero', () => {
  const rows = projectRows(payload);
  assert.equal(rows.length, 2);
  const project_4 = rows.find((r) => r.project === 'project-4');
  // The whole reason this is a separate assertion: `Number(null)` is 0, and a
  // lead time of 0 on a project that merged nothing reads as the fastest lane
  // in the fleet.
  assert.equal(project_4.leadP50, null);
  assert.equal(project_4.cfr, null);
  assert.equal(project_4.laneP90, null);
  // Counts are counts: an unrestored failure on a project with no merges is a
  // real 3 and must survive.
  assert.equal(project_4.unrestored, 3);
});

test('projectRows carries the two lead-time bases separately, and basisNote names them', () => {
  const project_3 = projectRows(payload).find((r) => r.project === 'project-3');
  assert.equal(project_3.leadFromJob, 6);
  assert.equal(project_3.leadFromPrSeen, 1);
  assert.equal(project_3.leadUnattributed, 1);
  const note = basisNote(project_3);
  assert.match(note, /6 from the build job/);
  assert.match(note, /1 from when the conductor first saw the PR/);
  assert.match(note, /1 unattributable \(excluded\)/);
  assert.equal(basisNote({ leadN: 0 }), 'nothing measurable in this window');
});

test('the drill-down is the slowest changes across what is on screen, longest first', () => {
  const slow = slowRows(projectRows(payload), { limit: 10 });
  assert.equal(slow.length, 2);
  assert.equal(slow[0].number, 9);
  assert.equal(slow[0].leadS, 86400 * 3);
  assert.equal(slow[0].project, 'project-3');
  assert.equal(slow[1].laneS, null, 'a PR with no APPROVE artifact keeps null, not 0');
  const capped = slowRows(projectRows(payload), { limit: 1 });
  assert.equal(capped.length, 1);
});

// --- sorting -----------------------------------------------------------------

test('every column sorts on the raw number, so 2h never sorts above 1d', () => {
  const cols = projectColumns(() => '', 14);
  const rows = [
    { project: 'a', leadP90: 7200, leadN: 3, perDay: 0.5, cfr: 0.5, ttrP90: 10, unrestored: 0, laneP90: 5, merged: 1 },
    { project: 'b', leadP90: 86400, leadN: 9, perDay: 2, cfr: 0.1, ttrP90: 20, unrestored: 2, laneP90: 50, merged: 9 }
  ];
  const lead = cols.find((c) => c.key === 'leadP90');
  // b is twelve times slower than a. Formatted, a reads "2h" and b reads "1d",
  // and "2h" > "1d" alphabetically — so a table sorted on the rendered string
  // would put the FAST project at the top of a slowest-first view. That
  // inversion is what this pins against.
  assert.equal(fmtSeconds(rows[0].leadP90), '2h');
  assert.equal(fmtSeconds(rows[1].leadP90), '1d');
  assert.equal(fmtSeconds(rows[0].leadP90) > fmtSeconds(rows[1].leadP90), true);
  assert.equal(sortRows(rows, lead.sort, 'desc')[0].project, 'b');
  assert.equal(sortRows(rows, lead.sort, 'asc')[0].project, 'a');

  const cfr = cols.find((c) => c.key === 'cfr');
  assert.equal(sortRows(rows, cfr.sort, 'desc')[0].project, 'a');

  // Every column must actually declare a sort, or a header silently does
  // nothing when clicked.
  for (const c of cols) assert.equal(typeof c.sort, 'function', `${c.key} must be sortable`);
  for (const c of slowColumns()) assert.equal(typeof c.sort, 'function', `${c.key} must be sortable`);
});

test('a project that measured nothing sinks to the bottom in BOTH directions', () => {
  const cols = projectColumns(() => '', 14);
  const lead = cols.find((c) => c.key === 'leadP50').sort;
  const rows = projectRows(payload);
  assert.equal(sortRows(rows, lead, 'desc')[1].project, 'project-4');
  // Ascending too: an unmeasured project surfacing as "fastest" is exactly the
  // wrong lesson to draw from this panel.
  assert.equal(sortRows(rows, lead, 'asc')[1].project, 'project-4');
});

// --- rendering ---------------------------------------------------------------

const renderProjects = (rows, days = 14) =>
  render(h(DoraProjectTable, { rows, days, evidence: payload.projects[0], empty: h('div', null, 'EMPTY') }));

test('the per-project table renders one sortable header per column', () => {
  const out = renderProjects(projectRows(payload));
  assert.match(out, /<table/);
  assert.equal((out.match(/aria-sort=/g) || []).length, projectColumns(() => '', 14).length,
    'every header carries aria-sort, which is what a screen reader announces');
  assert.match(out, /LEAD p50/);
  assert.match(out, /APPROVE→MERGE p50/);
  assert.match(out, /CHANGE FAIL/);
  assert.match(out, /RESTORE p50/);
  // One row per project plus the header.
  assert.equal((out.match(/<tr/g) || []).length, 3);
});

test('an unmeasured cell renders — and a measured one renders its unit', () => {
  const out = renderProjects(projectRows(payload));
  assert.match(out, /3d/, 'the p90 lead time is rendered as a duration');
  assert.match(out, /25%/, 'the change-failure rate is rendered as a percentage');
  assert.match(out, /every 1\.8d/, "project-4 merged nothing, so its landings read 'none'");
  assert.match(out, /none/);
  assert.match(out, /—/, 'the project that measured nothing renders an em dash, not 0s');
  assert.doesNotMatch(out, /0s</, 'nothing unmeasured may render as zero seconds');
});

test('the project name is a link and an unattributed row says so instead of faking one', () => {
  const out = renderProjects(projectRows(payload));
  assert.match(out, /href="\/p\/project-3"/, 'every identity cell links — no dead rows');
  const orphan = renderProjects([{ ...projectRows(payload)[0], project: null }]);
  assert.match(orphan, /unattributed/);
  assert.doesNotMatch(orphan, /href="\/p\/null"/, 'a missing project must not become a link to nowhere');
});

test('a thin sample is marked rather than presented as a percentile', () => {
  const thin = projectRows(payload).map((r) => ({ ...r, leadN: 2 }));
  assert.equal(isThin(2), true);
  assert.equal(isThin(THIN_SAMPLE), false);
  assert.equal(isThin(0), false, 'zero is "not measured", a different statement from "thin"');
  const out = renderProjects(thin);
  assert.match(out, /only 2 samples/);
});

test('a high change-failure rate colours its row, a healthy one does not', () => {
  const hot = renderProjects([{ ...projectRows(payload)[0], cfr: 0.5 }]);
  assert.match(hot, /row--warn/);
  const cool = renderProjects([{ ...projectRows(payload)[0], cfr: 0.01 }]);
  assert.doesNotMatch(cool, /row--warn/);
});

test('every figure carries the table it came from, so nobody has to trust the label', () => {
  const out = renderProjects(projectRows(payload));
  assert.match(out, /jobs\.created_at/, 'the lead-time cell names its source');
  assert.match(out, /ledgers\(kind=merge\)/);
  assert.match(out, /job_artifacts\(verdict\)/);
});

test('the empty state explains itself instead of implying a fast fleet', () => {
  const out = renderProjects([]);
  assert.match(out, /EMPTY/);
  assert.doesNotMatch(out, /<table/);
});

test('the slowest table links every PR out and every job in', () => {
  const out = render(h(DoraSlowestTable, {
    rows: slowRows(projectRows(payload)), empty: h('div', null, 'EMPTY')
  }));
  assert.match(out, /href="https:\/\/github\.com\/example-org\/project-3\/pull\/9"/);
  assert.match(out, /rel="noopener noreferrer"/);
  assert.match(out, /href="\/jobs\/build-project-3-9"/);
  assert.match(out, /href="\/p\/project-3"/);
  // The PR with no job must not render a link to /jobs/null.
  assert.doesNotMatch(out, /href="\/jobs\/null"/);
});

// --- the deploy record -------------------------------------------------------
// The screen must never keep rendering merge-time language over figures the
// worker has started measuring to production, and must not claim production
// for a project that has no departures.

test('the frequency cell reads the worker basis rather than a sentence of its own', () => {
  const deployed = projectRows({
    projects: [{
      project: 'project-3', merged: 3,
      lead_time: { p50_s: 100, n: 3, from_job_n: 3, to_deploy_n: 2, to_merge_n: 1, deploy_verified: true },
      deployment_frequency: {
        per_day: 0.07, count: 1, merges: 3, failed_departures: 1, deploy_verified: true,
        basis: 'verified production departures per day'
      }
    }]
  })[0];
  assert.equal(deployed.freqDeployVerified, true);
  assert.equal(deployed.freqCount, 1);
  assert.equal(deployed.freqFailed, 1);
  const out = render(h(DoraProjectTable, { rows: [deployed], days: 14, empty: h('div', null, 'EMPTY') }));
  assert.match(out, /1 verified departure carrying 3 merges/);
  assert.match(out, /1 that never arrived/);
  assert.doesNotMatch(out, /NOT verified production departures/);
});

test('a project with no departures keeps the merge wording, and says which clock stopped its rows', () => {
  const merged = projectRows({
    projects: [{
      project: 'project-4', merged: 2,
      lead_time: { p50_s: 100, n: 2, from_job_n: 2, to_deploy_n: 0, to_merge_n: 2, deploy_verified: false },
      deployment_frequency: {
        per_day: 0.14, count: 2, merges: 2, failed_departures: 0, deploy_verified: false,
        basis: 'merges per day — NOT verified production departures'
      }
    }]
  })[0];
  assert.equal(merged.freqDeployVerified, false);
  assert.doesNotMatch(basisNote(merged), /production/);
  const out = render(h(DoraProjectTable, { rows: [merged], days: 14, empty: h('div', null, 'EMPTY') }));
  assert.match(out, /NOT verified production departures/);
});

test('basisNote names the end of the clock as well as its start, and the mix when there is one', () => {
  const mixed = { leadN: 3, leadFromJob: 3, leadToDeploy: 2, leadToMerge: 1 };
  assert.match(basisNote(mixed), /2 ending at a verified production deploy, 1 only at the merge/);
  const all = { leadN: 2, leadFromJob: 2, leadToDeploy: 2, leadToMerge: 0 };
  assert.match(basisNote(all), /all ending at a verified production deploy/);
});

test('the slowest row says which clock stopped it, per row', () => {
  const rows = slowRows([{
    project: 'project-3',
    slowest: [
      { pr: 'https://github.com/example-org/project-3/pull/1', repo: 'example-org/project-3', number: 1,
        lead_s: 300, lead_basis: 'job_created', lead_end: 'deploy_verified', deployed_at: '2026-09-12T10:00:00Z' },
      { pr: 'https://github.com/example-org/project-3/pull/2', repo: 'example-org/project-3', number: 2,
        lead_s: 200, lead_basis: 'job_created', lead_end: 'merged' }
    ]
  }]);
  assert.equal(rows[0].end, 'deploy_verified');
  assert.equal(rows[1].end, 'merged');
  const out = render(h(DoraSlowestTable, { rows, empty: h('div', null, 'EMPTY') }));
  assert.match(out, /production verified serving it at 2026-09-12T10:00:00Z/);
  assert.match(out, /no verified production departure recorded for it/);
});

test('a PR url that is not https never reaches an href', () => {
  const rows = [{
    project: 'project-3', pr: 'javascript:alert(1)', repo: 'example-org/project-3', number: 3,
    ticketId: null, jobId: null, leadS: 10, laneS: null, basis: 'job_created', mergedAt: null
  }];
  const out = render(h(DoraSlowestTable, { rows, empty: h('div', null, 'EMPTY') }));
  assert.doesNotMatch(out, /javascript:/);
  assert.match(out, /project-3 #3/, 'it still renders as inert text rather than disappearing');
});
