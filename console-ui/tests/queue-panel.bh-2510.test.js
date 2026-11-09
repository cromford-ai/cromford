import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { render } from 'preact-render-to-string';
import { api } from '../src/api.js';
import { QUEUE_LIMIT, TRAINS_LIMIT, actionFormState, panelState } from '../src/lib/queue-panel.js';
import DeployQueuePanel from '../src/screens/DeployQueuePanel.js';
import MergeTrainsPanel from '../src/screens/MergeTrainsPanel.js';
import { flush } from './helpers/settle.js';

// BH-3150 (BH-2510.0): the contract the QUEUES panel siblings import. What is
// pinned here is the shape the siblings build on. BH-3151 (BH-2510.1) filled
// the build queue table (tests/build-queue-panel.bh-2510.test.js), BH-3152
// (BH-2510.2) the deploy queue (deploy-queue-panel.bh-2510.test.js) and BH-3153
// (BH-2510.3) the merge trains (merge-trains-panel.bh-2510.test.js); no stub
// screen is left.

const rows = (n) => Array.from({ length: n }, (_, i) => ({ id: i }));
const ok = (data) => ({ data, error: null });
const EMPTY = { build: ok({ queue: [] }), deploy: ok({ deploy_queue: [] }), trains: ok({ merge_trains: [] }) };

test('actionFormState: blocked while the reason is blank or whitespace', () => {
  assert.equal(actionFormState(' ').blocked, true);
  assert.equal(actionFormState('').blocked, true);
  assert.equal(actionFormState(undefined).blocked, true);
  assert.equal(actionFormState(null).blocked, true);
  assert.equal(actionFormState('dead box').blocked, false);
  assert.equal(actionFormState('  dead box ').reason, 'dead box');
});

test('panelState: a failed read is kind:error for that table only, never an empty table', () => {
  const s = panelState({ ...EMPTY, build: { data: null, error: new Error('x') } });
  assert.equal(s.build.kind, 'error');
  assert.deepEqual(s.build.rows, []);
  assert.equal(s.build.capped, false);
  assert.equal(s.deploy.kind, 'ok');
  assert.equal(s.trains.kind, 'ok');
  const d = panelState({ ...EMPTY, deploy: { data: null, error: new Error('y') } });
  assert.deepEqual([d.build.kind, d.deploy.kind, d.trains.kind], ['ok', 'error', 'ok']);
  const t = panelState({ ...EMPTY, trains: { data: null, error: new Error('z') } });
  assert.deepEqual([t.build.kind, t.deploy.kind, t.trains.kind], ['ok', 'ok', 'error']);
});

test('panelState: a failed refresh is an error even with the last good rows still held', () => {
  // useApi keeps `data` from the previous load when a refresh throws
  // (lib/hooks.js), so error-with-data is a shape production hands us.
  const err = new Error('refresh failed');
  const s = panelState({ ...EMPTY, build: { data: { queue: rows(3) }, error: err } });
  assert.equal(s.build.kind, 'error');
  assert.equal(s.build.error, err);
  assert.deepEqual(s.build.rows, []);
});

test('panelState: a body without its array is an error, not an empty table', () => {
  const s = panelState({ ...EMPTY, build: ok({}), deploy: ok({ deploy_queue: 'x' }), trains: { data: null, error: null } });
  assert.deepEqual([s.build.kind, s.deploy.kind, s.trains.kind], ['error', 'error', 'error']);
});

test('panelState: the rows come through, keyed by the worker\'s own field names', () => {
  const s = panelState({ build: ok({ queue: rows(2) }), deploy: ok({ deploy_queue: rows(3) }), trains: ok({ merge_trains: rows(1) }) });
  assert.deepEqual([s.build.rows.length, s.deploy.rows.length, s.trains.rows.length], [2, 3, 1]);
  assert.deepEqual([s.build.capped, s.deploy.capped, s.trains.capped], [false, false, false]);
});

test('panelState: QUEUE_LIMIT rows is capped, one fewer is not', () => {
  assert.equal(QUEUE_LIMIT, 500);
  assert.equal(panelState({ ...EMPTY, build: ok({ queue: rows(500) }) }).build.capped, true);
  assert.equal(panelState({ ...EMPTY, build: ok({ queue: rows(499) }) }).build.capped, false);
  assert.equal(panelState({ ...EMPTY, deploy: ok({ deploy_queue: rows(500) }) }).deploy.capped, true);
  assert.equal(panelState({ ...EMPTY, deploy: ok({ deploy_queue: rows(499) }) }).deploy.capped, false);
});

test('panelState: merge trains cap at the worker\'s 200 clamp', () => {
  assert.equal(TRAINS_LIMIT, 200);
  assert.equal(panelState({ ...EMPTY, trains: ok({ merge_trains: rows(200) }) }).trains.capped, true);
  assert.equal(panelState({ ...EMPTY, trains: ok({ merge_trains: rows(199) }) }).trains.capped, false);
});

function captureFetch() {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET', body: init.body });
    return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true }) };
  };
  return calls;
}

test('api helpers: the exact URL and method each one sends', async () => {
  const calls = captureFetch();
  await api.queueRows('project-3 os', 'queued');
  await api.deployQueueRows('p&x', 'waiting');
  await api.mergeTrains('p/1', 200);
  const qb = { project: 'p', key: 'BH-1', action: 'hold', reason: 'dead box' };
  const db = { project: 'p', sha: 'abc', action: 'drop', reason: 'bad sha' };
  await api.queueAction(qb);
  await api.deployQueueAction(db);
  assert.deepEqual(calls.map((c) => [c.method, c.url]), [
    ['GET', '/api/coord/queue?project=project-3%20os&status=queued&limit=500'],
    ['GET', '/api/coord/deploy-queue?project=p%26x&status=waiting&limit=500'],
    ['GET', '/api/coord/merge-trains?project=p%2F1&limit=200'],
    ['POST', '/api/coord/queue/action'],
    ['POST', '/api/coord/deploy-queue/action'],
  ]);
  assert.deepEqual(JSON.parse(calls[3].body), qb);
  assert.deepEqual(JSON.parse(calls[4].body), db);
});

// BH-3152 made DeployQueuePanel live and BH-3153 MergeTrainsPanel: neither is
// a stub that renders nothing any more.
test('no stub screen is left: the deploy queue and merge trains render', () => {
  for (const C of [DeployQueuePanel, MergeTrainsPanel]) {
    assert.equal(typeof C, 'function');
    assert.notEqual(render(h(C, { project: 'p' })), '');
  }
});

// ---- the production entry point: the real Project page, mounted -------------
// A minimal DOM (the preplan-adoption.bh-2573 pattern), enough for preact to
// mount ProjectScreen with a faked fetch.
class FakeNode {
  constructor(nodeType, name, data) {
    Object.assign(this, { nodeType, localName: name, nodeName: name ? name.toUpperCase() : '#text', data,
      childNodes: [], parentNode: null, attrs: {}, style: {}, listeners: {} });
  }
  get firstChild() { return this.childNodes[0] || null; }
  get nextSibling() {
    if (!this.parentNode) return null;
    const s = this.parentNode.childNodes;
    return s[s.indexOf(this) + 1] || null;
  }
  insertBefore(n, ref) {
    if (n.parentNode) n.parentNode.removeChild(n);
    n.parentNode = this;
    const i = ref ? this.childNodes.indexOf(ref) : -1;
    if (i < 0) this.childNodes.push(n); else this.childNodes.splice(i, 0, n);
    return n;
  }
  appendChild(n) { return this.insertBefore(n, null); }
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n; }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  removeAttribute(k) { delete this.attrs[k]; }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  addEventListener(t, fn) { this.listeners[t] = fn; }
  removeEventListener(t) { delete this.listeners[t]; }
  focus() {}
  querySelector() { return null; }
  querySelectorAll() { return []; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const mounted = [];
afterEach(() => { while (mounted.length) mount(null, mounted.pop()); });

test('the real Project page mounts one QUEUES section, above ROUTING, holding the build queue, deploy queue and merge trains', async () => {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    calls.push({ url: u, method: init.method || 'GET' });
    const body = u.startsWith('/api/dash/p/') ? { board: {}, runs: [], builds: [], alerts: [], events: [] }
      : u.startsWith('/api/coord/queue?') ? { queue: [] } : {};
    return { ok: true, status: 200, text: async () => JSON.stringify(body) };
  };
  const { ProjectScreen } = await import('../src/screens/Project.js');
  const root = doc.createElement('div');
  mount(h(ProjectScreen, { project: 'project-3' }), root);
  mounted.push(root);
  await flush();
  await flush();
  const titles = all(root).filter((n) => n.attrs && n.attrs.class === 'section__title').map((n) => n.textContent);
  assert.equal(titles.filter((t) => t === 'QUEUES').length, 1, titles.join(', '));
  assert.ok(titles.indexOf('QUEUES') < titles.indexOf('ROUTING'), `QUEUES sits above ROUTING: ${titles.join(', ')}`);
  const section = all(root).find((n) => n.attrs && n.attrs.class === 'section__title' && n.textContent === 'QUEUES').parentNode.parentNode;
  // Four children: the TO DO (WAITING) list (BH-9116), the build queue
  // ("nothing queued"), the deploy queue, and MergeTrainsPanel (BH-3153), here
  // an ErrorBox because the faked answer has no merge_trains.
  // TEST-CHANGE: BH-9116 — QUEUES gains the TO DO (WAITING) list first, so 3 -> 4 and merge trains moves to body[3].
  const body = section.childNodes.filter((n) => n.nodeType === 1 && n.attrs.class !== 'section__head');
  assert.equal(body.length, 4, 'the waiting list, build queue, deploy queue and merge trains panels render');
  assert.match(body[0].textContent, /TO DO \(WAITING\)/);
  assert.match(section.textContent, /build queue, deploy queue and merge trains for this project/);
  assert.match(section.textContent, /nothing queued/);
  assert.match(section.textContent, /DEPLOY QUEUE/);
  assert.match(body[3].textContent, /could not load/);
  // The build panel's three reads, the deploy queue's three and the merge
  // trains' one GET of the newest 50; no action is sent.
  assert.deepEqual(calls.filter((c) => /\/api\/coord\/(queue|deploy-queue|merge-trains)/.test(c.url))
    .map((c) => `${c.method} ${c.url}`).sort(), [
    'GET /api/coord/deploy-queue?project=project-3&status=claimed&limit=500',
    // TEST-CHANGE: BH-3154 — the panel also reads the held rows so HOLD / UNHOLD can render.
    'GET /api/coord/deploy-queue?project=project-3&status=held&limit=500',
    'GET /api/coord/deploy-queue?project=project-3&status=queued&limit=500',
    'GET /api/coord/merge-trains?project=project-3&limit=50',
    'GET /api/coord/queue?project=project-3&status=claimed&limit=500',
    'GET /api/coord/queue?project=project-3&status=queued&limit=500',
    'GET /api/coord/queue?project=project-3&status=ready&limit=500',
  ]);
});
