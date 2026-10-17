import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

// BH-7156: /staff/archie mounted the AUTONOMY panel, the panel asked
// GET /api/coord/staff/autonomy?agent=archie, and the worker answered its
// documented 404 (Archie is not a staff agent). The routed /staff/:agent (the
// real ROUTES table and matchRoute) is mounted into a small fake DOM against a
// stubbed fetch that answers the autonomy read the way the worker does: 404 for
// archie, 200 for a staff agent.

globalThis.window = globalThis.window || {
  location: { pathname: '/staff/archie', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { ROUTES } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const { StaffAgentScreen } = await import('../src/screens/Staff.js');

// ---------------------------------------------------------------- fixtures
const ROSTER = {
  agents: [
    { name: 'archie', kind: 'overlooker', role: 'overlooker', accountable: 'operator@example.com', autonomy: 'per-class', cap: null, status: null, open_findings: 0, precision: null, spend_usd: null, last_tick_at: null },
    { name: 'archie-2', kind: 'staff', role: 'records', accountable: 'operator@example.com', autonomy: 'automation', cap: 'augmentation', status: 'active', open_findings: 0, precision: null, spend_usd: null, last_tick_at: null },
    { name: 'watchman', kind: 'staff', role: 'security', accountable: 'operator@example.com', autonomy: 'automation', cap: 'augmentation', status: 'active', open_findings: 0, precision: null, spend_usd: null, last_tick_at: null }
  ],
  sources: {},
  as_of: '2026-10-16T06:00:00Z'
};
const findings = (agent) => ({ agent, findings: [], truncated: false });
const activity = (agent) => ({ agent, events: [], next: null, last_tick: null, cost_status: 'ok', as_of: '2026-10-16T06:00:00Z' });
const autonomy = (agent) => ({
  agent: { name: agent, autonomy: 'automation', cap: 'augmentation', status: 'active' },
  levels: ['automation', 'augmentation', 'autonomy'],
  classes: [],
  delegate_after: { min: 5, source: 'settings' },
  changes: [], changes_limit: 20, changes_limit_source: 'settings', changes_truncated: false
});
const chat = (agent) => ({ agent, messages: [], next: null, stopped: false, stopped_by: null, as_of: '2026-10-16T06:00:00Z' });
const win = (days) => ({ days, source: 'settings', merged: 0, rejected: 0, noise: 0, total: 0, agree: 0, overrule: 0, precision: null, noise_rate: null });
const learning = (agent) => ({
  agent: { name: agent, autonomy: 'automation', cap: 'augmentation', status: 'active' },
  windows: [win(7), win(30)], promotion: null, decisions: [], decisions_more: false,
  page_max: { value: 100, source: 'settings' }, retention_days: { value: 180, source: 'settings' }, as_of: '2026-10-16T06:00:00Z'
});
const STAFF = new Set(['archie-2', 'watchman']);

// ------------------------------------------------------------- fake DOM
class FakeNode {
  constructor(nodeType, name, data) {
    this.nodeType = nodeType; this.localName = name; this.nodeName = name ? name.toUpperCase() : '#text';
    this.data = data; this.childNodes = []; this.parentNode = null; this.attrs = {}; this.style = {}; this.listeners = {};
  }
  get firstChild() { return this.childNodes[0] || null; }
  get nextSibling() {
    if (!this.parentNode) return null;
    const sib = this.parentNode.childNodes;
    return sib[sib.indexOf(this) + 1] || null;
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
  focus() { globalThis.document.activeElement = this; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
  querySelectorAll() { return []; }
  querySelector() { return null; }
}
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const sectionTitles = (root) => all(root).filter((n) => /\bsection__title\b/.test(n.attrs.class || '')).map((n) => n.textContent);
const errorBoxes = (root) => all(root).filter((n) => /\bbanner\b/.test(n.attrs.class || '')).map((n) => n.textContent);

let mounted = null;
afterEach(() => { if (mounted) { mount(null, mounted); mounted = null; } });

// Mounts the routed path and records every request with the status the stub
// answered. The stub answers the autonomy read the way the worker does.
async function mountRoute(path) {
  const calls = [];
  globalThis.fetch = async (url) => {
    const u = String(url);
    const [p, q] = u.split('?');
    const agent = q ? new URLSearchParams(q).get('agent') : null;
    const act = /^\/api\/coord\/staff\/agent\/([^/]+)\/activity$/.exec(p);
    let status = 200;
    let body;
    if (p === '/api/coord/staff/roster') body = ROSTER;
    else if (p === '/api/coord/staff/findings' && agent) body = findings(agent);
    else if (act) body = activity(decodeURIComponent(act[1]));
    else if (p === '/api/coord/staff/autonomy' && STAFF.has(agent)) body = autonomy(agent);
    else if (p === '/api/coord/staff/autonomy') { status = 404; body = { error: 'agent not found' }; }
    // The BH-6823 chat pane (on main since #7155) reads the thread of a staff agent.
    else if (p === '/api/coord/staff/chat' && STAFF.has(agent)) body = chat(agent);
    // The BH-6825 learning view (on main since #7034) reads a staff agent's precision.
    else if (p === '/api/coord/staff/learning' && STAFF.has(agent)) body = learning(agent);
    else { status = 404; body = { error: 'unknown endpoint' }; }
    calls.push({ url: u, status });
    return { ok: status < 300, status, text: async () => JSON.stringify(body) };
  };
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  const hit = ROUTES.map(([pat, C]) => [matchRoute(pat, path), C]).find(([params]) => params);
  assert.equal(hit[1], StaffAgentScreen, `${path} reaches the agent page`);
  const root = doc.createElement('div');
  mount(h(hit[1], hit[0]), root);
  mounted = root;
  await flush();
  return { root, calls };
}

const assertNoAutonomy = ({ root, calls }) => {
  const urls = calls.map((c) => c.url);
  assert.ok(urls.includes('/api/coord/staff/roster'), `the page read the roster: ${urls.join(' ')}`);
  assert.equal(urls.filter((u) => u.includes('/staff/autonomy')).length, 0, `no autonomy request: ${urls.join(' ')}`);
  assert.equal(urls.filter((u) => u.includes('/staff/learning')).length, 0, `no learning request: ${urls.join(' ')}`);
  assert.deepEqual(calls.filter((c) => c.status >= 300), [], 'every request got a 2xx');
  assert.ok(!sectionTitles(root).includes('AUTONOMY'), `no AUTONOMY section: ${sectionTitles(root).join(', ')}`);
  assert.ok(sectionTitles(root).includes('ACTIVITY'), 'the rest of the page renders');
  assert.deepEqual(errorBoxes(root), [], 'no error box');
};

test('A1: the routed /staff/archie asks for no autonomy, gets only 2xx answers, and shows no AUTONOMY section and no error box', async () => {
  assertNoAutonomy(await mountRoute('/staff/archie'));
});

test('A2: /staff/Archie (mixed case) behaves as /staff/archie', async () => {
  assertNoAutonomy(await mountRoute('/staff/Archie'));
});

test('A3: /staff/watchman still reads its autonomy and renders the AUTONOMY section', async () => {
  const { root, calls } = await mountRoute('/staff/watchman');
  const urls = calls.map((c) => c.url);
  assert.ok(urls.includes('/api/coord/staff/autonomy?agent=watchman'), urls.join(' '));
  assert.ok(sectionTitles(root).includes('AUTONOMY'), sectionTitles(root).join(', '));
  assert.deepEqual(errorBoxes(root), []);
});

test('A4: /staff/archie-2 keeps the panel (the archie guard is an exact match)', async () => {
  const { root, calls } = await mountRoute('/staff/archie-2');
  const urls = calls.map((c) => c.url);
  assert.ok(urls.includes('/api/coord/staff/autonomy?agent=archie-2'), urls.join(' '));
  assert.ok(sectionTitles(root).includes('AUTONOMY'), sectionTitles(root).join(', '));
});
