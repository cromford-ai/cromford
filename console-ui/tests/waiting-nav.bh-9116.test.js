// BH-9116: the "To do (waiting)" view, reached the way a person reaches it.
// The real App in the fake DOM of tests/helpers/fake-dom.bh-5750.js (native
// dialogs throw), fetch answered by routedFetch. No network.
//   N1 (acceptance 3) mount the App at /, click the KANBAN nav entry, click the
//      TO DO (WAITING) tab: the counts and one table row per waiting ticket
//      are in the DOM, and no ancestor of the table is hidden
//   N2 (acceptance 2, the screen half) on the PIPELINE tab a building card
//      whose pair is a stale claim is gone and the BUILDING count is one lower
//   R2 /p/<project> QUEUES: the TO DO (WAITING) list comes before BUILD QUEUE;
//      a project with no OS board snapshot says so instead of an empty table
import test from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';
import { installDom, routedFetch, all, fire, buttonIn, rowsOf } from './helpers/fake-dom.bh-5750.js';

const setUrl = (to) => {
  const u = new URL(to, 'http://console.test');
  Object.assign(window.location, { pathname: u.pathname, search: u.search, hash: u.hash });
};
globalThis.window = globalThis.window || {
  location: { pathname: '/', search: '', hash: '' },
  dispatchEvent() { return true; }, addEventListener() {}, removeEventListener() {},
  history: { pushState(_s, _t, to) { setUrl(to); }, replaceState(_s, _t, to) { setUrl(to); } },
  scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} })
};

const { App } = await import('../src/app.js');
const { classifyWaiting } = await import('../src/lib/waiting.js');

const mounted = new Set();
test.afterEach(() => { for (const r of mounted) mount(null, r); mounted.clear(); });

const P = 'project-3';
const NOW = Date.now(); // determinism: ok — the payload is classified once against the clock the screen reads
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const ago = (m) => iso(NOW - m * 60000);
const tk = (key, o = {}) => ({ key, status: 'todo', title: `title ${key}`, updatedAt: ago(90), triage_verdict: 'untriaged', waiting_on: '', id: '', url: '', ...o });
const SNAPSHOT = {
  generated_at: Math.floor(NOW / 1000),
  projects: {
    [P]: { board_id: 'b-fixture', tickets: [
      tk('NT-1'), tk('NC-2', { waiting_on: 'client', triage_verdict: 'needs_clarification' }),
      tk('SC-7', { status: 'in_progress', triage_verdict: 'buildable' }), tk('LIVE-1', { status: 'in_progress', triage_verdict: 'buildable' })
    ] }
  }
};
const STATE = {
  triage: [], positions: [], parked_jobs: [], edges: [],
  queue: [
    { project: P, ticket_key: 'SC-7', status: 'claimed', claimed_at: ago(45), enqueued_at: ago(60), updated_at: ago(45) },
    { project: P, ticket_key: 'LIVE-1', status: 'claimed', claimed_at: ago(45), enqueued_at: ago(60), updated_at: ago(45) }
  ],
  live_jobs: [{ id: 'build-project-3-LIVE-1-1', project: P, ticket_id: 'LIVE-1', status: 'running', updated_at: ago(40), beat_at: ago(1) }],
  knobs: { stale_claim_min: 30, max_tickets: 2000, defer_lookback_min: 10080 }, truncated: false, positions_truncated: false
};
const WAITING = classifyWaiting(SNAPSHOT, STATE, { now: NOW });
const PIPELINE = {
  snapshot_age_min: 1,
  columns: {
    queued: [], merge_queue: [], review: [], merged_deployed: [], dead_failed: [],
    building: [
      { id: 'b-sc7', project: P, ticket: 'SC-7', stage: 'execute', updated_at: ago(45), age_min: 45 },
      { id: 'b-live1', project: P, ticket: 'LIVE-1', stage: 'execute', updated_at: ago(1), age_min: 1 }
    ]
  },
  counts: { queued: 0, building: 2, merge_queue: 0, review: 0, merged_deployed: 0, dead_failed: 0 }
};

const route = (waiting = WAITING) => (u) => {
  if (u.startsWith('/api/dash/kanban/waiting')) {
    const project = new URL(u, 'http://console.test').searchParams.get('project');
    if (project && project !== P) return [200, { ok: true, project_in_snapshot: false, rows: [], counts: {}, total: 0 }];
    return [200, waiting];
  }
  if (u.startsWith('/api/dash/kanban/pipeline')) return [200, PIPELINE];
  if (u.startsWith('/api/dash/tickets-snapshot')) return [200, SNAPSHOT];
  if (u.startsWith('/api/dash/fleet')) return [200, { projects: [P, 'cromford'], snapshot_age_min: 1, watchdog: { ok: true } }];
  if (u.startsWith('/api/dash/projects')) return [200, { projects: [{ project: P }, { project: 'cromford' }] }];
  if (u.startsWith('/api/dash/p/')) return [200, { runs: [], builds: [], alerts: [], board: {} }];
  if (u.startsWith('/api/coord/settings')) return [200, { settings: [] }];
  if (u.startsWith('/api/coord/queue?')) return [200, { queue: [] }];
  return [200, {}];
};

const domWithContains = () => {
  const doc = installDom();
  doc.contains = (n) => all(doc).includes(n);
  return doc;
};
const text = (el) => el.textContent.replace(/\s+/g, ' ');
const hiddenAbove = (n) => {
  for (let p = n; p; p = p.parentNode) {
    if (p.attrs && ('hidden' in p.attrs)) return true;
    const style = (p.attrs && p.attrs.style) || '';
    if (/display:\s*none/.test(style) || (p.style && p.style.display === 'none')) return true;
  }
  return false;
};

async function mountAt(path, waiting) {
  const doc = domWithContains();
  setUrl(path);
  const calls = routedFetch(route(waiting));
  const el = doc.createElement('div');
  mounted.add(el);
  mount(h(App), el);
  await flush();
  return { el, calls };
}

test('N1 KANBAN nav entry -> TO DO (WAITING) tab: counts and rows are visible', async () => {
  const { el, calls } = await mountAt('/');
  const nav = all(el).find((n) => n.localName === 'a' && n.attrs.href === '/kanban' && /KANBAN/.test(n.textContent));
  assert.ok(nav, 'the KANBAN nav entry');
  fire(nav, 'click');
  await flush();
  assert.equal(window.location.pathname, '/kanban');
  const tab = buttonIn(el, 'TO DO (WAITING)');
  assert.ok(tab, 'the TO DO (WAITING) tab');
  fire(tab, 'click');
  await flush();
  assert.ok(calls.some((c) => c.url === '/api/dash/kanban/waiting'), 'the view read its route');
  const table = all(el).find((n) => n.localName === 'table');
  assert.ok(table, 'the waiting table is mounted');
  assert.equal(hiddenAbove(table), false, 'no ancestor of the table is hidden');
  const body = rowsOf(table).filter((tr) => tr.parentNode && tr.parentNode.localName === 'tbody');
  assert.equal(body.length, WAITING.rows.length);
  assert.deepEqual(WAITING.rows.map((r) => r.key).sort(), ['NC-2', 'NT-1', 'SC-7']);
  assert.match(text(el), /To do \(waiting\)/);
  assert.match(text(el), /not-triaged 1/);
  assert.match(text(el), /needs-clarification 1/);
  assert.match(text(el), /stale-claim 1/);
  // The project pill filters the view.
  fire(buttonIn(el, 'cromford'), 'click');
  await flush();
  assert.ok(calls.some((c) => c.url === '/api/dash/kanban/waiting?project=cromford'));
  assert.match(text(el), /no OS board snapshot for cromford/);
});

const buildingCount = (el) => {
  const head = all(el).find((n) => n.attrs && n.attrs.class === 'kb__head kb__head--green');
  return head ? all(head).find((n) => n.attrs && n.attrs.class === 'kb__count') : null;
};

test('N2 PIPELINE: a stale-claim building card is gone and BUILDING is one lower', async () => {
  const { el, calls } = await mountAt('/kanban');
  assert.ok(calls.some((c) => c.url === '/api/dash/kanban/waiting'), 'the pipeline tab reads the waiting payload');
  const count = buildingCount(el);
  assert.ok(count, 'the BUILDING count');
  assert.equal(count.textContent.trim(), '1', 'two from the API, one stale claim dropped');
  assert.ok(!all(el).some((n) => n.localName === 'a' && /SC-7/.test(n.textContent)), 'the SC-7 card is not in the DOM');
  assert.ok(all(el).some((n) => /LIVE-1/.test(n.textContent || '')), 'the live card stays');
  assert.match(text(el), /1 stale claim not counted/);
});

test('N2b a failed waiting read leaves the board as the API sent it', async () => {
  const { el } = await mountAt('/kanban', { ok: false, unavailable: 'jobs state read failed (500)' });
  assert.equal(buildingCount(el).textContent.trim(), '2');
});

test('R2 /p/<project> QUEUES: TO DO (WAITING) before BUILD QUEUE; no snapshot says so', async () => {
  const { el, calls } = await mountAt(`/p/${P}`);
  assert.ok(calls.some((c) => c.url === `/api/dash/kanban/waiting?project=${P}`));
  const t = text(el);
  const a = t.indexOf('TO DO (WAITING)');
  const b = t.indexOf('BUILD QUEUE');
  assert.ok(a >= 0, 'the TO DO (WAITING) heading');
  assert.ok(b > a, 'it comes before BUILD QUEUE');
  for (const k of ['NT-1', 'NC-2', 'SC-7']) {
    assert.ok(all(el).some((n) => n.localName === 'a' && n.attrs.href === `/t/${k}`), `${k} row links its ticket`);
  }
  const { el: el2 } = await mountAt('/p/cromford');
  assert.match(text(el2), /no OS board snapshot for cromford/);
});
