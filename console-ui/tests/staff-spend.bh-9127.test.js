import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

// BH-9127: spend per staff agent on /staff and /staff/:agent, Archie's turn
// rows in the timeline, and COSTS filtered to one agent (/costs?agent=<name>).
// The roster and detail views render server-side; the agent section and the
// routed /costs are mounted in the shared fake DOM against a stubbed fetch, so
// the requests go through the real api.js. C8 is the entry-point test: the
// SPEND link on the roster leads to the filtered COSTS screen.

globalThis.window = globalThis.window || {
  location: { pathname: '/staff', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {} }
};

const { installDom, routedFetch, all, fire } = await import('./helpers/fake-dom.bh-5750.js');
// The new modules load lazily so each case fails on its own before they exist.
const opt = (p) => import(p).catch(() => ({}));
const spendLib = await opt('../src/lib/staff-spend.js');
const agentSpend = await opt('../src/screens/AgentSpend.js');
const { StaffView, AgentDetailView } = await import('../src/screens/Staff.js');
const { ROUTES } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const { render } = await import('preact-render-to-string');

// ---------------------------------------------------------------- fixtures
// The shape GET /api/staff/roster answers after BH-9127 (staff-screen.js).
const agentRow = (name, over = {}) => ({
  name, kind: name === 'archie' ? 'overlooker' : 'staff', role: 'r', accountable: 'operator@example.com', autonomy: 'automation',
  cap: null, status: 'active', open_findings: 0, precision: null, last_tick_at: null,
  spend_usd: 0, spend_usd_7d: 0, spend_unpriced: 0, spend_unpriced_7d: 0, spend_lanes: [], spend_window_days: 7, ...over
});
const ARCHIE_LANES = ['archie', 'archie-cards', 'archie-learn', 'archie-research', 'orc-monitor'];
const ROSTER = {
  agents: [
    agentRow('archie', { spend_usd: 1.5, spend_usd_7d: 3.25, spend_lanes: ARCHIE_LANES }),
    agentRow('quartermaster', { spend_usd: 0, spend_usd_7d: 0, spend_lanes: ['cost-reconcile'] }),
    agentRow('clerk', { spend_usd: 0.25, spend_usd_7d: 0.75, spend_unpriced: 2, spend_unpriced_7d: 3 }),
    agentRow('watchman', { spend_usd: null, spend_usd_7d: null, spend_unpriced: null, spend_unpriced_7d: null })
  ],
  sources: { precision: 'not built: BH-5563 (#5563)', spend: 'cost_rows' },
  as_of: '2026-11-06T06:00:00Z'
};
const UNREAD = { ...ROSTER, sources: { ...ROSTER.sources, spend: 'unread' } };
const lane = (name, usd) => ({
  lane: name, registered: true, today_usd: usd, calls: 3, p99_usd: null, p99_days: null, alert_mult: 3, alert_usd: null,
  ceiling_usd: null, ceiling_state: 'none', ceiling_raw: null, over_alert: false, over_ceiling: false, pct_of_ceiling: null
});
const LANES = { day: '2026-11-06', lanes: [lane('orc-monitor', 1.0), lane('archie', 0.5), lane('cost-reconcile', 0.2)], ceiling_switch_fleet: false };
const COSTS = { window_days: 7, volume: [], readouts: [], gaps: [] };
const FLAGS = { flags: [], as_of: '2026-11-06T06:00:00Z' };

const ok = (data) => ({ data, error: null, loading: false, reload() {} });
const failed = (msg) => ({ data: null, error: new Error(msg), loading: false, reload() {} });
const rosterView = (roster = ROSTER) => render(h(StaffView, { roster: ok(roster), flags: ok(FLAGS), onKill() {} }));
const bodyRows = (out) => {
  const tb = out.split('<tbody>')[1] || '';
  return (tb.split('</tbody>')[0].match(/<tr[\s>]/g) || []).length;
};
const text = (n) => n.textContent.replace(/\s+/g, ' ').trim();
const ROUTE = (roster = ROSTER, lanes = LANES) => (u) => {
  if (u === '/api/coord/staff/roster') return roster ? [200, roster] : [500, { error: 'roster down' }];
  if (u.startsWith('/api/coord/metrics/lane-spend')) return lanes ? [200, lanes] : [500, { error: 'lane spend down' }];
  if (u === '/api/dash/costs') return [200, COSTS];
  return [404, { error: 'unknown endpoint' }];
};

let mounted = null;
afterEach(() => { if (mounted) { mount(null, mounted); mounted = null; } });
async function mountNode(vnode) {
  const doc = installDom();
  const root = doc.createElement('div');
  mount(vnode, root);
  mounted = root;
  await flush();
  return root;
}
// The section whose title is `title`, as a fake-DOM node.
const sectionOf = (root, title) => all(root).find((n) => /\bsection\b/.test(n.attrs?.class || '')
  && all(n).some((t) => /\bsection__title\b/.test(t.attrs?.class || '') && text(t) === title));

// ------------------------------------------------------------------ C1
test('C1: SPEND is a link to /costs?agent=<name>; a real 0 is $0.00; null is n/a with the source tooltip', () => {
  assert.equal(spendLib.costsHref('archie'), '/costs?agent=archie');
  assert.equal(spendLib.costsHref('a b'), '/costs?agent=a%20b');
  const out = rosterView();
  assert.match(out, /<a href="\/costs\?agent=archie"[^>]*>\$1\.50<\/a>/);
  assert.match(out, /<a href="\/costs\?agent=quartermaster"[^>]*>\$0\.00<\/a>/);
  assert.match(out, /<a href="\/costs\?agent=clerk"[^>]*>\$0\.25<\/a>\s*<span class="na">\+2 unpriced<\/span>/);
  // The 7D figure rides the tooltip.
  assert.match(out, /<a href="\/costs\?agent=archie"[^>]*title="[^"]*7D \$3\.25/);
  // watchman's spend is null: n/a, never $0.00, and no link that claims a figure.
  assert.doesNotMatch(out, /href="\/costs\?agent=watchman"/);
  const unread = rosterView(UNREAD);
  assert.match(unread, /<span class="na" title="unread">n\/a<\/span>/);
});

// ------------------------------------------------------------------ C2
test('C2: sorting by SPEND puts the null spend last in both directions, with aria-sort', async () => {
  const root = await mountNode(h(StaffView, { roster: ok(ROSTER), flags: ok(FLAGS), onKill() {} }));
  const th = all(root).find((n) => n.localName === 'th' && /^SPEND/.test(text(n)));
  assert.ok(th, 'a SPEND header');
  const order = () => all(root).filter((n) => n.localName === 'tr')
    .map((tr) => all(tr).find((a) => a.localName === 'a' && /^\/staff\//.test(a.attrs.href || '')))
    .filter(Boolean).map((a) => a.attrs.href.slice('/staff/'.length));
  fire(all(th).find((n) => n.localName === 'button'), 'click');
  await flush();
  assert.equal(th.attrs['aria-sort'], 'ascending');
  assert.deepEqual(order(), ['quartermaster', 'clerk', 'archie', 'watchman']);
  fire(all(th).find((n) => n.localName === 'button'), 'click');
  await flush();
  assert.equal(th.attrs['aria-sort'], 'descending');
  assert.deepEqual(order(), ['archie', 'clerk', 'quartermaster', 'watchman']);
});

// ------------------------------------------------------------------ C3
const EMPTY_ACTIVITY = { agent: 'archie', events: [], next: null, last_tick: null, cost_status: 'ok' };
const detail = (agent, over = {}) => render(h(AgentDetailView, {
  agent, roster: ok(ROSTER), findings: ok({ agent, findings: [], truncated: false }), activity: ok(EMPTY_ACTIVITY), ...over
}));
const factsOf = (out) => out.slice(0, out.indexOf('>ACTIVITY</span>'));

test('C3: /staff/archie shows SPEND TODAY and SPEND 7D, each a link to /costs?agent=archie', () => {
  const facts = factsOf(detail('archie'));
  assert.match(facts, /<dt>SPEND TODAY<\/dt><dd><a href="\/costs\?agent=archie"[^>]*>\$1\.50<\/a>/);
  assert.match(facts, /<dt>SPEND 7D<\/dt><dd><a href="\/costs\?agent=archie"[^>]*>\$3\.25<\/a>/);
  const zero = factsOf(detail('quartermaster'));
  assert.match(zero, /<dt>SPEND TODAY<\/dt><dd><a href="\/costs\?agent=quartermaster"[^>]*>\$0\.00<\/a>/);
  const none = factsOf(detail('watchman', { roster: ok(UNREAD) }));
  assert.match(none, /<dt>SPEND TODAY<\/dt><dd><span class="na" title="unread">n\/a<\/span>/);
  assert.match(none, /<dt>SPEND 7D<\/dt><dd><span class="na" title="unread">n\/a<\/span>/);
});

// ------------------------------------------------------------------ C4
const PR = 'https://github.com/example-org/cromford/pull/12';
const turn = (id, over = {}) => ({
  kind: 'turn', ts: '2026-11-06T05:00:00Z', id, cursor: `2026-11-06T05:00:00Z~turn~${id}`, trigger: 'telegram',
  summary: 'Filed BH-1 and BH-2', link_url: PR, outcome: 'answered', duration_s: 95,
  cost_run_id: `staff-turn:archie-turn-1-${id}`, cost: { cost_usd: 0.15, rows: 2, unpriced: 1 }, ...over
});

test('C4: a turn row shows turn · telegram, the summary, the PR link, the duration and its cost', () => {
  const activity = ok({ ...EMPTY_ACTIVITY, events: [turn(9), turn(8, { cost: null, link_url: null, trigger: 'sweep', outcome: 'acted' })] });
  const out = detail('archie', { activity });
  const act = out.slice(out.indexOf('>ACTIVITY</span>'), out.indexOf('>OPEN FINDINGS</span>'));
  assert.equal(bodyRows(act), 2);
  assert.match(act, /turn · telegram/);
  assert.match(act, /turn · sweep/);
  assert.match(act, /Filed BH-1 and BH-2/);
  assert.match(act, new RegExp(`<a href="${PR}" target="_blank" rel="noopener">#12</a>`));
  assert.match(act, /answered/);
  assert.match(act, /1m 35s/);
  assert.match(act, /\$0\.15\d*\s*<span class="na">\+1 unpriced<\/span>/);
  // A turn with no cost row reads n/a, never a dash that hides it.
  assert.match(act, /title="no cost row for this turn"[^>]*>n\/a</);
});

// ------------------------------------------------------------------ C5
test('C5: the agent section lists only that agent\'s lanes and links to all lanes', () => {
  const { AgentLaneSpendView } = agentSpend;
  const out = render(h(AgentLaneSpendView, { agent: 'archie', data: [ROSTER, LANES], error: null, loading: false, reload() {} }));
  assert.match(out, /ARCHIE · LANE SPEND · TODAY \(UTC\)/);
  assert.equal(bodyRows(out), 2);
  assert.match(out, /orc-monitor/);
  assert.doesNotMatch(out, /cost-reconcile/);
  assert.match(out, /<a href="\/costs"[^>]*>show all lanes<\/a>/);
  assert.match(out, /\$1\.50/);
  assert.match(out, /\$3\.25/);
  // Sortable headers: the shared table.
  assert.match(out, /aria-sort="descending"/);
});

// ------------------------------------------------------------------ C6
test('C6: an agent not on the roster is "no agent"; a bad name is refused with no request', async () => {
  const { AgentLaneSpendView, AgentLaneSpendSection } = agentSpend;
  const out = render(h(AgentLaneSpendView, { agent: 'nobody', data: [ROSTER, LANES], error: null, loading: false, reload() {} }));
  assert.match(out, /no agent nobody on the roster/);
  assert.equal(bodyRows(out), 0);

  const calls = routedFetch(ROUTE());
  const root = await mountNode(h(AgentLaneSpendSection, { agent: '../x' }));
  assert.match(text(root), /not an agent name/);
  assert.equal(calls.length, 0);
});

// ------------------------------------------------------------------ C7
test('C7: a failed read is an ErrorBox with RETRY, never the empty state', async () => {
  const { AgentLaneSpendView, AgentLaneSpendSection } = agentSpend;
  const out = render(h(AgentLaneSpendView, { agent: 'archie', ...failed('lane spend down') }));
  assert.match(out, /lane spend down/);
  assert.match(out, />RETRY</);
  assert.doesNotMatch(out, /no agent|no lane spend/);

  const calls = routedFetch(ROUTE(ROSTER, null));
  const root = await mountNode(h(AgentLaneSpendSection, { agent: 'archie' }));
  assert.match(text(root), /lane spend down/);
  assert.ok(all(root).some((n) => n.localName === 'button' && text(n) === 'RETRY'));
  assert.equal(calls.filter((c) => c.method === 'GET').length, 2, 'the roster and the lane spend, one request each');
});

// ------------------------------------------------------------------ C8
test('C8: entry point: the roster SPEND link opens COSTS filtered to that agent', async () => {
  const href = (rosterView().match(/<a href="(\/costs\?agent=archie)"/) || [])[1];
  assert.equal(href, '/costs?agent=archie');
  const [path, search] = href.split('?');
  window.location.pathname = path;
  window.location.search = `?${search}`;
  try {
    routedFetch(ROUTE());
    const hit = ROUTES.map(([p, C]) => [matchRoute(p, path), C]).find(([params]) => params);
    assert.ok(hit, 'a route matches /costs');
    const root = await mountNode(h(hit[1], hit[0]));
    const sec = sectionOf(root, 'ARCHIE · LANE SPEND · TODAY (UTC)');
    assert.ok(sec, 'the filtered section is on /costs?agent=archie');
    const lanes = all(sec).filter((n) => n.localName === 'tr').length - 1;
    assert.equal(lanes, 2);
    assert.doesNotMatch(text(sec), /cost-reconcile/);
    // The unfiltered section is still below it.
    assert.ok(sectionOf(root, 'LANE SPEND · TODAY (UTC)'));
  } finally {
    window.location.pathname = '/staff';
    window.location.search = '';
  }
});
