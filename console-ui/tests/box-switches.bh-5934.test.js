import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

// BH-5934 item 3: /flags lists the ON box switch rows, the settings rows
// `switch.<name>.<box>` that bin/lib/lane-switch.sh reads first. The pure half
// (lib/box-switches.js) is driven directly, FlagsView is rendered server-side
// for every load state, and the routed FlagsScreen is mounted against a stubbed
// fetch so the settings read goes through the real api.js.

globalThis.window = globalThis.window || {
  location: { pathname: '/flags', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { boxSwitchRows, isSwitchOn, BOX_SWITCH_KEY_RE } = await import('../src/lib/box-switches.js');
const { FlagsView } = await import('../src/screens/Flags.js');
const { ROUTES } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const { render } = await import('preact-render-to-string');

// Fixed instants only; no case asserts an age.
const row = (key, value, actor = 'fly-1', updated_at = '2026-10-16T10:00:00Z') => ({ key, value, note: null, actor, updated_at });
const SETTINGS = [
  row('switch.fly-disabled.fly-1', '1', 'fly-1', '2026-10-16T10:00:00Z'),
  row('switch.responder-disabled.hub', ' ON ', 'console', '2026-10-15T08:00:00Z'),
  row('switch.resume-disabled.boxa', '0'),
  row('switch.fly-disabled', '1'),
  row('lane.fly-pool.test_impact_gate_cap', '80')
];
const ok = (data) => ({ data, error: null, loading: false, reload() {} });
const view = (over = {}) => render(h(FlagsView, {
  flags: ok({ flags: [] }), projects: [], filter: '', showCleared: false,
  onFilter() {}, onShowCleared() {}, onSet() {}, onClear() {}, busy: false, note: null, dialog: null,
  switches: ok({ settings: SETTINGS }), ...over
}));
const count = (hay, re) => (hay.match(re) || []).length;
// The BOX SWITCHES section alone: from its title to the end of the page.
const section = (out) => {
  const i = out.indexOf('BOX SWITCHES');
  assert.ok(i >= 0, 'a BOX SWITCHES section');
  return out.slice(i);
};

// ------------------------------------------------------------ pure helpers
test('U1: one ON box row becomes {key, name, box, value, set_by, set_at}', () => {
  const rows = boxSwitchRows({ settings: [row('switch.fly-disabled.fly-1', '1', 'fly-1', '2026-10-16T10:00:00Z')] });
  assert.equal(rows.length, 1);
  const r = rows[0];
  assert.equal(r.key, 'switch.fly-disabled.fly-1');
  assert.equal(r.name, 'fly-disabled');
  assert.equal(r.box, 'fly-1');
  assert.equal(r.value, '1');
  assert.equal(r.set_by, 'fly-1');
  assert.equal(r.set_at, '2026-10-16T10:00:00Z');
  const bare = boxSwitchRows({ settings: [{ key: 'switch.x.hub', value: 'true' }] })[0];
  assert.equal(bare.set_by, null, 'no actor is null, not undefined');
  assert.equal(bare.set_at, null);
});

test('U2: 1, on and true (any case, trimmed) are ON; every other value is not listed', () => {
  for (const v of ['1', ' ON ', 'true', 'On', 'TRUE']) {
    assert.equal(isSwitchOn(v), true, `'${v}' is ON`);
    assert.equal(boxSwitchRows({ settings: [row('switch.fly-disabled.fly-1', v)] }).length, 1, `'${v}' is listed`);
  }
  for (const v of ['0', 'off', 'false', 'maybe', '', null, undefined, '10']) {
    assert.equal(isSwitchOn(v), false, `'${v}' is not ON`);
    assert.equal(boxSwitchRows({ settings: [row('switch.fly-disabled.fly-1', v)] }).length, 0, `'${v}' is not listed`);
  }
});

test('U3: a fleet row, a lane-off .box. key, another prefix, an uppercase key and a null key are not listed', () => {
  const keys = ['switch.fly-disabled', 'switch.factory-stop', 'lane-off-x.box.hub', 'switch.a.box.hub',
    'lane.fly-pool.x', 'switch.FLY.hub', 'switch..hub', 'switch.x.', null, undefined, 42];
  for (const key of keys) {
    assert.deepEqual(boxSwitchRows({ settings: [{ key, value: '1', actor: 'a', updated_at: 'x' }] }), [], String(key));
  }
  assert.equal(BOX_SWITCH_KEY_RE.test('switch.spend-ceiling-off.box_2'), true, 'any name, not only *-disabled (A4)');
  assert.deepEqual(boxSwitchRows({ settings: [null, 'x', row('switch.a_b.box_2', 'true')] }).map((r) => [r.name, r.box]),
    [['a_b', 'box_2']], 'junk entries are skipped, the good row stays');
});

test('U4: a read with no settings array is a failed read (null), never an empty list', () => {
  assert.equal(boxSwitchRows({}), null);
  assert.equal(boxSwitchRows(null), null);
  assert.equal(boxSwitchRows(undefined), null);
  assert.equal(boxSwitchRows({ settings: 'x' }), null);
  assert.equal(boxSwitchRows({ error: 'x' }), null);
  assert.deepEqual(boxSwitchRows({ settings: [] }), []);
});

test('U5: round trip with the real writer key, bin/lib/lane-switch.sh _ls_box_key', () => {
  const repo = fileURLToPath(new URL('../..', import.meta.url));
  const key = execFileSync('bash', ['-c', '. bin/lib/lane-switch.sh || exit 9; _ls_box_key fly-disabled'], {
    cwd: repo, env: { PATH: process.env.PATH, JOBS_BOX: 'Fly-1' }, encoding: 'utf8'
  });
  assert.equal(key, 'switch.fly-disabled.fly-1', 'the writer lowercases the box');
  const rows = boxSwitchRows({ settings: [row(key, '1')] });
  assert.equal(rows.length, 1);
  assert.equal(rows[0].name, 'fly-disabled');
  assert.equal(rows[0].box, 'fly-1');
});

// ------------------------------------------------------------ server render
test('R1: BOX SWITCHES lists the 2 ON box rows, sortable, SWITCH links to the row history, BOX to /machines', () => {
  const out = section(view());
  assert.equal(count(out, /<tbody[\s\S]*?<\/tbody>/g), 1, 'one table');
  const body = out.match(/<tbody[\s\S]*?<\/tbody>/)[0];
  assert.equal(count(body, /<tr[\s>]/g), 2, 'two ON box rows');
  assert.match(out, /<a[^>]*href="\/config\/setting\/switch\.fly-disabled\.fly-1"[^>]*>fly-disabled<\/a>/);
  assert.match(out, /<a[^>]*href="\/config\/setting\/switch\.responder-disabled\.hub"[^>]*>responder-disabled<\/a>/);
  assert.match(out, /<a[^>]*href="\/machines"[^>]*>fly-1<\/a>/);
  assert.match(out, /<a[^>]*href="\/machines"[^>]*>hub<\/a>/);
  assert.match(body, />console</, 'SET BY');
  assert.doesNotMatch(out, /resume-disabled/, 'an OFF row is not listed');
  for (const label of ['BOX', 'SWITCH', 'VALUE', 'SET BY', 'SET AT']) {
    assert.match(out, new RegExp(`<th aria-sort="(ascending|descending|none)"[^>]*><button[^>]*>\\s*${label}`), label);
  }
  assert.match(out, /<th aria-sort="ascending"[^>]*><button[^>]*>\s*BOX/, 'BOX sorts ascending by default');
  assert.ok(body.indexOf('fly-1') < body.indexOf('>hub<'), 'fly-1 sorts before hub');
});

test('R2: loading with no data is the skeleton, not a table and not the empty state', () => {
  const out = section(view({ switches: { data: null, error: null, loading: true, reload() {} } }));
  assert.match(out, /class="skel"/);
  assert.doesNotMatch(out, /<table/);
  assert.doesNotMatch(out, /no box switch is on/);
});

test('R3: a failed read is an ErrorBox with RETRY, never "no box switch is on"; zero ON rows is the empty state', () => {
  const failed = section(view({ switches: { data: null, error: new Error('network unreachable'), loading: false, reload() {} } }));
  assert.match(failed, /could not load — <b>network unreachable/);
  assert.match(failed, />RETRY</);
  assert.doesNotMatch(failed, /no box switch is on/);
  const bad = section(view({ switches: ok({ error: 'x' }) }));
  assert.match(bad, /could not load/);
  assert.doesNotMatch(bad, /no box switch is on/);
  const empty = section(view({ switches: ok({ settings: [row('switch.fly-disabled.fly-1', '0')] }) }));
  assert.match(empty, /no box switch is on/);
  assert.doesNotMatch(empty, /could not load/);
  const kept = section(view({ switches: { data: { settings: SETTINGS }, error: new Error('timeout'), loading: false, reload() {} } }));
  assert.match(kept, /could not load — <b>timeout/);
  assert.match(kept, /href="\/config\/setting\/switch\.fly-disabled\.fly-1"/, 'a failed poll keeps the rows');
});

test('R4: the page filter narrows BOX SWITCHES too; the table scrolls in its own wide container', () => {
  const out = section(view({ filter: 'fly-1' }));
  assert.match(out, /href="\/config\/setting\/switch\.fly-disabled\.fly-1"/);
  assert.doesNotMatch(out, /responder-disabled/, 'the hub row is filtered out');
  assert.match(out, /class="tablewrap tablewrap--wide"/);
  assert.match(section(view({ filter: 'CONSOLE' })), /responder-disabled/, 'set_by matches, case blind');
  assert.match(section(view({ filter: 'zzz' })), /no box switch matches 'zzz'/);
});

test('R5: FlagsView without switches renders no BOX SWITCHES section', () => {
  const out = view({ switches: undefined });
  assert.doesNotMatch(out, /BOX SWITCHES/);
  assert.match(out, /ALL FLAGS/);
});

// ------------------------------------------------------------- mounted (D2)
class FakeNode {
  constructor(nodeType, name, data) {
    Object.assign(this, { nodeType, localName: name, nodeName: name ? name.toUpperCase() : '#text', data, childNodes: [], parentNode: null, attrs: {}, style: {}, listeners: {} });
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
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };

let mounted = null;
afterEach(() => { if (mounted) { mount(null, mounted); mounted = null; } });

test('M1: the routed /flags screen reads /api/coord/flags and /api/coord/settings together and lists the box rows', async () => {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  doc.hidden = false;
  globalThis.document = doc;
  const started = [];
  let release;
  const gate = new Promise((r) => { release = r; });
  globalThis.fetch = async (url) => {
    const u = String(url);
    started.push(u);
    await gate; // neither read answers until both have started: a sequential await would hang here
    const body = u.startsWith('/api/coord/settings') ? { settings: SETTINGS }
      : u.startsWith('/api/coord/flags') ? { flags: [] } : {};
    return { ok: true, status: 200, text: async () => JSON.stringify(body) };
  };
  const hit = ROUTES.map(([p, C]) => [matchRoute(p, '/flags'), C]).find(([params]) => params);
  assert.ok(hit, 'a route matches /flags');
  const root = doc.createElement('div');
  mount(h(hit[1], hit[0]), root);
  mounted = root;
  await flush();
  assert.ok(started.some((u) => u.startsWith('/api/coord/flags')), 'the flags read started');
  assert.ok(started.some((u) => u.startsWith('/api/coord/settings')), 'the settings read started before any answer');
  release();
  await flush();
  const links = all(root).filter((n) => n.localName === 'a').map((n) => n.attrs.href);
  assert.ok(links.includes('/config/setting/switch.fly-disabled.fly-1'));
  assert.ok(links.includes('/config/setting/switch.responder-disabled.hub'));
  assert.ok(!links.some((l) => /resume-disabled/.test(l || '')));
  assert.match(root.textContent, /BOX SWITCHES/);
});
