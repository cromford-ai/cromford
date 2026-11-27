import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

// BH-10231 (C1 of BH-9889): the BOX WATCH section of /staff/quartermaster.
// The view renders server-side; the section and the real agent page
// (AgentDetailView, what /staff/:agent shows) are mounted in the shared fake
// DOM against a stubbed fetch, so the read goes through the real api.js.
//   W1 rows render newest first; the box cell links to /machines?box=<box>
//   W2 every header sorts (click flips the order)
//   W3 loading = Skeleton, error = ErrorBox with RETRY, empty = the empty text
//   W4 the section reads GET /api/coord/box-watch/actions?limit=50 once
//   W5 entry point: /staff/quartermaster (AgentDetailView) shows the section;
//      /staff/clerk does not, and makes no box-watch read

globalThis.window = globalThis.window || {
  location: { pathname: '/staff/quartermaster', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {} }
};

const { installDom, routedFetch, all, fire, byTestId, rowsOf } = await import('./helpers/fake-dom.bh-5750.js');
const opt = (p) => import(p).catch(() => ({}));
const bw = await opt('../src/screens/staff/agent-box-watch.js');
const { AgentDetailView } = await import('../src/screens/Staff.js');
const { ROUTES } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const { render } = await import('preact-render-to-string');

const row = (id, box, acted_at, over = {}) => ({
  id, box, box_id: 'small', probes: 3, acted_at, outcome: 'back', restart_rc: 0, recovery_rc: 0,
  back_at: acted_at, detail: 'back after restart', ended_at: acted_at, ...over
});
const DATA = {
  actions: [
    row(3, 'box-small', '2026-11-26T14:00:00Z'),
    row(1, 'box-project-2', '2026-11-21T09:00:00Z', { outcome: 'refused', restart_rc: 2, recovery_rc: null, back_at: null, detail: 'not configured: ORGO_API_KEY unset' }),
    row(2, 'box-alpha', '2026-11-24T10:00:00Z', { outcome: 'still_dark', back_at: null })
  ],
  limit: 50, as_of: '2026-11-26T15:00:00Z'
};
const ok = (data) => ({ data, error: null, loading: false, reload() {} });
const text = (n) => n.textContent;

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
const ROUTE = (data = DATA) => (u) => {
  if (u.startsWith('/api/coord/box-watch/actions')) return data ? [200, data] : [500, { error: 'box watch down' }];
  return [404, { error: 'unknown endpoint' }];
};
const boxCells = (root) => rowsOf(root).map((tr) => all(tr).find((n) => n.localName === 'a')).filter(Boolean);

test('W1 rows render newest first; the box cell links to /machines?box=', async () => {
  assert.equal(typeof bw.AgentBoxWatchView, 'function', 'src/screens/staff/agent-box-watch.js exports AgentBoxWatchView');
  const out = render(h(bw.AgentBoxWatchView, { actions: ok(DATA) }));
  assert.match(out, /data-testid="agent-box-watch"/);
  assert.match(out, /BOX WATCH/);
  const order = [...out.matchAll(/box-(small|alpha|project-2)<\/a>/g)].map((m) => m[1]);
  assert.deepEqual(order, ['small', 'alpha', 'project-2'], 'newest first');
  assert.match(out, /href="\/machines\?box=box-small"/);
  assert.match(out, /still dark/);
  assert.match(out, /refused/);
});

test('W2 headers sort: a click on BOX orders by box, a second click flips it', async () => {
  routedFetch(ROUTE());
  const root = await mountNode(h(bw.AgentBoxWatchView, { actions: ok(DATA) }));
  const ths = all(root).filter((n) => n.localName === 'th');
  assert.ok(ths.length >= 7, `headers: ${ths.length}`);
  const boxBtn = all(root).find((n) => n.localName === 'button' && n.textContent.trim().startsWith('BOX'));
  assert.ok(boxBtn, 'BOX header is a sort button');
  fire(boxBtn, 'click'); await flush();
  assert.deepEqual(boxCells(root).map(text), ['box-alpha', 'box-small', 'box-project-2']);
  fire(boxBtn, 'click'); await flush();
  assert.deepEqual(boxCells(root).map(text), ['box-project-2', 'box-small', 'box-alpha']);
});

test('W3 loading, error and empty states', () => {
  const loading = render(h(bw.AgentBoxWatchView, { actions: { data: null, error: null, loading: true, reload() {} } }));
  assert.match(loading, /skel/i);
  const failed = render(h(bw.AgentBoxWatchView, { actions: { data: null, error: new Error('box watch down'), loading: false, reload() {} } }));
  assert.match(failed, /box watch down/);
  assert.match(failed, />RETRY</);
  assert.doesNotMatch(failed, /no box restarts recorded/);
  const empty = render(h(bw.AgentBoxWatchView, { actions: ok({ actions: [], limit: 50 }) }));
  assert.match(empty, /no box restarts recorded/);
});

test('W4 the section reads the bounded list once through api.js', async () => {
  const calls = routedFetch(ROUTE());
  const root = await mountNode(h(bw.AgentBoxWatch, {}));
  const reads = calls.filter((c) => c.url.startsWith('/api/coord/box-watch/actions'));
  assert.equal(reads.length, 1);
  assert.equal(reads[0].url, '/api/coord/box-watch/actions?limit=50');
  assert.equal(boxCells(root).length, 3);
});

test('W5 entry point: the routed /staff/quartermaster screen shows BOX WATCH; /staff/clerk does not', async () => {
  // The screen the console's router mounts for the path, with its params.
  const routed = (path) => ROUTES.map(([p, C]) => [matchRoute(p, path), C]).find(([params]) => params);
  const hit = routed('/staff/quartermaster');
  assert.ok(hit, '/staff/quartermaster is a console route');
  const calls = routedFetch(ROUTE());
  const root = await mountNode(h(hit[1], hit[0]));
  const sec = byTestId(root, 'agent-box-watch');
  assert.equal(sec.length, 1, 'the quartermaster page carries the BOX WATCH section');
  assert.ok(boxCells(sec[0]).some((a) => a.attrs.href === '/machines?box=box-small'), 'the rows reach the page');
  assert.equal(calls.filter((c) => c.url.startsWith('/api/coord/box-watch/')).length, 1);

  mount(null, mounted); mounted = null;
  const hit2 = routed('/staff/clerk');
  const calls2 = routedFetch(ROUTE());
  const root2 = await mountNode(h(hit2[1], hit2[0]));
  assert.equal(byTestId(root2, 'agent-box-watch').length, 0);
  assert.equal(calls2.filter((c) => c.url.startsWith('/api/coord/box-watch/')).length, 0);

  // The page component itself, as the four staff suites render it.
  const empty = { data: null, error: null, loading: true, reload() {} };
  mount(null, mounted); mounted = null;
  routedFetch(ROUTE());
  const root3 = await mountNode(h(AgentDetailView, { agent: 'quartermaster', roster: empty, findings: empty, activity: empty }));
  assert.equal(byTestId(root3, 'agent-box-watch').length, 1);
});
