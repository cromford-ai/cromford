import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h, render as mount } from 'preact';
import { planView, runsView } from '../src/lib/registry-seed.js';
import { SeedRegistryView, SeedRegistryPanel } from '../src/screens/hub/SeedRegistry.js';
import { flush } from './helpers/settle.js';

// BH-2677 (BH-2521.2): the SEED REGISTRY panel of the HUB screen. The view is
// rendered to a string; the real SeedRegistryPanel is mounted into a minimal
// DOM and driven through the real api object over a fake fetch (D2).

const FP = 'ab'.repeat(32);
const PLAN = {
  rows: 5, insert: ['lane.fly-pool.test_impact_gate_cap'], update: [{ key: 'lane.b.y', from: '1', to: '2' }],
  prune: ['lib.c.z'], operator_owned: 4, unchanged: 6, actor: 'registry-seed', as_of: '2026-09-26T10:00:00Z', plan_fp: FP
};
const EMPTY_PLAN = { rows: 5, insert: [], update: [], prune: [], operator_owned: 2, unchanged: 3, plan_fp: FP };
// One fixed anchor: OLD is 11 minutes before NOW, past the stale window. The
// mounted panel ages it against the real clock, which is only ever later, so
// the row reads stale there too.
const NOW = Date.parse('2026-09-26T10:00:00Z');
const OLD = new Date(NOW - 11 * 60000).toISOString();
const RUNS = { truncated: false, runs: [
  { id: 2, actor: 'operator@example.com', plan_fp: FP, status: 'started', rows: 5, changed: null, pruned: null, started_at: OLD, finished_at: null },
  { id: 1, actor: 'ops@example.com', plan_fp: FP, status: 'applied', rows: 5, changed: 3, pruned: 1, started_at: '2026-09-25T10:00:00Z', finished_at: '2026-09-25T10:00:02Z' },
] };
const COPY = 'Applies the registry seed: 1 inserts, 1 updates, 1 prunes. Rows an operator owns are never touched.';
const PLAN_URL = '/api/coord/settings/seed-registry/plan';
const RUNS_URL = '/api/coord/settings/seed-registry/runs';
const APPLY_URL = '/api/coord/settings/seed-registry/apply';

// Answers by URL: routes[url] is one [status, body] or a list consumed in order
// (the last repeats). The two GETs race on mount, so order alone is not stable.
function fakeFetch(routes) {
  const calls = [];
  const seen = {};
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    calls.push({ url: u, method: init.method || 'GET', body: init.body ? JSON.parse(init.body) : undefined });
    const r = routes[u] || [404, { error: 'no_route' }];
    const list = Array.isArray(r[0]) ? r : [r];
    const [status, body] = list[Math.min(seen[u] = (seen[u] ?? -1) + 1, list.length - 1)];
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) };
  };
  return calls;
}

const noop = () => {};
const viewProps = (over = {}) => ({
  plan: planView(PLAN), planError: null, runs: runsView(RUNS, NOW), runsError: null,
  busy: false, outcome: null, onApply: noop, onRefresh: noop, ...over
});

test('1: the view renders the section, the counts line and sortable plan and runs tables', () => {
  const out = render(h(SeedRegistryView, viewProps()));
  assert.match(out, /SEED REGISTRY/);
  assert.match(out, /1 insert · 1 update · 1 prune · 4 operator-owned · 6 unchanged/);
  assert.match(out, /RECENT APPLIES/);
  assert.equal((out.match(/class="tablewrap"/g) || []).length, 2);
  const ths = out.match(/<th[^>]*aria-sort="[a-z]+"/g) || [];
  assert.equal(ths.length, 9, `4 plan + 5 run sortable headers, got ${ths.length}`);
  for (const col of ['KEY', 'ACTION', 'FROM', 'TO', 'WHEN', 'ACTOR', 'STATUS', 'CHANGED', 'PRUNED']) assert.match(out, new RegExp(`>\\s*${col}\\b`));
  assert.doesNotMatch(out, /<button[^>]*disabled[^>]*>APPLY<\/button>/);
});

test('2: an empty plan disables APPLY and says nothing to apply, counts still shown', () => {
  const out = render(h(SeedRegistryView, viewProps({ plan: planView(EMPTY_PLAN) })));
  assert.match(out, /<button[^>]*disabled[^>]*>APPLY<\/button>/);
  assert.match(out, /Nothing to apply/);
  assert.match(out, /0 insert · 0 update · 0 prune · 2 operator-owned · 3 unchanged/);
  const loading = render(h(SeedRegistryView, viewProps({ plan: null })));
  assert.match(loading, /<button[^>]*disabled[^>]*>APPLY<\/button>/);
  assert.match(loading, /class="skel"/);
  const busy = render(h(SeedRegistryView, viewProps({ busy: true })));
  assert.match(busy, /<button[^>]*disabled[^>]*>APPLY<\/button>/);
});

test('6: RECENT APPLIES shows the actor and a stale started row as outcome unknown', () => {
  const out = render(h(SeedRegistryView, viewProps()));
  assert.match(out, /operator@example\.com/);
  assert.match(out, /ops@example\.com/);
  assert.match(out, /outcome unknown/);
  assert.match(out, />applied</);
  assert.doesNotMatch(out, /showing the last 20 applies/);
  assert.match(render(h(SeedRegistryView, viewProps({ runs: runsView({ ...RUNS, truncated: true }, NOW) }))), /showing the last 20 applies/);
  const none = render(h(SeedRegistryView, viewProps({ runs: runsView({ runs: [] }, NOW) })));
  assert.match(none, /No applies yet/);
  const failed = render(h(SeedRegistryView, viewProps({ runs: null, runsError: new Error('not_implemented') })));
  assert.match(failed, /could not load/);
  assert.doesNotMatch(failed, /No applies yet/);
});

test('8: a lane key links to its settings view; a lib key stays text', () => {
  const out = render(h(SeedRegistryView, viewProps()));
  assert.match(out, /<a[^>]*href="\/settings\/fly-pool"[^>]*>lane\.fly-pool\.test_impact_gate_cap<\/a>/);
  assert.match(out, /<a[^>]*href="\/settings\/b"/);
  assert.doesNotMatch(out, /<a[^>]*>lib\.c\.z<\/a>/);
  assert.match(out, /lib\.c\.z/);
});

// ---- the real SeedRegistryPanel, mounted and clicked (D2) -------------------
// Same minimal DOM as restore-lab-panel.bh-1909.test.js: only what preact and
// Modal touch.

class FakeNode {
  constructor(nodeType, name, data) {
    this.nodeType = nodeType;
    this.localName = name;
    this.nodeName = name ? name.toUpperCase() : '#text';
    this.data = data;
    this.childNodes = [];
    this.parentNode = null;
    this.attrs = {};
    this.style = {};
    this.listeners = {};
  }
  get onclick() { return null; }
  get onchange() { return null; }
  get oninput() { return null; }
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
  removeChild(n) {
    this.childNodes.splice(this.childNodes.indexOf(n), 1);
    n.parentNode = null;
    return n;
  }
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

function installDom() {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };
  return doc;
}

const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const button = (root, label) => all(root).find((n) => n.localName === 'button' && n.textContent.trim() === label);
const click = (el) => el.listeners.click.call(el, { type: 'click', target: el, currentTarget: el, preventDefault() {}, stopPropagation() {} });
const isDisabled = (n) => n.disabled === true || ('disabled' in n.attrs && n.attrs.disabled !== 'false');
const dialogOf = (root) => all(root).find((n) => n.attrs && n.attrs.role === 'dialog');
const type = (el, value) => { el.value = value; el.listeners.input.call(el, { type: 'input', target: el, currentTarget: el }); };
// BH-2995: the dialog's REASON field, the one input in it.
const reasonInput = (d) => all(d).find((n) => n.localName === 'input');
const dialogApply = (root) => all(dialogOf(root)).find((n) => n.localName === 'button' && n.textContent.trim() === 'APPLY');
const gets = (calls, url) => calls.filter((c) => c.method === 'GET' && c.url === url).length;

// Every mounted panel is unmounted after its test, so a panel that polls (an
// interval timer) fails test 3 instead of keeping the runner alive.
const mounted = [];
test.afterEach(() => { while (mounted.length) mount(null, mounted.pop()); });

async function mountPanel(routes) {
  const doc = installDom();
  const calls = fakeFetch(routes);
  const root = doc.createElement('div');
  mounted.push(root);
  mount(h(SeedRegistryPanel, {}), root);
  await flush();
  return { root, calls };
}

test('3: mounted, the panel loads plan and runs once each and does not poll', async () => {
  const { root, calls } = await mountPanel({ [PLAN_URL]: [200, PLAN], [RUNS_URL]: [200, RUNS] });
  assert.equal(gets(calls, PLAN_URL), 1);
  assert.equal(gets(calls, RUNS_URL), 1);
  assert.equal(calls.length, 2);
  assert.match(root.textContent, /lane\.b\.y/);
  await new Promise((r) => setTimeout(r, 300)); // fixed-wait: ok an observation window for "no further fetch", not a render barrier
  assert.equal(calls.length, 2, 'no further fetch after mount');
  click(button(root, 'REFRESH'));
  await flush();
  assert.equal(gets(calls, PLAN_URL), 2);
  assert.equal(gets(calls, RUNS_URL), 2);
});

test('4: APPLY confirms in the Modal, POSTs once with the plan_fp, shows the outcome and reloads both', async () => {
  const { root, calls } = await mountPanel({
    [PLAN_URL]: [[200, PLAN], [200, EMPTY_PLAN]], [RUNS_URL]: [200, RUNS],
    [APPLY_URL]: [200, { id: 11, actor: 'operator@example.com', rows: 5, changed: 2, pruned: 1, changed_keys: [], pruned_keys: [] }],
  });
  click(button(root, 'APPLY'));
  await flush();
  const dialog = dialogOf(root);
  assert.ok(dialog, 'the in-app dialog opened');
  assert.ok(dialog.textContent.includes(COPY), dialog.textContent);
  // The toolbar APPLY comes before the dialog's in tree order.
  assert.equal(isDisabled(button(root, 'APPLY')), true, 'APPLY busy while the dialog is open');
  assert.equal(calls.length, 2, 'opening the dialog sends nothing');
  // BH-2995: a REASON field under the copy; APPLY is disabled until it holds
  // non-blank text, and a click on it while disabled sends nothing.
  const reason = reasonInput(dialog);
  assert.ok(reason, 'the dialog holds a REASON input');
  assert.match(dialog.textContent, /REASON/);
  assert.equal(isDisabled(dialogApply(root)), true, 'APPLY disabled while the reason is blank');
  click(dialogApply(root));
  await flush();
  type(reason, '   ');
  await flush();
  assert.equal(isDisabled(dialogApply(root)), true, 'a whitespace reason still blocks');
  assert.equal(calls.length, 2, 'a blocked APPLY sends nothing');
  type(reason, ' fix drift ');
  await flush();
  assert.equal(isDisabled(dialogApply(root)), false, 'APPLY enabled once the reason is filled');
  click(dialogApply(root));
  await flush();
  const posts = calls.filter((c) => c.method === 'POST');
  assert.equal(posts.length, 1);
  assert.equal(posts[0].url, APPLY_URL);
  assert.deepEqual(posts[0].body, { plan_fp: FP, reason: 'fix drift' });
  assert.match(root.textContent, /Applied #11: 2 changed, 1 pruned\./);
  assert.equal(gets(calls, PLAN_URL), 2);
  assert.equal(gets(calls, RUNS_URL), 2);
  assert.ok(!dialogOf(root), 'dialog closed');
  assert.match(root.textContent, /Nothing to apply/);
});

test('5: CANCEL sends nothing and reloads nothing', async () => {
  const { root, calls } = await mountPanel({ [PLAN_URL]: [200, PLAN], [RUNS_URL]: [200, RUNS] });
  click(button(root, 'APPLY'));
  await flush();
  click(button(root, 'CANCEL'));
  await flush();
  assert.equal(calls.length, 2);
  assert.ok(!dialogOf(root));
  assert.doesNotMatch(root.textContent, /Applied/);
  assert.equal(isDisabled(button(root, 'APPLY')), false, 'enabled again after cancel');
});

test('2: mounted with an empty plan, clicking the disabled APPLY sends nothing', async () => {
  const { root, calls } = await mountPanel({ [PLAN_URL]: [200, EMPTY_PLAN], [RUNS_URL]: [200, RUNS] });
  const btn = button(root, 'APPLY');
  assert.equal(isDisabled(btn), true);
  click(btn);
  await flush();
  assert.ok(!dialogOf(root));
  assert.equal(calls.length, 2);
});

test('7: a rejected plan fetch and a plan without plan_fp are errors, not "Nothing to apply"', async () => {
  const failed = await mountPanel({ [PLAN_URL]: [501, { error: 'not_implemented' }], [RUNS_URL]: [200, RUNS] });
  assert.match(failed.root.textContent, /could not load/);
  assert.match(failed.root.textContent, /not_implemented/);
  assert.doesNotMatch(failed.root.textContent, /Nothing to apply/);
  assert.equal(isDisabled(button(failed.root, 'APPLY')), true);
  const noFp = await mountPanel({ [PLAN_URL]: [200, { insert: [], update: [], prune: [], operator_owned: 0, unchanged: 0 }], [RUNS_URL]: [200, RUNS] });
  assert.match(noFp.root.textContent, /bad response/);
  assert.doesNotMatch(noFp.root.textContent, /Nothing to apply/);
  const out = render(h(SeedRegistryView, viewProps({ plan: null, planError: new Error('not_implemented') })));
  assert.match(out, /could not load/);
  assert.match(out, /—/, 'counts are unknown, not zero');
  assert.doesNotMatch(out, /0 insert/);
});

test('9: a 409 fleet_gate on confirm names both boxes', async () => {
  const { root, calls } = await mountPanel({
    [PLAN_URL]: [200, PLAN], [RUNS_URL]: [200, RUNS],
    [APPLY_URL]: [409, { error: 'fleet_gate', boxes: [{ box: 'ops-1', reason: 'unreachable' }, { box: 'hub-2', reason: 'stale' }] }],
  });
  click(button(root, 'APPLY'));
  await flush();
  type(reasonInput(dialogOf(root)), 'retry');
  await flush();
  click(dialogApply(root));
  await flush();
  assert.equal(calls.filter((c) => c.method === 'POST').length, 1);
  assert.match(root.textContent, /ops-1 \(unreachable\)/);
  assert.match(root.textContent, /hub-2 \(stale\)/);
  assert.doesNotMatch(root.textContent, /Applied #/);
});

test('10: clicking a failed run expands its error and the keys behind its counts', async () => {
  const failedRuns = { truncated: false, runs: [
    { id: 7, actor: 'operator@example.com', plan_fp: FP, status: 'failed', rows: 5, changed: 1, pruned: 1, error: 'D1 write timeout',
      changed_keys: ['lane.fly-pool.test_impact_gate_cap'], pruned_keys: ['lib.c.z'], started_at: '2026-09-25T10:00:00Z', finished_at: '2026-09-25T10:00:09Z' },
  ] };
  const { root, calls } = await mountPanel({ [PLAN_URL]: [200, PLAN], [RUNS_URL]: [200, failedRuns] });
  assert.doesNotMatch(root.textContent, /D1 write timeout/, 'detail closed until clicked');
  const when = button(root, '2026-09-25T10:00:00Z');
  assert.equal(when.attrs['aria-expanded'], 'false');
  click(when);
  await flush();
  assert.equal(button(root, '2026-09-25T10:00:00Z').attrs['aria-expanded'], 'true');
  assert.match(root.textContent, /D1 write timeout/);
  assert.match(root.textContent, /2026-09-25T10:00:09Z/);
  const detail = all(root).find((n) => n.localName === 'dl');
  assert.ok(detail, 'the run detail rendered');
  assert.ok(all(detail).some((n) => n.localName === 'a' && n.attrs.href === '/settings/fly-pool'), 'a changed lane key links to its settings view');
  assert.match(detail.textContent, /lib\.c\.z/);
  assert.ok(detail.textContent.includes(FP));
  assert.equal(calls.length, 2, 'expanding sends nothing');
  click(button(root, '2026-09-25T10:00:00Z'));
  await flush();
  assert.doesNotMatch(root.textContent, /D1 write timeout/, 'a second click closes it');
});

test('10: a run without key lists shows them as unknown, not empty', () => {
  const out = render(h(SeedRegistryView, viewProps({ openId: 1 })));
  assert.match(out, /<dl[^>]*>[\s\S]*changed_keys[\s\S]*class="na"/);
  assert.doesNotMatch(out, />none</);
});
