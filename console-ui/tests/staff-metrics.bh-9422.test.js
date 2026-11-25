import test from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';

// BH-9422 (BH-9187.4, C4): the staff lever scorecards on Mission Control.
// /staff gets a METRICS section (one row per staff agent) under ROSTER, and
// /staff/<agent> gets a METRIC section. The pure half (lib/staff-scores.js)
// is driven directly; the views render server-side, through StaffView and
// AgentDetailView, the views the nav STAFF tab and the roster AGENT link open.
//
//   M1 scoreRows: a scoreboard body -> rows; no agents array -> null
//   M2 precisionText: null n/a, 0 0%, 0.5 50%, 2/3 67%
//   M3 fmtValue: null no sample, 0 0, 3.456 3.46, 41 41
//   M4 StaffMetricsView: loading Skeleton, error ErrorBox + RETRY, empty list
//   M5 StaffView with the metrics slot: METRICS after ROSTER, AGENT links,
//      the ten sortable headers
//   M6 AgentMetricView: METRIC, TARGET, LEVEL, NOW, 7 DAYS AGO, PRECISION n/a
//   M7 AgentDetailView with metricSlot: a METRIC section; without: none
//   M8 the archie rule: no metric slot for archie or " Archie "

globalThis.window = globalThis.window || {
  location: { pathname: '/staff', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { scoreRows, fmtValue, precisionText, metricAgentOf } = await import('../src/lib/staff-scores.js');
const { StaffMetricsView, AgentMetricView } = await import('../src/screens/staff/staff-metrics.js');
const { StaffView, AgentDetailView } = await import('../src/screens/Staff.js');
const { render } = await import('preact-render-to-string');

// ---------------------------------------------------------------- fixtures
// Exactly the fields worker/jobs/src/routes/staff-scoreboard.js answers per
// agent (the GET /api/staff/levers/scorecard answer minus ok).
const card = (agent, over = {}) => ({
  agent, days: 7, metric: 'hours_behind_main', target: 2, level: 'observe',
  metric_now: { value: 3, sampled_at: '2026-11-11T02:00:00Z' },
  metric_then: { value: 41, sampled_at: '2026-11-03T02:00:00Z' },
  actions: 2, dry_runs: 1, settled: 2, moved: 1, precision: 0.5, ...over
});
const BOARD = {
  ok: true, days: 7, as_of: '2026-11-11T03:00:00Z',
  agents: [
    card('inspector'),
    card('clerk', { metric: 'needs_count', target: 300, metric_now: null, metric_then: null, actions: 0, dry_runs: 0, settled: 0, moved: 0, precision: null }),
    card('tackler', { metric: null, target: null, metric_now: null, metric_then: null, actions: 0, dry_runs: 0, settled: 0, moved: 0, precision: null })
  ]
};
const ROSTER = {
  agents: [
    { name: 'archie', kind: 'overlooker', role: 'overlooker', accountable: 'operator@example.com', autonomy: 'per-class', cap: null, status: null, open_findings: 0, precision: null, spend_usd: null, last_tick_at: null },
    { name: 'clerk', kind: 'staff', role: 'records', accountable: 'operator@example.com', autonomy: 'automation', cap: 'augmentation', status: 'active', open_findings: 0, precision: null, spend_usd: null, last_tick_at: null }
  ],
  sources: {},
  as_of: '2026-11-11T03:00:00Z'
};
const FINDINGS = { agent: 'clerk', findings: [], truncated: false };
const ok = (data) => ({ data, error: null, loading: false, reload() {} });
const loading = () => ({ data: null, error: null, loading: true, reload() {} });
const failed = (msg) => ({ data: null, error: new Error(msg), loading: false, reload() {} });
const text = (s) => s.replace(/<[^>]+>/g, ' ').replace(/&#x2F;/g, '/').replace(/\s+/g, ' ');
const headersOf = (out) => [...out.matchAll(/<th\b[^>]*>([\s\S]*?)<\/th>/g)].map((m) => text(m[1]).replace(/[↑↓]/g, '').trim());

test('M1 scoreRows: rows from a scoreboard body; a body with no agents array is null', () => {
  const r = scoreRows(BOARD);
  assert.equal(r.days, 7);
  assert.deepEqual(r.rows.map((x) => x.agent), ['inspector', 'clerk', 'tackler']);
  assert.deepEqual(r.rows[0], { ...BOARD.agents[0], now: 3, then: 41 });
  assert.equal(r.rows[1].now, null);
  for (const bad of [null, undefined, {}, { ok: true }, { agents: 'x' }, 'text']) assert.equal(scoreRows(bad), null, JSON.stringify(bad));
  assert.deepEqual(scoreRows({ ok: true, days: 7, agents: [] }).rows, []);
});

test('M2 precisionText: null n/a (never 0%), 0 0%, 0.5 50%, 1 100%, 2/3 67%', () => {
  assert.equal(precisionText(null), 'n/a');
  assert.equal(precisionText(undefined), 'n/a');
  assert.equal(precisionText(0), '0%');
  assert.equal(precisionText(0.5), '50%');
  assert.equal(precisionText(1), '100%');
  assert.equal(precisionText(2 / 3), '67%');
});

test('M3 fmtValue: null no sample (never 0), 0, 3.456 3.46, 41', () => {
  assert.equal(fmtValue(null), 'no sample');
  assert.equal(fmtValue(undefined), 'no sample');
  assert.equal(fmtValue({ value: 0, sampled_at: 'x' }), '0');
  assert.equal(fmtValue({ value: 3.456, sampled_at: 'x' }), '3.46');
  assert.equal(fmtValue({ value: 41, sampled_at: 'x' }), '41');
  assert.equal(fmtValue(0), '0');
  assert.equal(fmtValue(3.456), '3.46');
});

test('M4 StaffMetricsView: loading Skeleton, error ErrorBox with RETRY, empty list', () => {
  const l = render(h(StaffMetricsView, { board: loading() }));
  assert.match(l, /class="skel"/);
  assert.doesNotMatch(l, /<table/);
  const e = render(h(StaffMetricsView, { board: failed('http_503') }));
  assert.match(e, /class="banner"/);
  assert.match(e, /http_503/);
  assert.match(e, />RETRY</);
  const bad = render(h(StaffMetricsView, { board: ok({ ok: true }) }));
  assert.match(bad, /class="banner"/, 'a body with no agents array is a failed read, never an empty list');
  const empty = render(h(StaffMetricsView, { board: ok({ ok: true, days: 7, agents: [] }) }));
  assert.match(empty, /no staff agents/);
});

test('M5 StaffView renders METRICS after ROSTER, with agent links and sortable headers', () => {
  const metrics = h(StaffMetricsView, { board: ok(BOARD) });
  const out = render(h(StaffView, { roster: ok(ROSTER), flags: ok({ flags: [] }), onKill() {}, metrics }));
  const iRoster = out.indexOf('>ROSTER<');
  const iMetrics = out.indexOf('>METRICS<');
  assert.ok(iRoster > 0, 'ROSTER section');
  assert.ok(iMetrics > iRoster, 'METRICS section after ROSTER');
  const part = out.slice(iMetrics);
  assert.deepEqual(headersOf(part), ['AGENT', 'METRIC', 'TARGET', 'LEVEL', 'NOW', '7D AGO', 'ACTIONS', 'SETTLED', 'MOVED', 'PRECISION']);
  const ths = [...part.matchAll(/<th\b[^>]*>[\s\S]*?<\/th>/g)].map((m) => m[0]);
  for (const th of ths) {
    assert.match(th, /aria-sort=/, th);
    assert.match(th, /<button/, th);
  }
  for (const a of ['inspector', 'clerk', 'tackler']) assert.match(part, new RegExp(`href="/staff/${a}"`), a);
  const t = text(part);
  assert.match(t, /hours_behind_main/);
  assert.match(t, /needs_count/);
  assert.match(t, /no sample/);
  assert.match(t, /50%/);
  assert.match(t, /n\/a/);
  assert.match(t, /no metric row/);
  assert.doesNotMatch(part, /href="\/staff\/archie"/);
  assert.doesNotMatch(part, /—/, 'no em dash in the section');
  // Without the slot the page is today's page: no METRICS section.
  const bare = render(h(StaffView, { roster: ok(ROSTER), flags: ok({ flags: [] }), onKill() {} }));
  assert.doesNotMatch(bare, />METRICS</);
});

test('M6 AgentMetricView: metric, target, level, now, 7 days ago, precision n/a when 0 settled', () => {
  const out = render(h(AgentMetricView, { card: ok({ ok: true, ...BOARD.agents[1] }) }));
  const t = text(out);
  for (const [k, v] of [['METRIC', 'needs_count'], ['TARGET', '300'], ['LEVEL', 'observe'], ['NOW', 'no sample'], ['7 DAYS AGO', 'no sample'],
    ['ACTIONS', '0'], ['DRY RUNS', '0'], ['SETTLED', '0'], ['MOVED', '0'], ['PRECISION', 'n/a']]) {
    assert.match(t, new RegExp(` ${k} ${v.replace('/', '\\/')} `), `${k} ${v}: ${t}`);
  }
  const full = text(render(h(AgentMetricView, { card: ok({ ok: true, ...BOARD.agents[0] }) })));
  assert.match(full, / NOW 3 /);
  assert.match(full, / 7 DAYS AGO 41 /);
  assert.match(full, / PRECISION 50% /);
  assert.match(render(h(AgentMetricView, { card: loading() })), /class="skel"/);
  const e = render(h(AgentMetricView, { card: failed('agent not found') }));
  assert.match(e, /agent not found/);
  assert.match(e, />RETRY</);
});

test('M7 AgentDetailView: metricSlot renders a METRIC section; without it, none', () => {
  const slot = h(AgentMetricView, { card: ok({ ok: true, ...BOARD.agents[1] }) });
  const base = { agent: 'clerk', roster: ok(ROSTER), findings: ok(FINDINGS), activity: ok({ agent: 'clerk', events: [], next: null, last_tick: null, cost_status: 'ok' }) };
  const withSlot = render(h(AgentDetailView, { ...base, metricSlot: slot }));
  assert.match(withSlot, /class="section__title">METRIC</);
  assert.match(text(withSlot), / METRIC needs_count /);
  const without = render(h(AgentDetailView, base));
  assert.doesNotMatch(without, /class="section__title">METRIC</);
  assert.equal(without, render(h(AgentDetailView, { ...base, metricSlot: null })));
});

test('M8 the archie rule: archie gets no metric section; a staff agent does', () => {
  assert.equal(metricAgentOf('archie'), null);
  assert.equal(metricAgentOf(' Archie '), null);
  assert.equal(metricAgentOf('clerk'), 'clerk');
  assert.equal(metricAgentOf(' Clerk '), 'clerk');
  assert.equal(metricAgentOf(''), null);
  assert.equal(metricAgentOf(undefined), null);
});
