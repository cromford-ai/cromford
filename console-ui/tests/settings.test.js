import test from 'node:test';
import assert from 'node:assert/strict';
import {
  tabsFrom, laneRows, flagName, settingKey, validateKnob, zeroLabel,
  flagBody, settingBody, makeLaneActions
} from '../src/lib/settings.js';

// determinism: ok-file clock-now-js every age in these fixtures is derived as an
// OFFSET from one captured read, and no case asserts a calendar date.
const NOW = Date.now();
const iso = (minutesAgo) => new Date(NOW - minutesAgo * 60000).toISOString();

// The registry is `catalog/lanes.json` as the worker bakes it (issue #1132 §1).
const registry = {
  lanes: [
    {
      id: 'merge-conductor', name: 'Merge conductor', scope: 'hub',
      script: 'bin/merge-conductor.sh', cadence: '*/5', boxes: ['hub'],
      switch: { kind: 'flag', name: 'lane-off-merge-conductor' },
      knobs: [
        { env: 'MC_MAX_PRS', type: 'int', default: 8, min: 1, max: 50, unit: 'PRs', zero_means: null },
        { env: 'MC_DAILY_CAP', type: 'int', default: 0, min: 0, max: 500, unit: 'USD', zero_means: 'unlimited' }
      ],
      stats: { cost_stage: 'merge', lanes_row: 'merge-conductor', log: 'logs/merge.log' }
    },
    {
      id: 'alert-triage', name: 'Alert triage', scope: 'hub',
      script: 'bin/alert-triage.sh', cadence: '*/20', boxes: ['hub'],
      switch: { kind: 'flag', name: 'lane-off-alert-triage' },
      knobs: [{ env: 'TRIAGE_MAX_FAMILIES', type: 'int', default: 3, min: 0, max: 20, zero_means: 'off' }],
      stats: { cost_stage: 'alert-triage' }
    },
    {
      id: 'review-prs', name: 'Review PRs', scope: 'project',
      script: 'bin/review-prs.sh', cadence: '7,37', boxes: ['per-project'],
      switch: { kind: 'flag', name: 'lane-off-review-prs' },
      knobs: [{ env: 'RP_MAX_HEADS', type: 'int', default: 20, min: 1, max: 100 }],
      stats: { cost_stage: 'review' }
    }
  ]
};

const hubStatus = {
  scope: 'hub',
  as_of: iso(1),
  projects: ['project-4', 'project-3'],
  all_off: false,
  lanes: [
    {
      id: 'merge-conductor', off: false, cadence: '*/5',
      last_tick_at: iso(4), last_outcome: 'ok', runs_today: 41,
      cost_today: 12.5, cost_7d: 88.25,
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

// ------------------------------------------------------------------- tabs

test('the tab list is the hub plus every project the STATUS payload named', () => {
  // Never a constant in the file: a hardcoded fleet is one more place to forget
  // a project (tests/fleet-projects-not-hardcoded-test.sh, same lesson).
  assert.deepEqual(tabsFrom(hubStatus).map((t) => t.id), ['hub', 'project-4', 'project-3']);
  assert.equal(tabsFrom(hubStatus)[0].label, 'HUB');
});

test('a status payload with no project list still gives the hub tab, never zero tabs', () => {
  assert.deepEqual(tabsFrom({ lanes: [] }).map((t) => t.id), ['hub']);
  assert.deepEqual(tabsFrom(null).map((t) => t.id), ['hub']);
});

// ------------------------------------------------------------------- rows

test('rows merge the registry with live status, scoped to the tab', () => {
  const rows = laneRows(registry, hubStatus, 'hub');
  assert.equal(rows.length, 2, 'the project-scoped lane is not on the hub tab');
  const mc = rows.find((r) => r.id === 'merge-conductor');
  assert.equal(mc.name, 'Merge conductor');
  assert.equal(mc.cadence, '*/5');
  assert.equal(mc.off, false);
  assert.equal(mc.cost_today, 12.5);
  assert.equal(mc.cost_7d, 88.25);
  assert.equal(mc.runs_today, 41);
  assert.equal(mc.knobs.length, 2);
  assert.equal(mc.knobs[0].value, 8, 'the live value wins over the registry default');
  assert.equal(mc.knobs[1].value, 0);
});

test('a project tab shows only project-scoped lanes and carries the project on every row', () => {
  const projectStatus = {
    scope: 'project-4', projects: ['project-4', 'project-3'],
    lanes: [{ id: 'review-prs', off: false, runs_today: 3, cost_today: 1.5, cost_7d: 9 }]
  };
  const rows = laneRows(registry, projectStatus, 'project-4');
  assert.equal(rows.length, 1);
  assert.equal(rows[0].id, 'review-prs');
  assert.equal(rows[0].project, 'project-4');
  assert.equal(rows[0].href, '/settings/review-prs?project=project-4', 'no dead rows');
});

test('a registered lane the status payload never mentioned still gets a row, marked unknown', () => {
  // The alternative is a lane that silently vanishes from the page — the exact
  // shape of "we have this data but the UI stops here".
  const rows = laneRows(registry, { scope: 'hub', lanes: [] }, 'hub');
  assert.equal(rows.length, 2);
  assert.equal(rows[0].unknown, true);
  assert.equal(rows[0].runs_today, null, 'unknown is not zero');
  assert.equal(rows[0].cost_today, null);
});

test('a lane the STATUS knows and the baked registry does not is still shown', () => {
  const status = { scope: 'hub', lanes: [{ id: 'brand-new-lane', off: false, runs_today: 1 }] };
  const rows = laneRows({ lanes: [] }, status, 'hub');
  assert.equal(rows.length, 1);
  assert.equal(rows[0].id, 'brand-new-lane');
  assert.equal(rows[0].unregistered, true);
});

// ------------------------------------------------------- names and keys

test('the flag name is per-lane on the hub and per-lane-per-project elsewhere', () => {
  assert.equal(flagName('merge-conductor', null), 'lane-off-merge-conductor');
  assert.equal(flagName('merge-conductor', 'hub'), 'lane-off-merge-conductor');
  assert.equal(flagName('review-prs', 'project-4'), 'lane-off-review-prs-project-4');
});

test('the setting key is LOWERCASE — the worker refuses anything else', () => {
  // worker/jobs/src/index.js: SETTING_KEY_RE = /^[a-z0-9_.-]{1,64}$/, checked on
  // PUT /api/settings. A key carrying the ENV name verbatim (MC_MAX_PRS) is a
  // 400 on every write, so the env name is lowercased here, once.
  assert.equal(settingKey('merge-conductor', 'MC_MAX_PRS', null), 'lane.merge-conductor.mc_max_prs');
  assert.equal(settingKey('review-prs', 'RP_MAX_HEADS', 'project-4'), 'lane.review-prs.project-4.rp_max_heads');
  assert.match(settingKey('merge-conductor', 'MC_MAX_PRS', null), /^[a-z0-9_.-]{1,64}$/);
  assert.match(settingKey('review-prs', 'RP_MAX_HEADS', 'project-4'), /^[a-z0-9_.-]{1,64}$/);
});

// ----------------------------------------------------------- knob labels

test('zero never renders as a bare 0 when the registry says what it means', () => {
  assert.equal(zeroLabel({ zero_means: 'unlimited' }), '0 = unlimited');
  assert.equal(zeroLabel({ zero_means: 'off' }), '0 = off');
  assert.equal(zeroLabel({ zero_means: null }), null);
  assert.equal(zeroLabel({}), null);
});

// ------------------------------------------------------- knob validation

test('a knob outside its registry range is refused CLIENT-side, with the bound named', () => {
  const knob = { env: 'MC_MAX_PRS', type: 'int', min: 1, max: 50 };
  const high = validateKnob(knob, '99');
  assert.equal(high.ok, false);
  assert.match(high.message, /MC_MAX_PRS/);
  assert.match(high.message, /1/);
  assert.match(high.message, /50/);
  const low = validateKnob(knob, '0');
  assert.equal(low.ok, false, '0 is below the minimum for a knob whose min is 1');
});

test('a value that is not a number at all is refused before it is sent', () => {
  const knob = { env: 'MC_MAX_PRS', type: 'int', min: 1, max: 50 };
  assert.equal(validateKnob(knob, '').ok, false);
  assert.equal(validateKnob(knob, 'eight').ok, false);
  assert.equal(validateKnob(knob, '4.5').ok, false, 'an int knob takes integers');
  assert.equal(validateKnob({ env: 'X', type: 'float', min: 0, max: 1 }, '0.5').ok, true);
});

test('a value inside the range passes and comes back as a number', () => {
  const knob = { env: 'MC_MAX_PRS', type: 'int', min: 1, max: 50 };
  const r = validateKnob(knob, ' 12 ');
  assert.equal(r.ok, true);
  assert.equal(r.value, 12);
  assert.equal(typeof r.value, 'number');
});

test('a knob with no declared bounds still refuses a non-number, and accepts any number', () => {
  const knob = { env: 'FREE', type: 'int' };
  assert.equal(validateKnob(knob, 'x').ok, false);
  assert.equal(validateKnob(knob, '9999').ok, true);
});

// ----------------------------------------------------------- write bodies

test('the flag write body is exactly what PUT /api/flags takes', () => {
  assert.deepEqual(flagBody('alert-triage', null, true, 'turned off from Mission Control'), {
    name: 'lane-off-alert-triage', active: 1, actor: 'console', reason: 'turned off from Mission Control'
  });
  assert.deepEqual(flagBody('review-prs', 'project-4', false, 'turned on from Mission Control'), {
    name: 'lane-off-review-prs-project-4', active: 0, actor: 'console', reason: 'turned on from Mission Control'
  });
});

test('the knob write body is exactly what PUT /api/settings takes', () => {
  assert.deepEqual(settingBody('merge-conductor', 'MC_MAX_PRS', 12, null), {
    key: 'lane.merge-conductor.mc_max_prs', value: 12, actor: 'console',
    note: 'set from Mission Control'
  });
  assert.deepEqual(settingBody('review-prs', 'RP_MAX_HEADS', 30, 'project-4'), {
    key: 'lane.review-prs.project-4.rp_max_heads', value: 30, actor: 'console',
    note: 'set from Mission Control'
  });
});

// --------------------------------------------------------------- actions

function harness({ confirmAnswer = true, writeThrows = null } = {}) {
  const calls = { confirm: [], flag: [], setting: [], all: [], refresh: 0, notes: [] };
  const actions = makeLaneActions({
    confirm: async (opts) => { calls.confirm.push(opts); return confirmAnswer; },
    writeFlag: async (body) => { calls.flag.push(body); if (writeThrows) throw new Error(writeThrows); },
    writeSetting: async (body) => { calls.setting.push(body); if (writeThrows) throw new Error(writeThrows); },
    writeAll: async (which, body) => { calls.all.push({ which, body }); if (writeThrows) throw new Error(writeThrows); },
    refresh: () => { calls.refresh += 1; },
    onNote: (n) => calls.notes.push(n)
  });
  return { actions, calls };
}

const mcRow = { id: 'merge-conductor', name: 'Merge conductor', project: null, off: false };

test('turning a lane OFF asks the in-app modal first, then writes the exact flag body', async () => {
  const { actions, calls } = harness();
  const res = await actions.toggleLane(mcRow);
  assert.equal(calls.confirm.length, 1, 'the confirm modal ran');
  assert.match(calls.confirm[0].title, /OFF/);
  assert.equal(res.status, 'written');
  assert.deepEqual(calls.flag, [{
    name: 'lane-off-merge-conductor', active: 1, actor: 'console',
    reason: 'turned off from Mission Control'
  }]);
  assert.equal(calls.refresh, 1, 'the status is refetched after the write');
});

test('cancelling the modal writes NOTHING', async () => {
  const { actions, calls } = harness({ confirmAnswer: false });
  const res = await actions.toggleLane(mcRow);
  assert.equal(res.status, 'cancelled');
  assert.equal(calls.flag.length, 0);
  assert.equal(calls.refresh, 0);
});

test('turning a lane back ON writes active:0 under the same flag name', async () => {
  const { actions, calls } = harness();
  await actions.toggleLane({ ...mcRow, off: true });
  assert.deepEqual(calls.flag[0], {
    name: 'lane-off-merge-conductor', active: 0, actor: 'console',
    reason: 'turned on from Mission Control'
  });
});

test('a per-project lane toggles under its project-scoped flag name', async () => {
  const { actions, calls } = harness();
  await actions.toggleLane({ id: 'review-prs', name: 'Review PRs', project: 'project-4', off: false });
  assert.equal(calls.flag[0].name, 'lane-off-review-prs-project-4');
});

test('a failed write is reported and never reads as success', async () => {
  const { actions, calls } = harness({ writeThrows: 'http_500' });
  const res = await actions.toggleLane(mcRow);
  assert.equal(res.status, 'failed');
  assert.match(res.message, /http_500/);
  assert.equal(calls.refresh, 0);
  assert.ok(calls.notes.some((n) => /http_500/.test(n.text)));
});

test('an out-of-range knob never reaches the API and says which bound it broke', async () => {
  const { actions, calls } = harness();
  const knob = { env: 'MC_MAX_PRS', type: 'int', min: 1, max: 50 };
  const res = await actions.setKnob(mcRow, knob, '99');
  assert.equal(res.status, 'invalid');
  assert.match(res.message, /1/);
  assert.match(res.message, /50/);
  assert.equal(calls.setting.length, 0, 'nothing was written');
  assert.equal(calls.confirm.length, 0, 'a refused value never even asks');
});

test('an in-range knob writes the exact settings body and refetches', async () => {
  const { actions, calls } = harness();
  const knob = { env: 'MC_MAX_PRS', type: 'int', min: 1, max: 50 };
  const res = await actions.setKnob(mcRow, knob, '12');
  assert.equal(res.status, 'written');
  assert.deepEqual(calls.setting, [{
    key: 'lane.merge-conductor.mc_max_prs', value: 12, actor: 'console',
    note: 'set from Mission Control'
  }]);
  assert.equal(calls.refresh, 1);
});

test('ALL OFF asks first and posts the actor and reason', async () => {
  const { actions, calls } = harness();
  const res = await actions.allOff();
  assert.equal(calls.confirm.length, 1);
  assert.equal(res.status, 'written');
  assert.deepEqual(calls.all, [{
    which: 'all-off', body: { actor: 'console', reason: 'all lanes stopped from Mission Control' }
  }]);
  assert.equal(calls.refresh, 1);
});

test('ALL ON asks first too, and a cancel posts nothing', async () => {
  const { actions, calls } = harness();
  await actions.allOn();
  assert.deepEqual(calls.all, [{
    which: 'all-on', body: { actor: 'console', reason: 'all lanes resumed from Mission Control' }
  }]);

  const cancelled = harness({ confirmAnswer: false });
  await cancelled.actions.allOff();
  assert.equal(cancelled.calls.all.length, 0);
});

// ══════════════════════════════════════════════════ round 2 (review #1133)

// ------------------------------------------------- I1: the tab strip holds

test('the tab strip survives a tab switch that has not answered yet', () => {
  // useApi CLEARS data when its deps change, so the moment a project tab is
  // clicked the status is null for the length of the fetch. Deriving the tabs
  // from that null collapses the strip to HUB — and if the project status then
  // 404s it STAYS collapsed, stranding the operator on a screen with no way
  // back to the tab they were on. The strip is the navigation; it does not get
  // to disappear because one pane is loading.
  const held = ['hub', 'project-4', 'project-3'];
  assert.deepEqual(tabsFrom(null, held).map((t) => t.id), held, 'the last known strip is kept');
  assert.deepEqual(tabsFrom({ lanes: [] }, held).map((t) => t.id), held);
});

test('the ACTIVE tab is always in the strip, even if no payload ever named it', () => {
  const t = tabsFrom(null, ['hub'], 'project-3');
  assert.deepEqual(t.map((x) => x.id), ['hub', 'project-3']);
});

test('a fresh payload wins over the held strip', () => {
  const fresh = tabsFrom({ projects: ['a-os'] }, ['hub', 'stale-os'], 'a-os');
  assert.deepEqual(fresh.map((t) => t.id), ['hub', 'a-os'], 'the stale project is gone');
});

test('the held strip is never duplicated into itself', () => {
  const t = tabsFrom({ projects: ['project-4'] }, ['hub', 'project-4'], 'project-4');
  assert.deepEqual(t.map((x) => x.id), ['hub', 'project-4']);
});

// ------------------------------------------------ I2: the whole key is bound

test('a key over 64 characters is refused CLIENT-side, before the click costs a 400', () => {
  // Keep the project long enough that the whole key is 65 characters.
  const knob = { env: 'AUTOPILOT_DAILY_CAP_USD', type: 'int', min: 0, max: 999 };
  const res = validateKnob(knob, '50', {
    laneId: 'review-autopilot', project: 'fixture-project-xyz'
  });
  assert.equal(res.ok, false);
  assert.match(res.message, /65/, 'it names the length');
  assert.match(res.message, /64/, 'and the bound');
});

test('the same knob on the hub, whose key fits, is accepted', () => {
  const knob = { env: 'AUTOPILOT_DAILY_CAP_USD', type: 'int', min: 0, max: 999 };
  assert.equal(validateKnob(knob, '50', { laneId: 'review-autopilot', project: null }).ok, true);
});

test('the WHOLE key is lowercased, not only the env segment', () => {
  // A project or lane id carrying an uppercase character would otherwise build
  // a key the worker refuses, with nothing on the page saying why.
  assert.equal(settingKey('Review-Autopilot', 'MAX', 'project-4'), 'lane.review-autopilot.project-4.max');
  assert.match(settingKey('Review-Autopilot', 'MAX', 'project-4'), /^[a-z0-9_.-]{1,64}$/);
});

test('a key with a character the worker could never store is refused here', () => {
  const res = validateKnob({ env: 'MAX', type: 'int' }, '5', { laneId: 'lane/../etc', project: null });
  assert.equal(res.ok, false);
  assert.match(res.message, /lane\.lane\/\.\.\/etc\.max|character/i);
});

// ------------------------------------------- nit: strict decimal parsing

test('a hex or exponent string is not a number this page will send', () => {
  // Number('0x10') is 16 and passes Number.isInteger, so the naive parse would
  // write 16 for a value nobody typed.
  const knob = { env: 'MC_MAX_PRS', type: 'int', min: 1, max: 50 };
  assert.equal(validateKnob(knob, '0x10').ok, false, 'hex');
  assert.equal(validateKnob(knob, '1e1').ok, false, 'exponent');
  assert.equal(validateKnob(knob, 'Infinity').ok, false);
  assert.equal(validateKnob(knob, '12abc').ok, false);
  assert.equal(validateKnob(knob, '+12').ok, true, 'a signed decimal is still a decimal');
  assert.equal(validateKnob(knob, '12').ok, true);
  assert.equal(validateKnob({ env: 'X', type: 'float', min: -1, max: 1 }, '-0.5').ok, true);
});

// ══════════════════════════════════════════════════ round 3 (review #1133)

test('a present row with off:null stays UNKNOWN — it never reads as ON', () => {
  // The doc-vs-code mismatch phase A would have coded against: `off: s ?
  // Boolean(s.off) : null` turned a present row carrying `off: null` into
  // false, so the toggle drew ON and was clickable. A switch that shows a
  // state it did not read is worse than one that admits it does not know —
  // the operator's next move is to trust it.
  const reg = { lanes: [{ id: 'x', name: 'X', scope: 'hub', knobs: [] }] };
  const explicit = laneRows(reg, { scope: 'hub', lanes: [{ id: 'x', off: null, runs_today: 3 }] }, 'hub')[0];
  assert.equal(explicit.off, null, 'an explicit null is unknown, not off');
  assert.equal(explicit.runs_today, 3, 'the rest of the row is still real');

  const absent = laneRows(reg, { scope: 'hub', lanes: [{ id: 'x', runs_today: 3 }] }, 'hub')[0];
  assert.equal(absent.off, null, 'an absent field is unknown too');
});

test('a real true/false on a present row is still carried through exactly', () => {
  const reg = { lanes: [{ id: 'x', name: 'X', scope: 'hub', knobs: [] }] };
  const on = laneRows(reg, { scope: 'hub', lanes: [{ id: 'x', off: false }] }, 'hub')[0];
  const off = laneRows(reg, { scope: 'hub', lanes: [{ id: 'x', off: true }] }, 'hub')[0];
  assert.equal(on.off, false);
  assert.equal(off.off, true);
  // The truthy/falsy shapes D1 and JSON actually produce.
  assert.equal(laneRows(reg, { scope: 'hub', lanes: [{ id: 'x', off: 1 }] }, 'hub')[0].off, true);
  assert.equal(laneRows(reg, { scope: 'hub', lanes: [{ id: 'x', off: 0 }] }, 'hub')[0].off, false);
});

test('the UNREGISTERED row obeys the same rule — the branch is duplicated, the rule is not', () => {
  const unknown = laneRows({ lanes: [] }, { scope: 'hub', lanes: [{ id: 'newbie', off: null }] }, 'hub')[0];
  assert.equal(unknown.unregistered, true);
  assert.equal(unknown.off, null, 'a lane the registry has never heard of is not asserted to be ON');
  const real = laneRows({ lanes: [] }, { scope: 'hub', lanes: [{ id: 'newbie', off: true }] }, 'hub')[0];
  assert.equal(real.off, true);
});

// ── BH-1165: what the row has to carry now ──────────────────────────────────
// Phase B built the screen against the payload phase A served. Phase C added
// three things an operator has to see: a flag file that no row drove (and which
// box holds it), the pre-BH-1132 switches that only CHANGE a lane's behaviour,
// and the knobs that are not numbers.

const bh1165Status = {
  scope: 'hub',
  as_of: iso(1),
  projects: ['project-4'],
  all_off: false,
  lanes: [
    {
      id: 'merge-conductor', off: false, cadence: '*/5',
      last_tick_at: iso(2), last_outcome: 'ran',
      modifiers: [{ name: 'merge-conductor-observe', active: true }],
      enables: [{ name: 'conductor-owns-merges', active: true }],
      flag_boxes: [], held_by: [], knobs: {}
    },
    {
      id: 'alert-triage', off: true, off_source: 'flag', paused_since: iso(30),
      paused_by: 'box-hub',
      paused_reason: 'a file nothing in the database wrote: flags/lane-off-alert-triage on box-hub',
      flag_boxes: ['box-hub'], held_by: ['lane-off-alert-triage'],
      last_tick_at: iso(3), last_outcome: 'paused',
      modifiers: [], enables: [], knobs: {}
    }
  ]
};

test('a row carries the boxes holding a file nobody wrote a row for', () => {
  const rows = laneRows(registry, bh1165Status, 'hub');
  const at = rows.find((r) => r.id === 'alert-triage');
  assert.equal(at.off, true);
  assert.equal(at.off_source, 'flag');
  assert.deepEqual(at.flag_boxes, ['box-hub']);
  assert.deepEqual(at.held_by, ['lane-off-alert-triage']);
  assert.match(at.paused_reason, /flags\/lane-off-alert-triage on box-hub/);
  // a lane with no sighting says so with an empty list, never undefined — a
  // renderer that has to guard on undefined eventually forgets to
  const mc = rows.find((r) => r.id === 'merge-conductor');
  assert.deepEqual(mc.flag_boxes, []);
});

test('a row carries the modifiers and the enables the payload reports', () => {
  // The ten `partial` aliases only CHANGE what a lane does
  // (merge-conductor-observe makes it dry-run). A page that showed neither the
  // modifier nor the enable told an operator a lane was simply "on" while it
  // was observing and merging nothing.
  const rows = laneRows(registry, bh1165Status, 'hub');
  const mc = rows.find((r) => r.id === 'merge-conductor');
  assert.deepEqual(mc.modifiers.map((m) => m.name), ['merge-conductor-observe']);
  assert.deepEqual(mc.enables.map((e) => e.name), ['conductor-owns-merges']);
  assert.deepEqual(rows.find((r) => r.id === 'alert-triage').modifiers, []);
});

test('a STRING knob is settable — a model slug is not a decimal', () => {
  // 212 knobs joined the registry in BH-1165 and about eighty of them are
  // strings (a model name, a list of boxes, a regex). validateKnob refused
  // every one of them as "must be a decimal number", so the page offered an
  // input that could only ever 400.
  const knob = { env: 'TRIAGE_MODEL', type: 'string', default: 'grok-4.6' };
  const ok = validateKnob(knob, ' claude-opus-5 ', { laneId: 'run-triage', project: null });
  assert.equal(ok.ok, true);
  assert.equal(ok.value, 'claude-opus-5', 'the value is trimmed, not reformatted');
  assert.equal(validateKnob(knob, '').ok, false, 'an empty string is still not a value');
  // the worker stores at most 256 characters and refuses the rest with a 400
  assert.equal(validateKnob(knob, 'x'.repeat(257)).ok, false);
  assert.equal(validateKnob(knob, 'a\nb').ok, false, 'a newline is not part of a knob');
  // and a NUMBER knob is still a number: this must not have widened the int path
  assert.equal(validateKnob({ env: 'N', type: 'int', min: 0, max: 9 }, 'four').ok, false);
  assert.equal(validateKnob({ env: 'N', type: 'int', min: 0, max: 9 }, '99').ok, false);
});

// ── BH-1165 round 1: `settable: false` never reaches the screen ─────────────
// Wiring all 78 lanes registered every `${X:-…}` an automatic script reads, and
// about eighty of those are the command a lane runs (CLI_CHECK_SSH is expanded
// UNQUOTED as `$SSH_CMD "root@$1" "bash -s"`), the host it sends
// `Bearer $HARNESS_SECRET` to (JOBS_URL), the path it deletes under
// (DISK_CLEAN_REPOS) or a test seam (AUTH_CHECK_LIB). bin/lib/lane-gate.sh
// exports a settings row into a lane cron runs AS ROOT — so drawing an input
// for one is drawing remote code execution on a control-plane page.

const hazardRegistry = {
  lanes: [{
    id: 'doorbell-coverage-check', name: 'Doorbell coverage', scope: 'hub',
    script: 'bin/doorbell-coverage-check.sh', cadence: '*/30', boxes: ['hub'],
    switch: { kind: 'flag', name: 'lane-off-doorbell-coverage-check' },
    knobs: [
      { env: 'JOBS_URL', type: 'string', default: '', settable: false },
      { env: 'DOORBELL_STALE_H', type: 'int', default: 6, min: 1, max: 48, zero_means: null }
    ],
    stats: {}
  }]
};

test('a settable:false knob is not drawn on the settings page at all', () => {
  const rows = laneRows(hazardRegistry, {
    scope: 'hub', as_of: iso(1), projects: [], all_off: false,
    lanes: [{ id: 'doorbell-coverage-check', off: false, knobs: {} }]
  }, 'hub');
  assert.deepEqual(rows[0].knobs.map((k) => k.env), ['DOORBELL_STALE_H']);
});

test('validateKnob refuses a settable:false knob even when a caller builds one by hand', () => {
  const r = validateKnob({ env: 'JOBS_URL', type: 'string', settable: false },
    'https://attacker.example', { laneId: 'doorbell-coverage-check', project: null });
  assert.equal(r.ok, false);
  assert.match(r.message, /not settable/);
  // and the ordinary knob beside it is untouched
  assert.equal(validateKnob({ env: 'DOORBELL_STALE_H', type: 'int', min: 1, max: 48 }, '6',
    { laneId: 'doorbell-coverage-check', project: null }).ok, true);
});
