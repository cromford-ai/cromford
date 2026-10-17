// BH-6973 (BH-6546.3): the Components screen, the Alerts `component=` filter
// and the per-alert decisions screen.
//
// Fixtures are the wire shapes of GET /api/alerts (worker/jobs/README.md,
// BH-6971 `component`) and GET /api/alerts/decisions
// (worker/jobs/src/routes/alert-decisions.js: { decisions, truncated, as_of },
// rows newest first). The pure half (lib/components.js) is driven directly,
// the views are rendered to a string, and the routed AlertsScreen and
// ComponentsScreen are mounted into the shared fake DOM against a stubbed fetch,
// so every read goes through the real api.js.

import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

globalThis.window = globalThis.window || {
  location: { pathname: '/components', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  matchMedia() { return { matches: false, addEventListener() {}, removeEventListener() {} }; }
};

const { installDom, routedFetch, all } = await import('./helpers/fake-dom.bh-5750.js');
const { render } = await import('preact-render-to-string');
const { api } = await import('../src/api.js');
const { sortRows } = await import('../src/lib/sort.js');
const { filterHref } = await import('../src/lib/alertrows.js');
const {
  componentNames, shapeComponentRow, componentAlertsHref, decisionsHref, countLabel, countSortValue
} = await import('../src/lib/components.js');
const { ComponentsView, AlertDecisionsView, componentColumns } = await import('../src/screens/Components.js');
const { FleetRowsSection } = await import('../src/screens/Alerts.js');
const { ROUTES, FleetContext } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');

// determinism: ok every age and window in this file is measured from this literal epoch, never the wall clock.
const NOW = Date.parse('2026-10-17T12:00:00Z');
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (s) => iso(NOW - s * 1000);
const H24 = 24 * 3600;

const alert = (id, component, over = {}) => ({
  id, family: 'fam1', box: 'hub', project: '', line: `line of ${id}`, severity: 'warn',
  first_seen: ago(3600), last_seen: ago(60), count: 1, state: 'new',
  claimed_by: null, claimed_at: null, notified_at: null, component, ...over
});
const decision = (n, over = {}) => ({
  id: n, alert_id: 'a.1', component: 'triage', run_id: `run-${n}`, verdict: 'park', until: null,
  reason: `reason ${n}`, title: null, outcome: 'applied', issue: null, at: ago(60), ...over
});

const paramsOf = (url) => new URL(url, 'https://console.test').searchParams;

function captureFetch(body = { alerts: [], truncated: false }) {
  const calls = [];
  globalThis.fetch = async (url) => {
    calls.push(String(url));
    return { ok: true, status: 200, text: async () => JSON.stringify(body) };
  };
  return calls;
}

let mounted = null;
afterEach(() => { if (mounted) { mount(null, mounted); mounted = null; } });

// --- T1: api.js -------------------------------------------------------------

test('C1 api.alerts sends component with the other filters', async () => {
  const calls = captureFetch();
  await api.alerts({ state: '!resolved', component: 'triage', limit: 500 });
  assert.equal(calls.length, 1);
  const u = calls[0];
  assert.ok(u.startsWith('/api/coord/alerts?'), u);
  const q = paramsOf(u);
  assert.equal(q.get('state'), '!resolved');
  assert.equal(q.get('component'), 'triage');
  assert.equal(q.get('limit'), '500');
  // A caller with no component sends no component key (the old URL, unchanged).
  await api.alerts({ state: 'new', family: 'abc' });
  assert.equal(calls[1], '/api/coord/alerts?state=new&family=abc');
});

test('C2 api.alertDecisions reads /api/coord/alerts/decisions by component or by alert id', async () => {
  const calls = captureFetch({ decisions: [], truncated: false });
  await api.alertDecisions({ component: 'triage', limit: 200 });
  await api.alertDecisions({ alert_id: 'a.1' });
  assert.equal(calls[0], '/api/coord/alerts/decisions?component=triage&limit=200');
  // `limit` rides only when given: the worker owns the default.
  assert.equal(calls[1], '/api/coord/alerts/decisions?alert_id=a.1');
});

test('C3 api.alertDecisions refuses zero or two keys before any fetch', async () => {
  const calls = captureFetch();
  await assert.rejects(() => api.alertDecisions({}));
  await assert.rejects(() => api.alertDecisions({ alert_id: 'a', component: 'b' }));
  await assert.rejects(() => api.alertDecisions());
  assert.equal(calls.length, 0, 'no request was spent');
});

// --- T2: lib/components.js ---------------------------------------------------

test('C4 componentNames: distinct sorted names, null is unstamped, truncated kept', () => {
  const p = {
    alerts: [alert('x1', 'triage'), alert('x2', 'alerts-groom'), alert('x3', 'triage'), alert('x4', null),
      alert('x5', null), alert('x6', 'unowned')],
    truncated: true
  };
  const n = componentNames(p);
  assert.deepEqual(n.names, ['alerts-groom', 'triage', 'unowned']);
  assert.equal(n.unstamped, 2);
  assert.equal(n.truncated, true);
  assert.ok(!n.names.includes('null'));
  assert.equal(componentNames({ alerts: [alert('y', 'triage')] }).truncated, false, 'a missing field is not truncated');
  assert.deepEqual(componentNames(null), { names: [], unstamped: 0, truncated: false });
});

test('C5 lastRunAt is the newest `at` whatever the order; null with no rows; unparsable skipped', () => {
  const rows = [decision(1, { at: ago(7200) }), decision(2, { at: ago(30) }), decision(3, { at: 'not-a-date' }),
    decision(4, { at: ago(600) })];
  const r = shapeComponentRow('triage', { alerts: [] }, { decisions: rows, truncated: false }, NOW);
  assert.equal(r.lastRunAt, ago(30));
  assert.equal(shapeComponentRow('triage', { alerts: [] }, { decisions: [], truncated: false }, NOW).lastRunAt, null);
  const only = shapeComponentRow('t', { alerts: [] }, { decisions: [decision(1, { at: 'garbage' })] }, NOW);
  assert.equal(only.lastRunAt, null, 'an unparsable at is never the last run');
});

test('C6 decisions in 24 h counts rows inside NOW-24h only (edge: exactly 24 h counts)', () => {
  const rows = [
    decision(1, { at: ago(1) }),
    decision(2, { at: ago(H24) }),
    decision(3, { at: ago(H24 + 1) }),
    decision(4, { at: 'nope' }),
    decision(5, { at: ago(3 * H24) })
  ];
  const r = shapeComponentRow('triage', { alerts: [] }, { decisions: rows, truncated: false }, NOW);
  assert.equal(r.decisions24h, 2);
  assert.equal(r.decisions24hMore, false);
});

test('C7 "200+" only when truncated AND the oldest returned row is still inside 24 h', () => {
  const inside = Array.from({ length: 200 }, (_, i) => decision(i, { at: ago(60 + i) }));
  const a = shapeComponentRow('t', { alerts: [] }, { decisions: inside, truncated: true }, NOW);
  assert.equal(a.decisions24hMore, true);
  assert.equal(countLabel(a.decisions24h, a.decisions24hMore), '200+');

  // Three today and the rest two days old: the 24 h count is exact.
  const mixed = [...Array.from({ length: 3 }, (_, i) => decision(i, { at: ago(60 + i) })),
    ...Array.from({ length: 197 }, (_, i) => decision(10 + i, { at: ago(2 * H24 + i) }))];
  const b = shapeComponentRow('t', { alerts: [] }, { decisions: mixed, truncated: true }, NOW);
  assert.equal(b.decisions24hMore, false);
  assert.equal(countLabel(b.decisions24h, b.decisions24hMore), 3);

  const c = shapeComponentRow('t', { alerts: [] }, { decisions: inside.slice(0, 5), truncated: false }, NOW);
  assert.equal(countLabel(c.decisions24h, c.decisions24hMore), 5);
});

test('C8 tickets filed: verdict ticket with a non-null issue only', () => {
  const rows = [
    decision(1, { verdict: 'ticket', issue: 42 }),
    decision(2, { verdict: 'ticket', issue: 7 }),
    decision(3, { verdict: 'ticket', issue: null }),
    decision(4, { verdict: 'escalate', issue: 42 }),
    decision(5, { verdict: 'Ticket', issue: 9 })
  ];
  const r = shapeComponentRow('t', { alerts: [] }, { decisions: rows, truncated: false }, NOW);
  assert.equal(r.tickets, 2);
  assert.equal(r.ticketsMore, false);
  const t = shapeComponentRow('t', { alerts: [] }, { decisions: rows, truncated: true }, NOW);
  assert.equal(countLabel(t.tickets, t.ticketsMore), '2+', 'a truncated read is a lower bound');
});

// --- T3: the screen -----------------------------------------------------------

const ok = (data) => ({ data, error: null, loading: false, reload() {} });
const FIXTURE = {
  names: { names: ['alerts-groom', 'big', 'broken', 'triage'], unstamped: 2, truncated: false },
  components: [
    { name: 'alerts-groom', alerts: { alerts: [alert('g1', 'alerts-groom')], truncated: false },
      decisions: { decisions: [decision(1, { at: ago(90), component: 'alerts-groom' })], truncated: false } },
    { name: 'big', alerts: { alerts: Array.from({ length: 500 }, (_, i) => alert(`b${i}`, 'big')), truncated: true },
      decisions: { decisions: [], truncated: false } },
    { name: 'broken', alertsError: 'http_502', decisionsError: 'http_502' },
    { name: 'triage', alerts: { alerts: Array.from({ length: 7 }, (_, i) => alert(`t${i}`, 'triage')), truncated: false },
      decisions: { decisions: [decision(1, { verdict: 'ticket', issue: 42 }), decision(2, { at: ago(2 * H24) })], truncated: false } }
  ]
};
const viewHtml = (over = {}) => render(h(ComponentsView, { ...ok(FIXTURE), nowMs: NOW, ...over }));
const tbodyOf = (s) => s.slice(s.indexOf('<tbody>'), s.indexOf('</tbody>'));

test('C9 a row whose read failed renders —, never 0', () => {
  const out = viewHtml();
  const rows = tbodyOf(out).split('<tr').slice(1);
  const broken = rows.find((r) => r.includes('>broken<'));
  assert.ok(broken, 'the broken component still has a row');
  assert.ok(!/>0</.test(broken), `no 0 in a failed row: ${broken}`);
  assert.equal((broken.match(/class="na"/g) || []).length, 4, 'all four counted cells say —');
  assert.match(broken, /title="http_502"/);
});

test('C14 ComponentsView renders the fixture: five sortable headers, aria-sort on OPEN', () => {
  const out = viewHtml();
  assert.match(out, /class="line-headline"/);
  for (const label of ['COMPONENT', 'OPEN', 'LAST RUN', 'DECISIONS 24H', 'TICKETS']) {
    assert.match(out, new RegExp(`<button type="button"[^>]*title="sort by ${label.toLowerCase()}"[^>]*>\\s*${label}`), label);
  }
  assert.equal((out.match(/aria-sort="descending"/g) || []).length, 1);
  assert.match(out, /<th aria-sort="descending"[^>]*>\s*<button[^>]*>\s*OPEN/);
  assert.match(out, /2 alerts have no component yet/);
  // The cells: 7 open, "500+", the ticket counted, decisions 24 h exact.
  const triage = tbodyOf(out).split('<tr').find((r) => r.includes('>triage<'));
  assert.match(triage, />7</);
  assert.match(tbodyOf(out), />500\+</);
});

test('C14b the empty, loading and failed states are distinct', () => {
  const empty = viewHtml({ data: { names: { names: [], unstamped: 0, truncated: false }, components: [] } });
  assert.match(empty, /no component holds an open alert/);
  const loading = viewHtml({ data: null, loading: true });
  assert.match(loading, /Reading the components\./);
  assert.ok(!/no component holds/.test(loading));
  const failed = viewHtml({ data: null, loading: false, error: new Error('http_503') });
  assert.match(failed, /could not load/);
  assert.match(failed, /http_503/);
  assert.ok(!/no component holds/.test(failed));
  const capped = viewHtml({ data: { ...FIXTURE, names: { ...FIXTURE.names, truncated: true } } });
  assert.match(capped, /newest 500 open alerts/);
});

test('C15 sort by open alerts: OPEN desc by default, "500+" above 7; flipping asc reverses', () => {
  const out = viewHtml();
  const order = [...tbodyOf(out).matchAll(/href="\/alerts\?component=([a-z-]+)" class="cell-name"/g)].map((m) => m[1]);
  assert.deepEqual(order, ['big', 'triage', 'alerts-groom', 'broken']);
  const rows = FIXTURE.components.map((c) => shapeComponentRow(c.name, c.alerts, c.decisions, NOW,
    { alertsError: c.alertsError, decisionsError: c.decisionsError }));
  const open = componentColumns(NOW).find((c) => c.key === 'open');
  assert.deepEqual(sortRows(rows, open.sort, 'asc').map((r) => r.name), ['alerts-groom', 'triage', 'big', 'broken']);
  assert.ok(countSortValue(500, true) > countSortValue(500, false), '"500+" sorts above 500');
});

test('C16 every component row links to /alerts?component=<name>', () => {
  const out = tbodyOf(viewHtml());
  for (const n of ['alerts-groom', 'big', 'broken', 'triage']) {
    assert.ok(out.includes(`<a href="/alerts?component=${n}" class="cell-name">${n}</a>`), n);
  }
  assert.equal(componentAlertsHref('a b'), '/alerts?component=a%20b');
});

// --- T4: the Alerts filter ------------------------------------------------------

test('C10 filterHref keeps component; other hrefs unchanged', () => {
  assert.equal(filterHref({ component: 'triage' }), '?component=triage');
  assert.equal(filterHref({ family: 'f' }), '?family=f');
  assert.equal(filterHref({}), '/alerts');
  assert.equal(filterHref({ family: 'f', component: 'triage' }), '?family=f&component=triage');
});

test('C11 /alerts?component=triage asks the worker for triage rows and shows only them', async () => {
  const doc = installDom();
  window.location.pathname = '/alerts';
  window.location.search = '?component=triage';
  const fleetRows = [alert('t1', 'triage'), alert('t2', 'triage'), alert('g1', 'alerts-groom'), alert('tt', 'triage-2')];
  const calls = routedFetch((u) => {
    if (!u.startsWith('/api/coord/alerts')) return [200, {}];
    const c = paramsOf(u).get('component');
    // The worker matches exactly: triage-2 is not triage.
    return [200, { alerts: fleetRows.filter((r) => !c || r.component === c), truncated: false, as_of: iso(NOW) }];
  });
  const hit = ROUTES.map(([p, C]) => [matchRoute(p, '/alerts'), C]).find(([params]) => params);
  const root = doc.createElement('div');
  mount(h(FleetContext.Provider, { value: ok({ projects: [] }) }, h(hit[1], hit[0])), root);
  mounted = root;
  await flush();
  const alertsCalls = calls.filter((c) => c.url.startsWith('/api/coord/alerts'));
  assert.equal(alertsCalls.length, 1, alertsCalls.map((c) => c.url).join(' '));
  assert.equal(paramsOf(alertsCalls[0].url).get('component'), 'triage');
  const text = root.textContent;
  assert.match(text, /component=triage/, 'the chip names the filter');
  // The FLEET ROWS id cells, read from the tree: exactly the triage rows.
  const ids = all(root).filter((n) => n.localName === 'button' && (n.attrs.class || '').split(/\s+/).includes('cell-name'))
    .map((n) => n.textContent.trim());
  assert.deepEqual(ids.sort(), ['t1', 't2'], 'g1 and the near-miss triage-2 are not listed');
  assert.match(text, /2 rows/);
  const hrefs = all(root).filter((n) => n.localName === 'a').map((n) => n.attrs.href);
  assert.ok(hrefs.includes('/alerts/decisions/t1'));
  assert.ok(hrefs.includes('/components'), 'the Components screen is reachable from Alerts');
  window.location.search = '';
});

const shapedRows = { rows: [{ ...alert('a.1', 'triage'), stateRank: 0 }, { ...alert('a/2', 'triage'), stateRank: 0 }], truncated: false, asOf: null };

test('C12 FleetRowsSection with no component filter renders no DECISIONS column', () => {
  const out = render(h(FleetRowsSection, { shaped: shapedRows, filters: { family: 'fam1' }, nowMs: NOW }));
  assert.ok(!/DECISIONS/.test(out));
  assert.ok(!/\/alerts\/decisions\//.test(out));
});

test('C17 FleetRowsSection with filters.component links each row to its decisions', () => {
  const out = render(h(FleetRowsSection, { shaped: shapedRows, filters: { component: 'triage' }, nowMs: NOW }));
  assert.match(out, />DECISIONS</);
  assert.ok(out.includes('href="/alerts/decisions/a.1"'));
  assert.ok(out.includes('href="/alerts/decisions/a%2F2"'));
});

// --- T5: routes -------------------------------------------------------------------

test('C13 ROUTES resolves /components and /alerts/decisions/:id, and the id round-trips', () => {
  const find = (path) => ROUTES.map(([p, C]) => [matchRoute(p, path), C]).find(([params]) => params);
  const c = find('/components');
  assert.ok(c);
  assert.equal(c[1].name, 'ComponentsScreen');
  const d = find(decisionsHref('a.1'));
  assert.ok(d);
  assert.equal(d[1].name, 'AlertDecisionsScreen');
  assert.deepEqual(d[0], { id: 'a.1' });
  assert.deepEqual(find(decisionsHref('a/2'))[0], { id: 'a/2' });
  // /alerts itself still opens the Alerts screen.
  assert.equal(find('/alerts')[1].name, 'AlertsScreen');
});

test('C13b the routed ComponentsScreen reads names first, then every component in one wave', async () => {
  const doc = installDom();
  window.location.pathname = '/components';
  window.location.search = '';
  const started = [];
  let release;
  const gate = new Promise((r) => { release = r; });
  globalThis.fetch = async (url) => {
    const u = String(url);
    started.push(u);
    const q = paramsOf(u);
    let body = {};
    if (u.startsWith('/api/coord/alerts/decisions')) {
      await gate; // no decisions read answers until every wave-2 read has started
      body = q.get('component') === 'triage'
        ? { decisions: [decision(1, { verdict: 'ticket', issue: 42 })], truncated: false }
        : { decisions: [], truncated: false };
    } else if (u.startsWith('/api/coord/alerts')) {
      const rows = [alert('t1', 'triage'), alert('t2', 'triage'), alert('g1', 'alerts-groom')];
      body = { alerts: q.get('component') ? rows.filter((r) => r.component === q.get('component')) : rows, truncated: false };
    }
    return { ok: true, status: 200, text: async () => JSON.stringify(body) };
  };
  const hit = ROUTES.map(([p, C]) => [matchRoute(p, '/components'), C]).find(([params]) => params);
  const root = doc.createElement('div');
  mount(h(FleetContext.Provider, { value: ok({ projects: [] }) }, h(hit[1], hit[0])), root);
  mounted = root;
  await flush();
  assert.equal(started.filter((u) => u.startsWith('/api/coord/alerts/decisions')).length, 2,
    `both decisions reads started before any answered: ${started.join(' ')}`);
  release();
  await flush();
  const hrefs = all(root).filter((n) => n.localName === 'a').map((n) => n.attrs.href);
  assert.ok(hrefs.includes('/alerts?component=triage'));
  assert.ok(hrefs.includes('/alerts?component=alerts-groom'));
  assert.match(root.textContent, /COMPONENTS/);
});

// --- the decisions screen ------------------------------------------------------------

const DECISIONS = {
  decisions: [
    decision(1, { verdict: 'ticket', issue: 42, at: ago(120), reason: 'needs a fix' }),
    decision(2, { verdict: 'park', issue: null, at: ago(3600) })
  ],
  truncated: true
};

test('C18 AlertDecisionsView renders decisions in a sortable table; issue links to /t/BH-<n>', () => {
  const out = render(h(AlertDecisionsView, { id: 'a.1', ...ok(DECISIONS), nowMs: NOW }));
  assert.match(out, /class="line-headline"/);
  assert.match(out, /Decisions · a\.1/);
  for (const label of ['AT', 'VERDICT', 'OUTCOME', 'ISSUE', 'RUN']) {
    assert.match(out, new RegExp(`title="sort by ${label.toLowerCase()}"`), label);
  }
  assert.ok(!/title="sort by reason"/.test(out), 'REASON is free text, not sortable');
  assert.ok(out.includes('href="/t/BH-42"'));
  const park = tbodyOf(out).split('<tr').find((r) => r.includes('run-2'));
  assert.match(park, /class="na">—</);
  assert.match(out, /showing the newest 200/);
  assert.ok(out.includes('href="/alerts?component=triage"'), 'a crumb back to the component');
  const empty = render(h(AlertDecisionsView, { id: 'a.1', ...ok({ decisions: [], truncated: false }), nowMs: NOW }));
  assert.match(empty, /no decisions recorded/);
});

// --- 375px -------------------------------------------------------------------------------

test('C19 375px: each table scrolls inside its own tablewrap, no wide table, no fixed width over 375px', () => {
  const outs = [viewHtml(), render(h(AlertDecisionsView, { id: 'a.1', ...ok(DECISIONS), nowMs: NOW }))];
  for (const out of outs) {
    const tables = (out.match(/<table/g) || []).length;
    assert.ok(tables >= 1);
    assert.equal((out.match(/<div class="tablewrap">\s*<table/g) || []).length, tables, 'every table sits in a tablewrap');
    assert.ok(!/tablewrap--wide/.test(out));
    for (const m of out.matchAll(/(?:min-)?width:\s*(\d+)px/g)) {
      assert.ok(Number(m[1]) <= 375, `fixed width ${m[0]}`);
    }
  }
});
