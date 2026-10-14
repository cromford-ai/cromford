import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { api } from '../src/api.js';
import { laneSpendRows, ceilingText, stateOf, switchBanner } from '../src/lib/lane-spend.js';
import { LaneSpendSection, LaneSpendView } from '../src/screens/LaneSpend.js';

// BH-6174 (BH-5526 slice C4): the LANE SPEND section on /costs. The payload is
// the shape GET /api/metrics/lane-spend returns (worker/jobs/src/routes/
// lane-spend.js): lanes sorted today_usd desc, null where a lane has no p99 row
// or no armed ceiling.

const lane = (over) => ({
  lane: 'x', registered: true, today_usd: 0, calls: 0,
  p99_usd: null, p99_days: null, alert_mult: null, alert_usd: null,
  ceiling_usd: null, ceiling_state: 'none', ceiling_raw: null,
  over_alert: false, over_ceiling: false, pct_of_ceiling: null, ...over,
});

const payload = {
  day: '2099-10-12', since: '2099-10-12T00:00:00Z', until: '2099-10-13T00:00:00Z',
  p99_day: '2099-10-12', ceiling_switch_fleet: false, skipped_rows: 0,
  as_of: '2099-10-12T18:00:00.000Z',
  lanes: [
    lane({ lane: 'fly-pool', today_usd: 160, calls: 12, p99_usd: 100, p99_days: 14, alert_mult: 1.5, alert_usd: 150,
      ceiling_usd: 300, ceiling_state: 'armed', ceiling_raw: '300', over_alert: true, pct_of_ceiling: 53.3 }),
    lane({ lane: 'review-prs', today_usd: 12, calls: 3, ceiling_usd: 10, ceiling_state: 'armed', ceiling_raw: '10',
      over_ceiling: true, pct_of_ceiling: 120 }),
    lane({ lane: 'stage-review', registered: false, today_usd: 1, calls: 1, p99_usd: 3.1, p99_days: 9,
      alert_mult: 1.5, alert_usd: 4.65 }),
    lane({ lane: 'lead-review', today_usd: 0.5, calls: 2, ceiling_state: 'off', ceiling_raw: 'off' }),
    lane({ lane: 'alert-triage', today_usd: 0, ceiling_state: 'junk', ceiling_raw: 'abc' }),
    lane({ lane: 'merge-queue', today_usd: 0, ceiling_state: 'zero', ceiling_raw: '0' }),
  ],
};

test('C1 laneSpendRows keeps nulls null; ceilingText covers every ceiling state', () => {
  const rows = laneSpendRows(payload);
  assert.equal(rows.length, 6);
  const st = rows.find((r) => r.lane === 'stage-review');
  assert.equal(st.registered, false);
  assert.equal(st.alert_usd, 4.65);
  const rp = rows.find((r) => r.lane === 'review-prs');
  assert.equal(rp.alert_usd, null, 'a lane with no p99 row has no alert line, never 0');
  assert.equal(rp.p99_usd, null);
  assert.equal(rp.p99_days, null);
  const lr = rows.find((r) => r.lane === 'lead-review');
  assert.equal(lr.ceiling_usd, null);
  assert.equal(lr.pct_of_ceiling, null);
  assert.equal(new Set(rows.map((r) => r.key)).size, 6, 'keys are unique');
  assert.deepEqual(laneSpendRows(null), []);
  assert.deepEqual(laneSpendRows({}), []);
  assert.deepEqual(laneSpendRows({ lanes: 'nope' }), []);

  assert.equal(ceilingText(rows.find((r) => r.lane === 'fly-pool')), '$300.00');
  assert.equal(ceilingText(lane({ ceiling_state: 'armed', ceiling_usd: 10.5, ceiling_raw: '10.5' })), '$10.50');
  assert.equal(ceilingText(lr), 'off');
  assert.equal(ceilingText(rows.find((r) => r.lane === 'merge-queue')), '0 (none)');
  assert.equal(ceilingText(rows.find((r) => r.lane === 'alert-triage')), 'junk: abc');
  assert.equal(ceilingText(lane({ ceiling_state: 'none' })), '—');
  assert.equal(ceilingText(lane({ ceiling_state: 'armed', ceiling_usd: null })), '—', 'armed with no number is not $0.00');
  assert.equal(ceilingText(null), '—');
});

test('C2 stateOf: OVER CEILING beats OVER ALERT beats ok; no line when both lines are null', () => {
  const both = stateOf(lane({ over_ceiling: true, over_alert: true, alert_usd: 1, ceiling_usd: 1 }));
  assert.equal(both.label, 'OVER CEILING');
  assert.equal(both.tone, 'dead');
  const alertOnly = stateOf(lane({ over_alert: true, alert_usd: 1, ceiling_usd: 9 }));
  assert.equal(alertOnly.label, 'OVER ALERT');
  assert.equal(alertOnly.tone, 'warn');
  const fine = stateOf(lane({ alert_usd: 5, ceiling_usd: 9 }));
  assert.equal(fine.label, 'ok');
  assert.equal(fine.tone, 'ok');
  assert.equal(stateOf(lane({ alert_usd: 5 })).label, 'ok', 'one line is enough to be ok');
  assert.equal(stateOf(lane({ ceiling_usd: 9 })).label, 'ok');
  const none = stateOf(lane({ ceiling_state: 'off' }));
  assert.equal(none.label, 'no line');
  assert.equal(none.tone, 'muted');
  const rows = laneSpendRows(payload);
  assert.deepEqual(rows.map((r) => r.state.label), ['OVER ALERT', 'OVER CEILING', 'ok', 'no line', 'no line', 'no line']);
});

test('C3 the view: title, sortable TODAY, registered lanes link, stage lanes do not', () => {
  const out = render(h(LaneSpendView, { data: payload, error: null, loading: false, reload() {} }));
  assert.ok(out.includes('LANE SPEND · TODAY (UTC)'));
  assert.match(out, /<table/);
  assert.match(out, /<th[^>]*aria-sort="descending"[^>]*>\s*<button[^>]*title="sort by today"/, 'TODAY is the default sort, descending');
  for (const c of ['lane', 'today', 'alert line', 'ceiling', '% of ceiling', 'p99 · days', 'state']) {
    assert.ok(out.includes(`title="sort by ${c}"`), `sortable header ${c}`);
  }
  assert.ok(out.includes('href="/settings/fly-pool"'));
  assert.ok(out.includes('href="/settings/review-prs"'));
  assert.ok(!out.includes('href="/settings/stage-review"'), 'a stage-<s> id has no detail screen');
  assert.match(out, /<span class="na" title="not a registered lane: no detail screen">stage-review<\/span>/);
  assert.ok(out.includes('tablewrap--wide'), 'scrolls inside its own container on a phone');
  assert.ok(out.includes('$160.00'));
  assert.ok(out.includes('$150.00'));
  assert.ok(out.includes('$300.00'));
  assert.ok(out.includes('53.3%'));
  assert.ok(out.includes('$100.00 · 14d'));
  assert.ok(out.includes('junk: abc'));
  assert.ok(out.includes('0 (none)'));
  assert.ok(out.includes('OVER CEILING'));
  assert.ok(out.includes('OVER ALERT'));
  // Two lanes report a real today_usd of 0; every null line is `—`, never $0.00.
  assert.equal((out.match(/\$0\.00 </g) || []).length, 2, 'only the two real zero TODAY cells show $0.00');
  assert.ok(out.includes('cost_rows per lane_id since 2099-10-12T00:00:00Z'));
  assert.ok(out.includes('alert line = 1.5x p99 from the table of 2099-10-12'));
  assert.ok(out.includes('ceiling = settings spend.ceiling.&lt;lane>.day_usd') || out.includes('ceiling = settings spend.ceiling.&lt;lane&gt;.day_usd'));
  // Rows arrive in TODAY desc, and the default sort keeps that order.
  const order = ['fly-pool', 'review-prs', 'stage-review', 'lead-review'].map((l) => out.indexOf(`>${l}<`));
  assert.ok(order.every((v, i) => v > 0 && (i === 0 || v > order[i - 1])), `order ${order}`);
  assert.equal(typeof LaneSpendSection, 'function');
});

test('C4 the states: loading, error, empty, the switch banner, the p99 footnote', () => {
  const loading = render(h(LaneSpendView, { data: null, error: null, loading: true, reload() {} }));
  assert.ok(loading.includes('class="skel"'));
  assert.ok(!loading.includes('<table'));

  const err = render(h(LaneSpendView, { data: null, error: new Error('boom 503'), loading: false, reload() {} }));
  assert.ok(err.includes('could not load'));
  assert.ok(err.includes('boom 503'));
  assert.ok(err.includes('RETRY'));
  assert.ok(!err.includes('no lane has spend'), 'a failed read is not "no data"');

  const empty = render(h(LaneSpendView, { data: { ...payload, lanes: [] }, error: null, loading: false, reload() {} }));
  assert.ok(empty.includes('no lane has spend, an alert line or a ceiling today'));
  assert.ok(!empty.includes('<table'));

  const sw = render(h(LaneSpendView, { data: { ...payload, ceiling_switch_fleet: true }, error: null, loading: false, reload() {} }));
  assert.ok(sw.includes('switch.spend-ceiling-off'));
  assert.ok(sw.includes('no ceiling is enforced'));
  assert.ok(sw.includes('per-box switch is not visible here'));
  assert.ok(!render(h(LaneSpendView, { data: payload, loading: false, reload() {} })).includes('switch.spend-ceiling-off'));
  assert.equal(switchBanner({ ceiling_switch_fleet: false }), null);
  assert.equal(switchBanner({ ceiling_switch_fleet: null }), null);
  assert.equal(switchBanner(null), null);
  assert.match(switchBanner({ ceiling_switch_fleet: true }), /switch\.spend-ceiling-off/);

  const old = render(h(LaneSpendView, { data: { ...payload, p99_day: '2099-10-11' }, error: null, loading: false, reload() {} }));
  assert.ok(old.includes('the alert lines come from the p99 table of 2099-10-11, not 2099-10-12'));
  const none = render(h(LaneSpendView, { data: { ...payload, p99_day: null }, error: null, loading: false, reload() {} }));
  assert.ok(none.includes('no p99 table is pushed yet'));
  const today = render(h(LaneSpendView, { data: payload, error: null, loading: false, reload() {} }));
  assert.ok(!today.includes('not 2099-10-12') && !today.includes('no p99 table is pushed yet'));

  // No lane carries a multiplier: the note does not invent one.
  const nomult = render(h(LaneSpendView, { data: { ...payload, lanes: [payload.lanes[1]] }, error: null, loading: false, reload() {} }));
  assert.ok(!nomult.includes('x p99'));
  assert.ok(nomult.includes('alert line = p99 table of 2099-10-12'));
});

test('C5 api.laneSpend asks the coord proxy, with ?day= only when given', async () => {
  const calls = [];
  globalThis.fetch = async (url) => {
    calls.push(String(url));
    return { ok: true, status: 200, text: async () => JSON.stringify({ lanes: [] }) };
  };
  await api.laneSpend();
  await api.laneSpend('2099-10-12');
  assert.deepEqual(calls, ['/api/coord/metrics/lane-spend', '/api/coord/metrics/lane-spend?day=2099-10-12']);
});

// TEST-CHANGE (merge queue batches, 2026-10-13): C6 pinned the mount directly
// after CAPS, which splits the CAPS/HISTORY pair that
// tests/cost-caps-contract.bh-2563-test.sh M2 requires on consecutive lines.
// The section now sits directly after HISTORY, and C6 pins that.
test('C6 the production section renders, and /costs mounts it directly after the cap HISTORY', () => {
  const out = render(h(LaneSpendSection));
  assert.ok(out.includes('LANE SPEND · TODAY (UTC)'));
  assert.ok(out.includes('class="skel"'), 'first paint is the skeleton, not an empty table');
  const src = readFileSync(new URL('../src/screens/Costs.js', import.meta.url), 'utf8');
  assert.notEqual(src.indexOf("import { LaneSpendSection } from './LaneSpend.js'"), -1);
  const hist = src.indexOf('<${CostCapHistorySection}/>');
  const mine = src.indexOf('<${LaneSpendSection}/>');
  assert.notEqual(hist, -1);
  assert.notEqual(mine, -1);
  assert.match(src.slice(hist), /^<\$\{CostCapHistorySection\}\/>\s*<\$\{LaneSpendSection\}\/>/);
});
