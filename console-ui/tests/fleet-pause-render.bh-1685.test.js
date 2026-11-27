import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { ProjectsTable, PauseBanner, flagsRank } from '../src/screens/Fleet.js';
import { shapePauses } from '../src/lib/pauses.js';
import { api } from '../src/api.js';

// BH-1685 (BH-1672.4). A pause is a worker row now, and the Fleet page has to
// SHOW it: a red PAUSED(<what>) tag on every project row it covers, and a
// sortable PAUSES banner above the table. Every case renders the REAL exported
// components from one shapePauses output, the way fleet-queue-tail does —
// preact-render-to-string runs no effects, so FleetScreen's own read cannot be
// stubbed here; its wiring is the api.pauses assertion at the bottom.

const now = Date.parse('2026-09-24T12:00:00Z');
const iso = (minFromNow) => new Date(now + minFromNow * 60000).toISOString();

const payload = {
  pauses: [
    { id: 11, scope: 'project-3', what: 'merges', reason: 'release freeze', actor: 'operator',
      created_at: iso(-90), expires_at: iso(30), ended_at: null },
    { id: 12, scope: 'fleet', what: 'builds', reason: null, actor: 'console',
      created_at: iso(-5), expires_at: iso(120), ended_at: null },
    // Listed by the worker, but already past its expiry: must render nowhere.
    { id: 13, scope: 'project-5', what: 'reviews', reason: 'stale', actor: 'console',
      created_at: iso(-200), expires_at: iso(-1), ended_at: null }
  ],
  truncated: false
};
const pauses = shapePauses(payload, now).rows;

const project = (name) => ({
  project: name, last_run_age_min: 3, last_summary: 'ok', last_rc: 0, paused: false, automerge: true, fleet: {}
});
const rows = [project('project-3'), project('project-5')];

// The <tr> for one project, so an assertion about "this row" cannot pass on
// a tag that rendered in the other one.
const rowHtml = (html, name) => {
  const trs = html.match(/<tr[^>]*>[\s\S]*?<\/tr>/g) || [];
  return trs.find((t) => t.includes(`>${name}<`)) || '';
};

test('the project pause renders as a red PAUSED(merges) on its own row only', () => {
  const out = render(h(ProjectsTable, { rows, recentRuns: {}, pauses }));
  const project_3 = rowHtml(out, 'project-3');
  const ts = rowHtml(out, 'project-5');
  assert.match(project_3, /<span class="tag tag--bad"[^>]*>PAUSED\(merges\)<\/span>/);
  assert.doesNotMatch(ts, /PAUSED\(merges\)/);
});

test('the tag title carries the reason and the age', () => {
  const out = render(h(ProjectsTable, { rows, recentRuns: {}, pauses }));
  const tag = rowHtml(out, 'project-3').match(/<span class="tag tag--bad" title="([^"]*)"[^>]*>PAUSED\(merges\)/);
  assert.ok(tag, 'the merges tag has a title');
  assert.match(tag[1], /release freeze/);
  // 90 minutes through the console's one age formatter (format.js agoFromMinutes).
  assert.match(tag[1], /1h ago/);
});

test('a fleet pause tags EVERY project row', () => {
  const out = render(h(ProjectsTable, { rows, recentRuns: {}, pauses }));
  for (const name of ['project-3', 'project-5']) {
    assert.match(rowHtml(out, name), /tag--bad[^>]*>PAUSED\(builds\)/, name);
    assert.doesNotMatch(rowHtml(out, name), /PAUSED\(reviews\)/, 'expired row renders nowhere');
  }
});

test('a paused row has no "—" placeholder, an untouched row still does', () => {
  const out = render(h(ProjectsTable, { rows, recentRuns: {}, pauses: [] }));
  assert.match(rowHtml(out, 'project-3'), /class="na">—/);
  const paused = render(h(ProjectsTable, { rows: [project('project-3')], recentRuns: {}, pauses }));
  // The only "—" cells left would be FLAGS; RC is 0 and QUEUE/OLDEST are on a
  // separate span class, so count the FLAGS wrapper's children instead.
  const flags = paused.match(/<span style="display:inline-flex;gap:5px;flex-wrap:wrap">([\s\S]*?)<\/span>\s*<\/td>/);
  assert.ok(flags, 'flags cell rendered');
  assert.doesNotMatch(flags[1], /—/);
});

test('ProjectsTable without a pauses prop renders exactly as before', () => {
  const out = render(h(ProjectsTable, { rows, recentRuns: {} }));
  assert.doesNotMatch(out, /tag--bad/);
  assert.doesNotMatch(out, /PAUSED\(/);
});

test('the FLAGS sort ranks an active pause above a flag-file pause above nothing', () => {
  const project_3Rank = flagsRank(project('project-3'), pauses);
  const bare = { ...project('x'), automerge: true };
  // `x` still gets the fleet pause, so rank it against an empty list.
  assert.ok(project_3Rank > flagsRank({ ...project('project-3'), paused: true }, []));
  assert.ok(flagsRank({ ...project('project-3'), paused: true }, []) > flagsRank(bare, []));
  assert.equal(flagsRank(bare, []), 0);
});

test('the banner renders one body row per live pause, over the shared SortableTable', () => {
  const out = render(h(PauseBanner, { rows: pauses, onEnd: () => {} }));
  const body = out.split('<tbody')[1] || '';
  assert.equal((body.match(/<tr/g) || []).length, 2);
  assert.match(out, /class="tablewrap/, 'the banner scrolls inside its own container');
  assert.match(out, /PAUSES/);
});

test('the six data columns are sortable with aria-sort, END is not', () => {
  const out = render(h(PauseBanner, { rows: pauses, onEnd: () => {} }));
  const ths = out.match(/<th[^>]*>[\s\S]*?<\/th>/g) || [];
  assert.equal(ths.length, 7);
  for (const label of ['SCOPE', 'WHAT', 'REASON', 'ACTOR', 'AGE', 'EXPIRES']) {
    const th = ths.find((t) => t.includes(label));
    assert.ok(th, `${label} header`);
    assert.match(th, /aria-sort="(none|ascending|descending)"/, label);
  }
  assert.doesNotMatch(ths[6], /aria-sort/);
});

test('a project scope links to its page, fleet scope is plain text', () => {
  const out = render(h(PauseBanner, { rows: pauses, onEnd: () => {} }));
  assert.match(out, /href="\/p\/project-3"/);
  assert.match(out, /FLEET \(all projects\)/);
  assert.doesNotMatch(out, /<a[^>]*>FLEET \(all projects\)/);
  assert.match(out, /no reason given/);
  assert.match(out, /END/);
});

test('a failed pause read renders no banner at all', () => {
  assert.equal(render(h(PauseBanner, { rows: shapePauses(null, now).rows, onEnd: () => {} })), '');
});

test('truncated says the list is partial', () => {
  const out = render(h(PauseBanner, { rows: pauses, truncated: true, onEnd: () => {} }));
  assert.match(out, /first 500 shown/);
});

test('the console has a pauses read', () => {
  assert.equal(typeof api.pauses, 'function');
});
