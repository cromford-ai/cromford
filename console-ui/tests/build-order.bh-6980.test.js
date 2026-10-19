// BH-6980 (BH-6547.4): the build-order graph in Mission Control.
//
// Fixtures are the wire shapes of the three reads the screen makes:
//   R1 GET /api/coord/scheduler/ready  (worker/jobs/src/routes/scheduler.js:
//      {ok, project, at, mode, candidates, complete, verdicts:[{ticket, ready, reason}]})
//   R2 GET /api/coord/ticket-edges     (worker/jobs/src/routes/ticket-edges.js:
//      {edges:[{id, project, parent, child, kind, source, verified_at, at}]}, LIMIT 500)
//   R3 GET /api/dash/kanban/pipeline   (the Kanban screen's read: {columns:{<col>:[card]}})
// The pure half (lib/build-order.js) is driven directly, the view is rendered to
// a string, and the routed screen is mounted into the shared fake DOM against a
// stubbed fetch, so every read goes through the real api.js.

import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

globalThis.window = globalThis.window || {
  location: { pathname: '/build-order', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  matchMedia() { return { matches: false, addEventListener() {}, removeEventListener() {} }; }
};

const { installDom, routedFetch, all, fire } = await import('./helpers/fake-dom.bh-5750.js');
const { render } = await import('preact-render-to-string');
const {
  ticketNumber, keyPrefix, nodeState, buildOrderGraph, ticketHref, prHref, EDGES_LIMIT
} = await import('../src/lib/build-order.js');
const { BuildOrderView } = await import('../src/screens/BuildOrder.js');
const { ROUTES, NAV, FleetContext } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');

const P = 'cromford';
// determinism: ok every timestamp in this file is a literal, never the wall clock.
const AT = '2026-10-18T21:00:00Z';

const v = (ticket, ready, reason = '') => ({ ticket, ready, reason });
const e = (parent, child, kind = 'hard') => ({
  id: parent * 1000 + child, project: P, parent, child, kind, source: 'body', verified_at: null, at: AT
});
let nextId = 1;
const card = (ticket, over = {}) => ({
  id: nextId++, project: P, ticket, stage: 'execute', pr_url: null, stage_why: null, ...over
});
const pipe = (cols) => ({ columns: { queued: [], building: [], merge_queue: [], review: [], merged_deployed: [], dead_failed: [], ...cols } });
const ready = (verdicts, over = {}) => ({
  ok: true, project: P, at: AT, mode: 'shadow', candidates: verdicts.length, complete: true, verdicts, ...over
});

const graphOf = ({ verdicts = [], edges = [], cols = {}, readyOver = {} }) =>
  buildOrderGraph({ ready: ready(verdicts, readyOver), edges: { edges }, pipeline: pipe(cols), project: P });
const nodeOf = (g, n) => g.nodes.find((x) => x.n === n);

let mounted = null;
afterEach(() => { if (mounted) { mount(null, mounted); mounted = null; } });

// --- T1: the node state rule ------------------------------------------------

test('B1 verdict yes and no card -> ready, empty reason', () => {
  const s = nodeState({ verdict: v(10, 'yes') });
  assert.equal(s.state, 'ready');
  assert.equal(s.label, 'ready');
  assert.equal(s.reason, '');
});

test('B2 verdict no "parent #6979 open" -> waiting, label "waiting on #6979", reason verbatim', () => {
  const s = nodeState({ verdict: v(6980, 'no', 'parent #6979 open') });
  assert.equal(s.state, 'waiting');
  assert.equal(s.label, 'waiting on #6979');
  assert.equal(s.reason, 'parent #6979 open');
});

test('B3 the other no reasons stay verbatim; a #N that is not a parent gives no "waiting on"', () => {
  for (const reason of ['hold by operator', 'files claimed by #12', 'wip cap', 'parent #x open']) {
    const s = nodeState({ verdict: v(1, 'no', reason) });
    assert.equal(s.state, 'waiting', reason);
    assert.equal(s.reason, reason, reason);
    assert.equal(s.label, 'waiting', `${reason}: no "waiting on #" label`);
  }
});

test('B4 card columns: building, review, merge_queue, queued, merged_deployed; most advanced wins', () => {
  const g = graphOf({
    verdicts: [v(1, 'yes'), v(2, 'yes'), v(3, 'yes'), v(4, 'yes'), v(5, 'yes'), v(6, 'yes')],
    cols: {
      building: [card('BH-1')],
      review: [card('BH-2'), card('BH-6')],
      merge_queue: [card('BH-3')],
      queued: [card('BH-4')],
      merged_deployed: [card('BH-5'), card('BH-6')]
    }
  });
  assert.equal(nodeOf(g, 1).state, 'building');
  assert.equal(nodeOf(g, 2).state, 'review');
  assert.equal(nodeOf(g, 3).state, 'queued');
  assert.equal(nodeOf(g, 3).reason, 'in the merge queue');
  assert.equal(nodeOf(g, 4).state, 'queued');
  assert.equal(nodeOf(g, 4).reason, 'waiting for a build slot');
  assert.equal(nodeOf(g, 5).state, 'merged');
  assert.equal(nodeOf(g, 6).state, 'merged', 'review AND merged_deployed -> merged');
  // A card's stage_why is the reason when the verdict has none.
  const w = graphOf({ verdicts: [v(7, 'yes')], cols: { building: [card('BH-7', { stage_why: 'review round 2' })] } });
  assert.equal(nodeOf(w, 7).reason, 'review round 2');
});

test('B5 a dead_failed card does not set the state: the verdict does', () => {
  const g = graphOf({ verdicts: [v(8, 'no', 'hold by operator')], cols: { dead_failed: [card('BH-8')] } });
  assert.equal(nodeOf(g, 8).state, 'waiting');
  assert.equal(nodeOf(g, 8).reason, 'hold by operator');
});

test('B6 a parent only on an edge -> unknown, never merged; in-flight -> building; unknown -> unknown', () => {
  const g = graphOf({ verdicts: [v(20, 'no', 'parent #19 open')], edges: [e(19, 20)] });
  const p = nodeOf(g, 19);
  assert.equal(p.state, 'unknown');
  assert.equal(p.reason, 'not in the ready set and no recent build');
  assert.ok(!g.nodes.some((x) => x.state === 'merged'), 'no merged card, so nothing is merged');
  const f = nodeState({ verdict: v(1, 'in-flight', '') });
  assert.equal(f.state, 'building');
  assert.equal(f.reason, 'build in flight');
  const u = nodeState({ verdict: v(1, 'unknown', 'parent #3 unreadable') });
  assert.equal(u.state, 'unknown');
  assert.equal(u.reason, 'parent #3 unreadable');
  // The verdict reason is kept even when a card sets the state.
  const r = graphOf({ verdicts: [v(21, 'in-flight', 'claimed by a lane')], cols: { review: [card('BH-21')] } });
  assert.equal(nodeOf(r, 21).state, 'review');
  assert.equal(nodeOf(r, 21).reason, 'claimed by a lane');
});

test('B7 layers: a chain, a diamond (longest path) and a cycle that terminates', () => {
  const chain = graphOf({ verdicts: [v(1, 'yes'), v(2, 'yes'), v(3, 'yes')], edges: [e(1, 2), e(2, 3)] });
  assert.deepEqual([1, 2, 3].map((n) => nodeOf(chain, n).depth), [0, 1, 2]);
  assert.deepEqual(chain.layers.map((l) => l.map((x) => x.n)), [[1], [2], [3]]);
  assert.deepEqual(nodeOf(chain, 3).parents, [{ n: 2, kind: 'hard' }]);

  // 1 -> 2 -> 4 and 1 -> 4 (soft): 4 sits after 2, not beside it.
  const diamond = graphOf({ verdicts: [v(1, 'yes'), v(2, 'yes'), v(3, 'yes'), v(4, 'yes')],
    edges: [e(1, 2), e(1, 3), e(2, 4), e(1, 4, 'soft')] });
  assert.equal(nodeOf(diamond, 4).depth, 2);
  assert.deepEqual(diamond.layers[1].map((x) => x.n), [2, 3], 'ascending inside a layer');
  assert.deepEqual(nodeOf(diamond, 4).parents, [{ n: 1, kind: 'soft' }, { n: 2, kind: 'hard' }]);

  const cyc = graphOf({ verdicts: [v(4, 'yes'), v(5, 'yes')], edges: [e(4, 5), e(5, 4)] });
  assert.ok(cyc.nodes.every((x) => x.depth <= cyc.nodes.length), 'depth is capped');
  assert.ok(nodeOf(cyc, 4).cycle && nodeOf(cyc, 5).cycle, 'both cycle members are marked');
  assert.match(nodeOf(cyc, 4).reason, /cycle/);
});

test('B8 key prefix from this project\'s cards; another project is ignored; no card -> #n, no /t/ href', () => {
  assert.equal(ticketNumber(card('BH-6980')), 6980);
  assert.equal(ticketNumber(card('no-digits')), null);
  assert.equal(ticketNumber(6980), 6980);
  assert.equal(keyPrefix([card('BH-1')], P), 'BH');
  assert.equal(keyPrefix([card('TK-1', { project: 'project-3' })], P), null);

  const g = graphOf({ verdicts: [v(30, 'yes'), v(31, 'yes')], cols: { review: [card('BH-30')] } });
  assert.equal(nodeOf(g, 31).key, 'BH-31');
  assert.equal(ticketHref(nodeOf(g, 31)), '/t/BH-31');

  // A card for project-3 #40 must not set the state of cromford #40.
  const x = graphOf({ verdicts: [v(40, 'yes')], cols: { merged_deployed: [card('TK-40', { project: 'project-3' })] } });
  assert.equal(nodeOf(x, 40).state, 'ready');
  assert.equal(nodeOf(x, 40).key, null);
  assert.equal(ticketHref(nodeOf(x, 40)), null);
  // A card with no trailing digits joins nothing.
  const y = graphOf({ verdicts: [v(41, 'yes')], cols: { review: [card('BH-')] } });
  assert.equal(nodeOf(y, 41).state, 'ready');
});

test('B9 500 edges -> edgesTruncated; complete:false is carried for the partial line', () => {
  const edges = Array.from({ length: EDGES_LIMIT }, (_, i) => e(1000 + i, 2000 + i));
  const g = graphOf({ verdicts: [v(1, 'yes')], edges });
  assert.equal(EDGES_LIMIT, 500);
  assert.equal(g.edgesTruncated, true);
  assert.equal(graphOf({ verdicts: [v(1, 'yes')], edges: edges.slice(1) }).edgesTruncated, false);
  const p = graphOf({ verdicts: [v(1, 'yes')], readyOver: { candidates: 3, complete: false } });
  assert.deepEqual(p.tick, { at: AT, mode: 'shadow', candidates: 3, complete: false, verdicts: 1 });
  const out = render(h(BuildOrderView, viewProps({ ready: { d: ready([v(1, 'yes')], { candidates: 3, complete: false }) } })));
  assert.match(out, /1 of 3 verdicts · partial/);
});

// --- the screen fixture --------------------------------------------------------

const FIX_READY = ready([
  v(6977, 'yes'),
  v(6979, 'in-flight', ''),
  v(6980, 'no', 'parent #6979 open'),
  v(6981, 'no', 'hold by operator'),
  v(6982, 'no', 'files claimed by #6977')
]);
const FIX_EDGES = { edges: [e(6977, 6979), e(6978, 6979), e(6979, 6980), e(6977, 6982, 'soft')] };
const FIX_PIPE = pipe({
  review: [card('BH-6979', { pr_url: 'https://github.com/example-org/cromford/pull/7297' })],
  merged_deployed: [card('BH-6978', { pr_url: 'https://github.com/example-org/cromford/pull/7049' })]
});

function viewProps(over = {}) {
  return {
    project: P, projects: [P, 'project-3'], loading: false, error: null,
    data: { ready: { d: FIX_READY }, edges: { d: FIX_EDGES }, pipeline: { d: FIX_PIPE }, ...over }
  };
}
const viewHtml = (over) => render(h(BuildOrderView, viewProps(over)));
const graphHtml = (s) => {
  const i = s.indexOf('data-testid="build-order-graph"');
  return i < 0 ? '' : s.slice(i, s.indexOf('data-testid="build-order-list"'));
};

test('B11 renders the fixture graph: every node shows its key, state and reason', () => {
  const out = viewHtml();
  const g = graphHtml(out);
  assert.ok(g, 'the graph section renders');
  assert.match(out, /tick 2026-10-18T21:00:00Z · mode shadow · 5 of 5 verdicts/);
  const nodes = g.split('data-testid="bo-node"').slice(1);
  assert.equal(nodes.length, 6, 'five verdicts plus the edge-only parent 6978');
  const of = (n) => nodes.find((x) => x.includes(`data-ticket="${n}"`));
  assert.match(of(6977), />BH-6977</); assert.match(of(6977), />ready</);
  assert.match(of(6978), />merged</);
  assert.match(of(6979), />review</); assert.match(of(6979), />build in flight</);
  assert.match(of(6980), />waiting on #6979</); assert.match(of(6980), />parent #6979 open</);
  assert.match(of(6981), />hold by operator</);
  assert.match(of(6982), />files claimed by #6977</);
  assert.match(of(6980), /after/); assert.match(of(6980), /href="\/t\/BH-6979"/);
  assert.match(of(6982), /soft/);
  // Three layers: 6977/6978/6981 -> 6979/6982 -> 6980.
  assert.equal((g.match(/data-testid="bo-layer"/g) || []).length, 3);
});

test('B13 empty and failure states: no tick, a failed edges read, zero candidates, a failed ready read', () => {
  const noTick = viewHtml({ ready: { d: { ok: true, project: P, at: null, complete: false, verdicts: [] } }, edges: { d: { edges: [] } } });
  assert.match(noTick, /the scheduler has not written a tick for cromford/);
  assert.ok(!graphHtml(noTick).includes('bo-node'));

  const noEdges = viewHtml({ edges: { e: 'http_503' } });
  assert.match(noEdges, /ticket edges unavailable: http_503/);
  assert.ok(graphHtml(noEdges).includes('bo-node'), 'the verdicts still render');
  assert.ok(!/root|no parent/i.test(graphHtml(noEdges)), 'no node claims it has no parent');

  const zero = viewHtml({ ready: { d: ready([]) }, edges: { d: { edges: [] } } });
  assert.match(zero, /no candidate ticket in the newest tick/);

  const noReady = viewHtml({ ready: { e: 'http_502' } });
  assert.match(noReady, /scheduler ready unavailable: http_502/);
  assert.ok(!graphHtml(noReady).includes('bo-node'), 'a failed ready read is never an empty or all-unknown graph');

  const noPipe = viewHtml({ pipeline: { e: 'http_500' } });
  assert.match(noPipe, /pipeline unavailable: http_500/);

  const loading = render(h(BuildOrderView, { ...viewProps(), data: null, loading: true }));
  assert.match(loading, /loading/);
  assert.ok(!/bo-node/.test(loading));

  const truncated = viewHtml({ edges: { d: { edges: Array.from({ length: 500 }, (_, i) => e(1 + i, 6977)) } } });
  assert.match(truncated, /showing the first 500 edges/);
});

test('B14 links resolve: ticket keys to /t/BH-<n>, PRs to /pr/cromford/<n>, both through ROUTES', () => {
  const out = viewHtml();
  const hrefs = [...out.matchAll(/href="([^"]+)"/g)].map((m) => m[1]);
  const find = (path) => ROUTES.map(([p, C]) => [matchRoute(p, path), C]).find(([params]) => params);
  for (const n of [6977, 6978, 6979, 6980, 6981, 6982]) {
    assert.ok(hrefs.includes(`/t/BH-${n}`), `BH-${n}`);
    const hit = find(`/t/BH-${n}`);
    assert.equal(hit[1].name, 'TicketScreen');
    assert.deepEqual(hit[0], { ticket: `BH-${n}` });
  }
  assert.ok(hrefs.includes('/pr/cromford/7297'));
  assert.ok(hrefs.includes('/pr/cromford/7049'));
  assert.deepEqual(find('/pr/cromford/7297')[0], { project: P, number: '7297' });
  assert.equal(prHref(P, 7297), '/pr/cromford/7297');
  assert.equal(prHref(P, null), null);
  // Every href on the screen opens a real route.
  for (const href of hrefs) assert.ok(find(href.split('?')[0]), `no route for ${href}`);
  // With no key prefix a node links to its project, never to /t/<nothing>.
  const bare = viewHtml({ pipeline: { d: pipe({}) } });
  assert.ok(!/href="\/t\//.test(bare));
  assert.match(bare, /href="\/p\/cromford"[^>]*>#6980</);
});

// --- mounted through the real api.js ---------------------------------------------

function mountRoute(doc, path, search, fleetProjects = [P, 'project-3']) {
  window.location.pathname = path;
  window.location.search = search;
  const hit = ROUTES.map(([p, C]) => [matchRoute(p, path), C]).find(([params]) => params);
  assert.ok(hit, `a route for ${path}`);
  const root = doc.createElement('div');
  const fleet = { data: { projects: fleetProjects }, error: null, loading: false, reload() {} };
  mount(h(FleetContext.Provider, { value: fleet }, h(hit[1], hit[0])), root);
  mounted = root;
  return root;
}
const fixtureRoute = (u) => (u.startsWith('/api/coord/scheduler/ready') ? [200, FIX_READY]
  : u.startsWith('/api/coord/ticket-edges') ? [200, FIX_EDGES]
    : u.startsWith('/api/dash/kanban/pipeline') ? [200, FIX_PIPE] : [200, {}]);

test('B10 the mounted screen makes exactly the three GETs, all started before any answers', async () => {
  const doc = installDom();
  const started = [];
  let release;
  const gate = new Promise((r) => { release = r; });
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    started.push({ u, method: init.method || 'GET' });
    await gate;
    const [status, body] = fixtureRoute(u);
    return { ok: status < 300, status, text: async () => JSON.stringify(body) };
  };
  const root = mountRoute(doc, '/build-order', '');
  await flush();
  assert.deepEqual(started.map((s) => s.u).sort(), [
    '/api/coord/scheduler/ready?project=cromford',
    '/api/coord/ticket-edges?project=cromford',
    '/api/dash/kanban/pipeline?project=cromford&shipped_limit=50'
  ], 'the first fleet project, three reads in flight together');
  release();
  await flush();
  assert.match(root.textContent, /waiting on #6979/);
  assert.equal(started.length, 3, 'no fourth read');
});

test('B12 ?project=project-3 moves all three reads to project-3', async () => {
  const doc = installDom();
  const calls = routedFetch((u) => [200, u.includes('ticket-edges') ? { edges: [] } : u.includes('scheduler') ? { ok: true, at: null, verdicts: [] } : pipe({})]);
  const root = mountRoute(doc, '/build-order', '?project=project-3');
  await flush();
  assert.equal(calls.length, 3, calls.map((c) => c.url).join(' '));
  for (const c of calls) assert.equal(new URL(c.url, 'https://x.test').searchParams.get('project'), 'project-3', c.url);
  assert.match(root.textContent, /has not written a tick for project-3/);
  window.location.search = '';
});

test('B15 sorts the list: TICKET asc by default, a click flips it to desc and aria-sort follows', async () => {
  const doc = installDom();
  routedFetch(fixtureRoute);
  const root = mountRoute(doc, '/build-order', '?project=cromford');
  await flush();
  const list = all(root).find((n) => n.attrs && n.attrs['data-testid'] === 'build-order-list');
  assert.ok(list, 'the list section');
  const order = () => all(list).filter((n) => n.localName === 'tr').slice(1)
    .map((tr) => Number((tr.textContent.match(/BH-(\d+)/) || [])[1]));
  const th = () => all(list).find((n) => n.localName === 'th' && /TICKET/.test(n.textContent));
  assert.deepEqual(order(), [6977, 6978, 6979, 6980, 6981, 6982]);
  assert.equal(th().attrs['aria-sort'], 'ascending');
  fire(all(th()).find((n) => n.localName === 'button'), 'click');
  await flush();
  assert.deepEqual(order(), [6982, 6981, 6980, 6979, 6978, 6977]);
  assert.equal(th().attrs['aria-sort'], 'descending');
  for (const label of ['STATE', 'REASON', 'AFTER', 'PR']) {
    assert.ok(all(list).some((n) => n.localName === 'th' && n.textContent.includes(label)), label);
  }
  window.location.search = '';
});

test('B16 /build-order is a route, the KANBAN tab lights on it, and Kanban links to it', async () => {
  const hit = ROUTES.find(([p]) => matchRoute(p, '/build-order'));
  assert.ok(hit);
  assert.equal(hit[1].name, 'BuildOrderScreen');
  const kanban = NAV.find((n) => n.label === 'KANBAN');
  assert.equal(kanban.match('/build-order'), true);
  assert.equal(kanban.match('/kanban'), true);
  assert.equal(NAV.filter((n) => n.match('/build-order')).length, 1, 'one tab lights');

  const doc = installDom();
  routedFetch(() => [200, pipe({})]);
  const root = mountRoute(doc, '/kanban', '');
  await flush();
  const hrefs = all(root).filter((n) => n.localName === 'a').map((n) => n.attrs.href);
  assert.ok(hrefs.includes('/build-order'), hrefs.join(' '));
});

test('B17 375px: the graph scrolls inside its own overflow-x:auto box; no fixed width over 375px', () => {
  const out = viewHtml();
  assert.match(out, /<div[^>]*style="[^"]*overflow-x:\s*auto[^"]*"[^>]*data-testid="build-order-graph"|data-testid="build-order-graph"[^>]*style="[^"]*overflow-x:\s*auto/);
  for (const m of out.matchAll(/(?:min-)?width:\s*(\d+)px/g)) {
    assert.ok(Number(m[1]) <= 375, `fixed width ${m[0]}`);
  }
  const styles = [...out.matchAll(/style="([^"]*)"/g)].map((m) => m[1]);
  assert.ok(styles.length > 0);
  for (const s of styles) assert.ok(!/#[0-9a-f]{3,8}\b|rgb\(/i.test(s), `a raw colour in style="${s}"`);
  // The list sits in SortableTable's own scroll wrap.
  assert.match(out, /<div class="tablewrap">\s*<table/);
});

test('B18 read-only: no button, form or input but the sort headers, and only GETs', async () => {
  const out = viewHtml();
  assert.ok(!/<form|<input|<select|<textarea/.test(out));
  const buttons = out.match(/<button[^>]*>/g) || [];
  assert.ok(buttons.length > 0);
  for (const b of buttons) assert.match(b, /title="sort by /, b);

  const doc = installDom();
  const calls = routedFetch(fixtureRoute);
  mountRoute(doc, '/build-order', '?project=cromford');
  await flush();
  assert.ok(calls.length > 0);
  assert.ok(calls.every((c) => c.method === 'GET'), calls.map((c) => c.method).join(' '));
  window.location.search = '';
});
