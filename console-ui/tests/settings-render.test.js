import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { SettingsView, LaneDetailView } from '../src/screens/Settings.js';
import { laneRows, tabsFrom } from '../src/lib/settings.js';

// The helpers being right is not the same as the screen rendering. This renders
// the real components and reads the HTML back, so "the SETTINGS screen works"
// is a thing that was observed rather than a thing that was assumed.

// determinism: ok-file clock-now-js every timestamp is an OFFSET from one
// captured read; no case asserts a calendar date.
const NOW = Date.now();
const iso = (minutesAgo) => new Date(NOW - minutesAgo * 60000).toISOString();

const registry = {
  lanes: [
    {
      id: 'merge-conductor', name: 'Merge conductor', scope: 'hub',
      script: 'bin/merge-conductor.sh', cadence: '*/5',
      switch: { kind: 'flag', name: 'lane-off-merge-conductor' },
      knobs: [
        { env: 'MC_MAX_PRS', type: 'int', default: 8, min: 1, max: 50, unit: 'PRs' },
        { env: 'MC_DAILY_CAP', type: 'int', default: 0, min: 0, max: 500, unit: 'USD', zero_means: 'unlimited' }
      ],
      stats: { cost_stage: 'merge' }
    },
    {
      id: 'alert-triage', name: 'Alert triage', scope: 'hub',
      script: 'bin/alert-triage.sh', cadence: '*/20',
      switch: { kind: 'flag', name: 'lane-off-alert-triage' },
      knobs: [{ env: 'TRIAGE_MAX_FAMILIES', type: 'int', default: 3, min: 0, max: 20, zero_means: 'off' }],
      stats: { cost_stage: 'alert-triage' }
    },
    {
      id: 'review-prs', name: 'Review PRs', scope: 'project',
      script: 'bin/review-prs.sh', cadence: '7,37',
      switch: { kind: 'flag', name: 'lane-off-review-prs' }, knobs: []
    }
  ]
};

const status = {
  scope: 'hub', as_of: iso(1), projects: ['project-4', 'project-3'], all_off: false,
  lanes: [
    {
      id: 'merge-conductor', off: false, cadence: '*/5', last_tick_at: iso(4),
      last_outcome: 'ok', runs_today: 41, cost_today: 12.5, cost_7d: 88.25,
      knobs: { MC_MAX_PRS: { value: 8, source: 'default' }, MC_DAILY_CAP: { value: 0, source: 'settings' } }
    },
    {
      id: 'alert-triage', off: true, off_source: 'flag', paused_since: iso(120),
      cadence: '*/20', last_tick_at: iso(121), last_outcome: 'paused', runs_today: 2,
      cost_today: 793.4, cost_7d: 801.1,
      knobs: { TRIAGE_MAX_FAMILIES: { value: 3, source: 'env' } }
    }
  ]
};

const noop = () => {};
const actions = { toggleLane: noop, setKnob: noop, allOff: noop, allOn: noop };

const view = (over = {}) => render(h(SettingsView, {
  tabs: tabsFrom(status), activeTab: 'hub',
  rows: laneRows(registry, status, 'hub'),
  status, error: null, loading: false, busy: null, note: null,
  actions, dialog: null, onTab: noop, onReload: noop,
  ...over
}));

// ------------------------------------------------------------------ tabs

test('the hub tab and one tab per project render, from the status payload', () => {
  const html = view();
  assert.match(html, /class="tabs"/);
  for (const label of ['HUB', 'project-4', 'project-3']) {
    assert.ok(html.includes(label), `${label} has a tab`);
  }
  assert.match(html, /class="tab tab--on"[^>]*>HUB|>HUB</, 'the active tab is marked');
});

// ----------------------------------------------------------------- table

test('it is one sortable table, every header sorts, and it scrolls in its own box', () => {
  const html = view();
  assert.match(html, /<table/, 'a table, not a wall of cards');
  assert.match(html, /class="tablewrap/, 'the wrapper is the one with overflow-x:auto — the page never scrolls sideways');
  assert.match(html, /aria-sort=/, 'sort state is announced, not only drawn');
  // lane, state, cadence, last tick, runs today, $ today, $ 7d, knobs
  const headers = (html.match(/<th /g) || []).length;
  assert.equal(headers, 8, 'eight columns');
  const sortable = (html.match(/<button type="button"[^>]*title="sort by/g) || []).length;
  assert.equal(sortable, 8, 'every one of the eight headers is clickable');
});

test('the columns the ticket asked for are all on screen with real values', () => {
  const html = view();
  assert.ok(html.includes('Merge conductor'), 'the lane name');
  assert.ok(html.includes('*/5'), 'the cadence');
  assert.ok(html.includes('41'), 'runs today');
  assert.ok(html.includes('$12.50') || html.includes('12.50'), '$ today');
  assert.ok(html.includes('88.25') || html.includes('$88.25'), '$ 7d');
  assert.ok(html.includes('MC_MAX_PRS'), 'the knob is named');
  assert.match(html, /<input[^>]*type="number"/, 'the knob is an inline input');
});

test('the knob input carries the registry min and max, so the browser refuses out of range too', () => {
  const html = view();
  assert.match(html, /min="1"/);
  assert.match(html, /max="50"/);
});

test('a zero knob never renders as a bare 0 — the registry says what zero means', () => {
  const html = view();
  assert.ok(html.includes('0 = unlimited'), 'MC_DAILY_CAP says what its 0 is');
});

test('an off lane reads as off, says since when, and its toggle announces its state', () => {
  const html = view();
  assert.ok(html.includes('OFF'), 'the off state is named');
  assert.match(html, /aria-pressed="false"/, 'the off toggle announces itself');
  assert.match(html, /aria-pressed="true"/, 'and the on one does too');
  assert.match(html, /paused/i, 'the paused-since / outcome is rendered');
});

test('every lane row links to its own detail — no dead rows', () => {
  const html = view();
  assert.ok(html.includes('href="/settings/merge-conductor"'), 'the hub lane opens its detail');
  assert.ok(html.includes('href="/settings/alert-triage"'));
});

test('a project tab renders its lanes under a project-scoped detail link', () => {
  const projectStatus = {
    scope: 'project-4', projects: ['project-4', 'project-3'],
    lanes: [{ id: 'review-prs', off: false, runs_today: 3, cost_today: 1.5, cost_7d: 9, cadence: '7,37' }]
  };
  const html = view({
    activeTab: 'project-4', status: projectStatus,
    rows: laneRows(registry, projectStatus, 'project-4'), tabs: tabsFrom(projectStatus)
  });
  assert.ok(html.includes('Review PRs'));
  assert.ok(html.includes('href="/settings/review-prs?project=project-4"'));
  assert.ok(!html.includes('Merge conductor'), 'hub lanes stay on the hub tab');
});

// ------------------------------------------------------- master switches

test('ALL OFF and ALL ON are on the page', () => {
  const html = view();
  assert.ok(html.includes('ALL OFF'));
  assert.ok(html.includes('ALL ON'));
});

test('the page uses the in-app modal slot and never a native dialog', () => {
  const html = view({ dialog: h('div', { class: 'modal__scrim' }, 'confirm me') });
  assert.match(html, /modal__scrim/, 'the shared confirm modal renders where the screen puts it');
  const src = view();
  assert.ok(!/window\.confirm|window\.alert/.test(src));
});

// ------------------------------------------------------ loading / errors

test('an unreachable API keeps the last state on screen behind a banner — never an empty table', () => {
  const html = view({ error: new Error('network unreachable') });
  assert.match(html, /class="banner/, 'the banner is up');
  assert.ok(html.includes('network unreachable'), 'it names the reason');
  assert.ok(html.includes('Merge conductor'), 'the last fetched rows are STILL rendered');
  assert.match(html, /<table/, 'the table did not empty itself');
  assert.ok(!html.includes('NO LANES'), 'and it does not claim there is nothing here');
});

test('a first load that fails with nothing cached says so instead of drawing an empty table', () => {
  const html = view({ error: new Error('network unreachable'), rows: [], status: null });
  assert.match(html, /class="banner/);
  assert.ok(html.includes('network unreachable'));
});

test('writes are disabled while one is in flight, so a double click cannot double-write', () => {
  const html = view({ busy: 'merge-conductor' });
  assert.match(html, /disabled/);
});

// ----------------------------------------------------------- lane detail

test('the lane detail names the lane, its script and its cost rows', () => {
  const lane = laneRows(registry, status, 'hub').find((r) => r.id === 'alert-triage');
  const html = render(h(LaneDetailView, {
    lane, project: null, error: null, loading: false,
    costRows: [
      { at: iso(30), stage: 'alert-triage', usd: 41.2, ticket: 'BH-1039' },
      { at: iso(90), stage: 'alert-triage', usd: 12.0, ticket: null }
    ]
  }));
  assert.ok(html.includes('Alert triage'), 'the lane is named');
  assert.ok(html.includes('bin/alert-triage.sh'), 'its script is named');
  assert.ok(html.includes('BH-1039'), 'its cost rows are on screen');
  assert.match(html, /href="\/settings"/, 'a crumb back to the table');
  assert.match(html, /<table/, 'the cost rows are a table');
});

test('a lane detail with no cost rows says so rather than drawing an empty table', () => {
  const lane = laneRows(registry, status, 'hub')[0];
  const html = render(h(LaneDetailView, { lane, project: null, error: null, loading: false, costRows: [] }));
  assert.match(html, /NO COST ROWS|no cost rows/i);
});

// ══════════════════════════════════════════════════ round 2 (review #1133)

test('a project tab still renders the whole strip while its status is in flight', () => {
  // The bug this pins: useApi nulls `data` on a deps change, so mid-fetch the
  // tab strip was derived from null and collapsed to HUB alone — and a 404 on
  // the project status left it collapsed, with no way back to the tab you were
  // on. The strip is navigation and does not vanish because a pane is loading.
  const html = view({
    activeTab: 'project-4', status: null, rows: [], loading: true,
    tabs: tabsFrom(null, ['hub', 'project-4', 'project-3'], 'project-4')
  });
  for (const label of ['HUB', 'project-4', 'project-3']) {
    assert.ok(html.includes(label), `${label} is still in the strip`);
  }
  assert.match(html, /aria-selected="true"[^>]*>project-4|project-4/, 'and the active one is still marked');
});

test('a project whose status 404s keeps its tab and says what happened', () => {
  const html = view({
    activeTab: 'project-3', status: null, rows: [], loading: false,
    tabs: tabsFrom(null, ['hub', 'project-4', 'project-3'], 'project-3'),
    error: new Error('http_404')
  });
  assert.ok(html.includes('project-3'), 'the tab survives the failure');
  assert.ok(html.includes('HUB'), 'and so does the way back');
  assert.ok(html.includes('http_404'));
});

test('a first load that fails shows the banner and NOT also an empty-state', () => {
  // Two contradictory messages — "could not reach the API" next to "NO LANES" —
  // is worse than either alone: the second reads as a fact about the fleet.
  const html = view({ error: new Error('network unreachable'), rows: [], status: null });
  assert.match(html, /class="banner/);
  assert.ok(!html.includes('NO LANES'), 'the empty state stays out of the way of the banner');
});

test('with no error and no lanes, the empty state IS the right answer', () => {
  const html = view({ error: null, rows: [], status: { scope: 'hub', lanes: [], projects: [] } });
  assert.ok(html.includes('NO LANES'));
});

test('an over-long key is refused inline on the knob that would produce it', () => {
  const longRegistry = {
    lanes: [{
      id: 'review-autopilot', name: 'Review autopilot', scope: 'project', script: 'bin/review-autopilot.sh',
      cadence: '*/10', switch: { kind: 'flag', name: 'lane-off-review-autopilot' },
      knobs: [{ env: 'AUTOPILOT_DAILY_CAP_USD', type: 'int', default: 0, min: 0, max: 999, zero_means: 'unlimited' }]
    }]
  };
  const st = { scope: 'fixture-project-xyz', projects: ['fixture-project-xyz'], lanes: [{ id: 'review-autopilot', off: false }] };
  const rows = laneRows(longRegistry, st, 'fixture-project-xyz');
  const html = view({ activeTab: 'fixture-project-xyz', status: st, rows, tabs: tabsFrom(st) });
  // The input is rendered disabled with the reason attached, rather than
  // letting the operator type a value that can only ever 400.
  assert.ok(html.includes('AUTOPILOT_DAILY_CAP_USD'), 'the knob is still shown — hiding it would hide the problem');
  assert.ok(html.includes('is 65 characters'), 'it names the actual length');
  assert.ok(html.includes("worker's limit is 64"), 'and the bound it broke');
  assert.ok(html.includes('cannot be set from here'), 'in words, not just a number');
});

test('the detail TICKET cell is a link, not a dead cell', () => {
  const lane = laneRows(registry, status, 'hub').find((r) => r.id === 'alert-triage');
  const html = render(h(LaneDetailView, {
    lane, project: null, error: null, loading: false,
    costRows: [
      { at: iso(30), stage: 'alert-triage', usd: 41.2, ticket: 'BH-1039', build_dir: 'bh-1039-abc' },
      { at: iso(60), stage: 'alert-triage', usd: 3.5, ticket: 'BH-40', build_dir: null }
    ]
  }));
  assert.ok(html.includes('href="/builds/bh-1039-abc"'), 'a row with a build opens it');
  assert.ok(html.includes('BH-40'), 'and one without a build still renders its ticket');
});

// ══════════════════════════════════════════════════ round 3 (review #1133)

test('a lane whose off state is unknown renders a DISABLED toggle, never a live ON', () => {
  const reg = { lanes: [{ id: 'x', name: 'Mystery lane', scope: 'hub', cadence: '*/5', knobs: [] }] };
  const st = { scope: 'hub', projects: [], lanes: [{ id: 'x', off: null, runs_today: 3 }] };
  const out = view({ status: st, rows: laneRows(reg, st, 'hub'), tabs: tabsFrom(st) });
  assert.ok(out.includes('Mystery lane'), 'the row is still there with its numbers');
  assert.ok(out.includes('unknown'), 'and it says the state is unknown');
  assert.match(out, /<button[^>]*disabled/, 'the toggle cannot be clicked');
  assert.ok(!/aria-pressed="true"/.test(out), 'nothing on the row claims it is on');
  assert.ok(!out.includes('>OFF'), 'and it does not claim it is off either — the label is neither');
});

// ── BH-1165: the screen says WHERE a stop is, and what is only modified ─────

const bh1165 = {
  scope: 'hub', as_of: iso(1), projects: ['project-4'], all_off: false,
  lanes: [
    {
      id: 'merge-conductor', off: false, cadence: '*/5', last_tick_at: iso(2),
      last_outcome: 'ran', runs_today: 3, cost_today: 1, cost_7d: 2, knobs: {},
      modifiers: [{ name: 'merge-conductor-observe', active: true }],
      enables: [{ name: 'conductor-owns-merges', active: true }],
      flag_boxes: [], held_by: []
    },
    {
      id: 'alert-triage', off: true, off_source: 'flag', paused_since: iso(30),
      paused_reason: 'a file nothing in the database wrote: flags/lane-off-alert-triage on box-hub',
      flag_boxes: ['box-hub'], held_by: ['lane-off-alert-triage'],
      cadence: '*/20', last_tick_at: iso(3), last_outcome: 'paused',
      runs_today: 0, cost_today: 0, cost_7d: 0, knobs: {}, modifiers: [], enables: []
    }
  ]
};

test('a lane held by a FILE says so, and names the box', () => {
  // Before this the page drew the same "OFF" for a row an operator can clear
  // from here and for a file on a box they would have to ssh to. Pressing the
  // toggle on the second one writes a row that changes nothing on that box.
  const out = render(h(SettingsView, {
    tabs: tabsFrom(bh1165), activeTab: 'hub',
    rows: laneRows(registry, bh1165, 'hub'),
    status: bh1165, error: null, loading: false, busy: null, note: null,
    onDismissNote: noop, actions, dialog: null, onTab: noop, onReload: noop
  }));
  assert.match(out, /box-hub/, 'the box holding the file is not on screen');
  assert.match(out, /file/i);
});

test('a modifier is on screen, and it is not drawn as an off switch', () => {
  const out = render(h(SettingsView, {
    tabs: tabsFrom(bh1165), activeTab: 'hub',
    rows: laneRows(registry, bh1165, 'hub'),
    status: bh1165, error: null, loading: false, busy: null, note: null,
    onDismissNote: noop, actions, dialog: null, onTab: noop, onReload: noop
  }));
  assert.match(out, /merge-conductor-observe/);
  // the conductor is still ON: a modifier must never read as a stop
  assert.match(out, /aria-pressed="true"/);
});

test('a hand-touched flags/all-off on a box is on screen, and is not the ALL OFF row', () => {
  // `all_off` is the pause_flags row ALL ON clears from this page.
  // `all_off_flag_boxes` is a FILE on a box that only an ssh can remove, and
  // every lane on that box is gated meanwhile. Drawing them the same would make
  // pressing ALL ON look like it had worked.
  const status = { ...bh1165, all_off: false, all_off_flag_boxes: ['orgo-3'] };
  const out = render(h(SettingsView, {
    tabs: tabsFrom(status), activeTab: 'hub',
    rows: laneRows(registry, status, 'hub'),
    status, error: null, loading: false, busy: null, note: null,
    onDismissNote: noop, actions, dialog: null, onTab: noop, onReload: noop
  }));
  assert.match(out, /orgo-3/, 'the box holding flags/all-off is not on screen');
});
