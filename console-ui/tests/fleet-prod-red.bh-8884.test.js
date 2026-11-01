import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { ProjectsTable } from '../src/screens/Fleet.js';
import { prodMarker, sinceLabel } from '../src/lib/prod-red.js';

// BH-8884. The hub pushes `prod` in each project row when the merge conductor
// holds the project for a red production deploy (or `unknown` when the deploy
// snapshot is stale). The QUEUE cell must SAY it beside the depth. Every
// rendering case renders the REAL ProjectsTable that `/` renders.
// No clock is read: every value arrives as data.

const row = (fleet) => ({
  project: 'project-3', last_run_age_min: 3, last_summary: 'ok', last_rc: 0,
  paused: false, automerge: true, fleet
});
const html = (fleet) => render(h(ProjectsTable, { rows: [row(fleet)], recentRuns: {} }));
const text = (fleet) => html(fleet).replace(/<[^>]*>/g, '');

// The exact object tests/fleet-status-push-prod-red.bh-8884-test.sh P1 asserts
// the hub writes (same keys, same values).
const P1 = { state: 'red', since: '2026-10-27T19:10:00Z', sha: 'abc12345', id: 'dpl_fixture1' };

test('R1: a red prod renders the red tag beside the depth', () => {
  const out = html({ queue_depth: 2, prod: P1 });
  assert.match(out, /prod: red since Oct 27 19:10Z/);
  assert.match(out, /tag--bad/);
  assert.match(out, /data-testid="prod-red"/);
  assert.match(out, /title="[^"]*abc12345[^"]*"/, 'the title names the commit');
  assert.match(out, /title="[^"]*dpl_fixture1[^"]*"/, 'the title names the Vercel id');
  assert.match(text({ queue_depth: 2, prod: P1 }), /2/, 'the depth still renders');
});

test('R2: no prod field renders no tag', () => {
  assert.doesNotMatch(html({ queue_depth: 2 }), /prod-red/);
  assert.doesNotMatch(text({ queue_depth: 2 }), /prod:/);
});

test('R3: an unknown prod renders a faint tag, not a red one', () => {
  const out = html({ queue_depth: 0, prod: { state: 'unknown', generated_at: 'none' } });
  assert.match(out, /prod: unknown/);
  assert.doesNotMatch(out, /tag--bad/);
  assert.match(out, /tag--idle/);
});

test('R4: any other state or shape renders nothing', () => {
  assert.doesNotMatch(html({ queue_depth: 1, prod: { state: 'green' } }), /prod-red/);
  assert.doesNotMatch(html({ queue_depth: 1, prod: 'red' }), /prod-red/);
  assert.equal(prodMarker(null), null);
  assert.equal(prodMarker('red'), null);
  assert.equal(prodMarker({ state: 'green' }), null);
});

test('R5: sinceLabel is an absolute UTC stamp, and says when it cannot read one', () => {
  assert.equal(sinceLabel('nope'), 'an unreadable time');
  assert.equal(sinceLabel('2026-01-05T03:04:00Z'), 'Jan 5 03:04Z');
});

test('R6: the hub object round-trips to the tag text', () => {
  const m = prodMarker(P1);
  assert.equal(m.text, 'prod: red since Oct 27 19:10Z');
  assert.equal(m.tone, 'bad');
  assert.match(text({ queue_depth: 0, prod: P1 }), /prod: red since Oct 27 19:10Z/);
});
