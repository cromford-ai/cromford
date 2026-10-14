import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

// BH-5643 (BH-5635.4). Mission Control's PROJECTS table gets three flag
// columns: PAUSED (the paused-<p> row, with PAUSE/RESUME), WIP (the
// wip-limit-<p> row's value, with a number input and SAVE) and ROUTE (the
// routing row, a link to /p/<p>). A flag read that failed is "—", never
// "off": PAUSED gates merges and builds on every box. F1-F5 drive the pure
// shaper, F6-F9 render the real components, F10-F12 mount the real FleetScreen
// in a small fake DOM against a stubbed fetch, so every read and write goes
// through the real api.js.

globalThis.window = globalThis.window || {
  location: { pathname: '/', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { shapeProjectFlags, wipInputError, cellText, flagSortValue } = await import('../src/lib/flagrows.js');
const { ProjectsTable, FleetScreen } = await import('../src/screens/Fleet.js');
const { ConfigView } = await import('../src/screens/Config.js');
const { FleetContext } = await import('../src/app.js');
const { render } = await import('preact-render-to-string');

const project = (name) => ({
  project: name, last_run_age_min: 3, last_summary: 'ok', last_rc: 0, paused: false, automerge: true, fleet: {}
});

// The <tr> for one project, so an assertion about "this row" cannot pass on a
// cell that rendered in another one.
const rowHtml = (out, name) => {
  const rows = out.split('<tr').slice(1);
  const hit = rows.find((r) => r.includes(`href="/p/${name}"`));
  assert.ok(hit, `a row for ${name}`);
  return hit;
};
// The td under one header, by header position.
const headers = (out) => {
  const head = out.slice(out.indexOf('<thead'), out.indexOf('</thead>'));
  return head.split('<th ').slice(1).map((t) => t.replace(/^[^>]*>/, '').replace(/<[^>]*>/g, '').replace(/[↑↓]/g, '').trim());
};
const cellOf = (out, name, label) => {
  const i = headers(out).findIndex((t) => t.startsWith(label));
  assert.ok(i >= 0, `a ${label} header`);
  const tds = rowHtml(out, name).split('<td').slice(1);
  return tds[i];
};
const textOf = (frag) => frag.replace(/^[^>]*>/, '').replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();

// ---------------------------------------------------------------- shaper

test('F1: an unreadable flags or routing payload is null in every cell', () => {
  for (const [f, r] of [[null, null], [{}, {}], [{ flags: null }, { routing: null }], ['x', 7]]) {
    assert.deepEqual(shapeProjectFlags(f, r, ['a']), { a: { paused: null, wip: null, route: null } });
  }
  // The worker caps GET /api/flags at 500 rows: a full page cannot say "no row".
  const full = { flags: Array.from({ length: 500 }, (_, i) => ({ name: `x-${i}`, active: 0 })) };
  assert.equal(shapeProjectFlags(full, null, ['a']).a.paused, null);
  assert.equal(shapeProjectFlags(full, null, ['a']).a.wip, null);
  const fullRoute = { routing: Array.from({ length: 500 }, (_, i) => ({ project: `p${i}`, builder: 'local' })) };
  assert.equal(shapeProjectFlags(null, fullRoute, ['a']).a.route, null);
});

test('F2: paused reads the exact paused-<p> row; no row is false; active null is null', () => {
  const s = shapeProjectFlags({ flags: [{ name: 'paused-a', active: 1 }, { name: 'paused-ab', active: 0 }] }, null, ['a', 'ab', 'b']);
  assert.equal(s.a.paused, true);
  assert.equal(s.ab.paused, false, 'paused-a does not mark ab');
  assert.equal(s.b.paused, false);
  const s2 = shapeProjectFlags({ flags: [{ name: 'paused-ab', active: 1 }] }, null, ['a', 'ab']);
  assert.equal(s2.a.paused, false, 'paused-ab does not mark a');
  assert.equal(s2.ab.paused, true);
  assert.equal(shapeProjectFlags({ flags: [{ name: 'paused-a', active: null }] }, null, ['a']).a.paused, null);
  assert.equal(shapeProjectFlags({ flags: [{ name: 'paused-a' }] }, null, ['a']).a.paused, null);
  for (const odd of [2, 'x', 'on']) {
    assert.equal(shapeProjectFlags({ flags: [{ name: 'paused-a', active: odd }] }, null, ['a']).a.paused, null, String(odd));
  }
  assert.equal(shapeProjectFlags({ flags: [{ name: 'paused-a', active: '1' }] }, null, ['a']).a.paused, true);
  // A flag for a project not in the list adds no row.
  assert.deepEqual(Object.keys(shapeProjectFlags({ flags: [{ name: 'paused-z', active: 1 }] }, null, ['a'])), ['a']);
});

test('F3: wip is the value of an active wip-limit-<p> row, false with none, null when unreadable', () => {
  const wip = (row) => shapeProjectFlags({ flags: row ? [{ name: 'wip-limit-a', ...row }] : [] }, null, ['a']).a.wip;
  assert.equal(wip({ active: 1, value: '5' }), 5);
  assert.equal(wip({ active: 1, value: '12' }), 12);
  assert.equal(wip({ active: 0, value: '5' }), false);
  assert.equal(wip(null), false);
  for (const v of ['', 'x', '0', '1.5', '-3', null, undefined, ' 5']) assert.equal(wip({ active: 1, value: v }), null, String(v));
  assert.equal(wip({ active: null, value: '5' }), null);
});

test('F4: route is builder · pool_app · HALTED from the routing row, "no row" without one', () => {
  const routing = { routing: [
    { project: 'a', builder: 'pool', pool_app: 'bh-pool', halted: 1 },
    { project: 'c', builder: 'local', pool_app: null, halted: 0 }
  ] };
  const s = shapeProjectFlags({ flags: [] }, routing, ['a', 'b', 'c']);
  assert.equal(s.a.route, 'pool · bh-pool · HALTED');
  assert.equal(s.b.route, 'no row');
  assert.equal(s.c.route, 'local');
});

test('F5: wipInputError takes a whole number 1..9999 and refuses everything else', () => {
  assert.equal(wipInputError('5'), null);
  assert.equal(wipInputError(' 12 '), null);
  assert.equal(wipInputError('9999'), null);
  for (const bad of ['0', '-1', '1.5', '1e3', '', ' ', '5; rm -rf', '../x', '10000', '05', null, undefined]) {
    assert.equal(typeof wipInputError(bad), 'string', String(bad));
  }
  assert.equal(cellText('paused', null), '—');
  assert.equal(cellText('paused', false), 'off');
  assert.equal(cellText('paused', true), 'ON');
  assert.equal(cellText('wip', false), 'none');
  assert.equal(cellText('wip', 5), '5');
  assert.equal(cellText('route', null), '—');
});

// ------------------------------------------------------------- the table

const ROWS = [project('a'), project('b'), project('c')];

test('F6: unreadable flags render "—" in PAUSED and WIP, never off, and no PAUSE button', () => {
  const cells = shapeProjectFlags(null, null, ROWS.map((r) => r.project));
  const out = render(h(ProjectsTable, { rows: ROWS, recentRuns: {}, flagCells: cells, onPause() {}, onSaveWip() {} }));
  for (const p of ['a', 'b', 'c']) {
    assert.equal(textOf(cellOf(out, p, 'PAUSED')), '—');
    assert.match(textOf(cellOf(out, p, 'WIP')), /^—/);
    assert.match(cellOf(out, p, 'ROUTE'), new RegExp(`href="/p/${p}"`), 'ROUTE "—" still links');
  }
  assert.doesNotMatch(out, />\s*off\s*</);
  assert.doesNotMatch(out, />\s*none\s*</);
  assert.doesNotMatch(out, />\s*(PAUSE|RESUME)\s*</);
  // The four older suites render without flagCells: "—" and no buttons.
  const bare = render(h(ProjectsTable, { rows: ROWS, recentRuns: {} }));
  assert.equal(textOf(cellOf(bare, 'a', 'PAUSED')), '—');
  assert.doesNotMatch(bare, /SAVE/);
});

const READABLE = shapeProjectFlags(
  { flags: [{ name: 'paused-a', active: 1 }, { name: 'wip-limit-b', active: 1, value: '5' }] },
  { routing: [{ project: 'a', builder: 'pool', pool_app: 'bh-pool', halted: 0 }] },
  ['a', 'b', 'c']
);

test('F7: PAUSED, WIP and ROUTE are sortable headers; accessors return bool/number/string; ROUTE links to /p/<p>', () => {
  const out = render(h(ProjectsTable, { rows: ROWS, recentRuns: {}, flagCells: READABLE }));
  const hs = headers(out);
  const iFlags = hs.findIndex((t) => t.startsWith('FLAGS'));
  // BH-6350 put MODE between PAUSED and WIP.
  assert.deepEqual(hs.slice(iFlags, iFlags + 5).map((t) => t.split(' ')[0]), ['FLAGS', 'PAUSED', 'MODE', 'WIP', 'ROUTE']);
  for (const label of ['PAUSED', 'WIP', 'ROUTE']) {
    assert.match(out, new RegExp(`<th aria-sort="(none|ascending|descending)"[^>]*>\\s*<button[^>]*>\\s*${label}`), label);
  }
  assert.equal(flagSortValue('paused', READABLE.a), true);
  assert.equal(flagSortValue('paused', READABLE.b), false);
  assert.equal(flagSortValue('wip', READABLE.b), 5);
  assert.equal(flagSortValue('wip', READABLE.a), null, 'no limit sorts as missing, not as 0');
  assert.equal(flagSortValue('route', READABLE.a), 'pool · bh-pool');
  assert.equal(flagSortValue('paused', null), null);
  assert.equal(textOf(cellOf(out, 'a', 'PAUSED')), 'ON');
  assert.equal(textOf(cellOf(out, 'b', 'PAUSED')), 'off');
  assert.equal(textOf(cellOf(out, 'b', 'WIP')), '5');
  assert.equal(textOf(cellOf(out, 'a', 'WIP')), 'none');
  assert.match(cellOf(out, 'a', 'ROUTE'), /href="\/p\/a"[^>]*>pool · bh-pool</);
  assert.match(cellOf(out, 'b', 'ROUTE'), /href="\/p\/b"[^>]*>no row</);
});

test('F8: with handlers, PAUSE shows on an off row and RESUME on an on row; Fleet.js has no native dialog', () => {
  const out = render(h(ProjectsTable, { rows: ROWS, recentRuns: {}, flagCells: READABLE, onPause() {}, onSaveWip() {} }));
  assert.match(cellOf(out, 'a', 'PAUSED'), /<button[^>]*>RESUME<\/button>/);
  assert.match(cellOf(out, 'b', 'PAUSED'), /<button[^>]*>PAUSE<\/button>/);
  const wip = cellOf(out, 'b', 'WIP');
  assert.match(wip, /<input[^>]*type="number"/);
  assert.match(wip, /aria-label="wip limit for b"/);
  assert.match(wip, /SAVE/);
  // The cell is a pure function of flagCells: the same input renders the same state.
  assert.equal(render(h(ProjectsTable, { rows: ROWS, recentRuns: {}, flagCells: READABLE, onPause() {}, onSaveWip() {} })), out);
  const src = readFileSync(new URL('../src/screens/Fleet.js', import.meta.url), 'utf8');
  assert.ok(src.includes('export function ProjectsTable'), 'read the real Fleet.js');
  // `confirm({...})` is useConfirm's in-app modal; a native dialog is called on
  // window, or bare with a string.
  assert.ok(src.includes('await confirm({'), 'the in-app confirm is what the screen calls');
  assert.doesNotMatch(src, /\bwindow\.(confirm|alert|prompt)\s*\(|(^|[^.\w])(alert|prompt)\s*\(|\bconfirm\s*\(\s*['"`]/m);
});

test('F9: the /config flags table shows a VALUE column with the row value', () => {
  const ok = (data) => ({ data, error: null, loading: false, reload() {} });
  const out = render(h(ConfigView, {
    settings: ok({ settings: [] }),
    flags: ok({ flags: [{ name: 'wip-limit-a', active: 1, value: '5', actor: 'console', reason: 'r', updated_at: null }, { name: 'pause-all', active: 0, value: null }] }),
    changes: ok({ changes: [], truncated: false })
  }));
  const flagsTable = out.slice(out.indexOf('>FLAGS<'));
  assert.match(flagsTable, /<button[^>]*>\s*VALUE/);
  const row = flagsTable.split('<tr').find((r) => r.includes('wip-limit-a'));
  assert.ok(row);
  assert.match(row, /<td[^>]*>5<\/td>/);
  const other = flagsTable.split('<tr').find((r) => r.includes('>pause-all<'));
  assert.match(other, /<td[^>]*>—<\/td>/);
  assert.match(row, /TURN OFF/, 'the toggle is still there');
});

// ------------------------------------------------------------- fake DOM
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
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
  focus() { globalThis.document.activeElement = this; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
  // Only the two selectors Modal.js asks for.
  querySelectorAll(sel) {
    const tags = sel.split(',').map((x) => x.trim().split(/\s+/).pop());
    const within = sel.includes('.modal__body') ? all(this).filter((n) => /\bmodal__body\b/.test(n.attrs.class || '')) : [this];
    return within.flatMap((r) => all(r).slice(1)).filter((n) => tags.includes(n.localName));
  }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
}
function installDom() {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  doc.hidden = false;
  doc.activeElement = null;
  globalThis.document = doc;
  return doc;
}
const fire = (node, type, extra = {}) => {
  const key = Object.keys(node.listeners).find((k) => k.toLowerCase() === type);
  assert.ok(key, `a ${type} listener on <${node.localName}>`);
  return node.listeners[key].call(node, { type: key, target: node, currentTarget: node, button: 0, preventDefault() {}, ...extra });
};
const disabled = (n) => n.getAttribute('disabled') !== null && n.getAttribute('disabled') !== 'false';
const confirmBtn = (root) => {
  const actions = all(root).find((n) => /\bmodal__actions\b/.test(n.attrs.class || ''));
  return actions && actions.childNodes.filter((n) => n.localName === 'button').pop();
};
const modalInput = (root) => {
  const body = all(root).find((n) => /\bmodal__body\b/.test(n.attrs.class || ''));
  return body && all(body).find((n) => n.localName === 'input');
};
const typeInto = (node, v) => { node.value = v; fire(node, 'input'); };
// The <tr> of one project in the PROJECTS table and the cell under a header.
const trOf = (root, name) => all(root).find((n) => n.localName === 'tr'
  && n.childNodes[0] && n.childNodes[0].localName === 'td' && n.childNodes[0].textContent.trim() === name);
const domCell = (root, name, label) => {
  const table = all(root).find((n) => n.localName === 'table' && all(n).some((x) => x.localName === 'th' && x.textContent.trim().startsWith('PAUSED')));
  assert.ok(table, 'the PROJECTS table');
  const ths = all(table).filter((n) => n.localName === 'th');
  const i = ths.findIndex((t) => t.textContent.trim().startsWith(label));
  const tr = trOf(table, name);
  assert.ok(tr, `a row for ${name}`);
  return tr.childNodes.filter((c) => c.localName === 'td')[i];
};
const btnIn = (node, label) => all(node).find((n) => n.localName === 'button' && n.textContent.trim() === label);

// GETs answer from `state`; a PUT answers `put(body)`, which may change state.
function stubFetch(state, put = () => [200, { ok: true }]) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    const method = init.method || 'GET';
    const body = init.body ? JSON.parse(init.body) : null;
    calls.push({ url: u, method, body });
    let status = 200; let res;
    if (method !== 'GET') [status, res] = put(body);
    else if (u === '/api/dash/projects') res = { projects: state.projects, projects_source: 'fleet_status', snapshot_age_min: 1 };
    else if (u === '/api/coord/flags') [status, res] = state.flagsStatus ? [state.flagsStatus, { error: 'boom' }] : [200, { flags: state.flags }];
    else if (u === '/api/coord/routing') res = { routing: state.routing };
    else res = {};
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(res) };
  };
  return calls;
}

// Every mounted screen polls every 30 s. A failed assertion skips a case's own
// unmount, so afterEach unmounts whatever is still mounted: a red case must
// fail, not hang the run on live timers.
const mounted = new Set();
test.afterEach(() => { for (const root of mounted) mount(null, root); mounted.clear(); });

async function mountFleet() {
  installDom();
  const root = globalThis.document.createElement('div');
  mount(h(FleetContext.Provider, { value: { data: null } }, h(FleetScreen)), root);
  mounted.add(root);
  await flush();
  return { root, text: () => root.textContent, unmount: () => { mounted.delete(root); mount(null, root); } };
}

const base = () => ({
  projects: [project('a'), project('b')],
  flags: [{ name: 'paused-a', active: 0, value: null }, { name: 'wip-limit-b', active: 1, value: '3' }],
  routing: [{ project: 'a', builder: 'pool', pool_app: 'bh-pool', halted: 0 }]
});

test('F10: PAUSE opens the in-app modal, sends one PUT paused-<p> after a reason, and the cell reads only the re-read', async () => {
  const state = base();
  const calls = stubFetch(state);
  const c = await mountFleet();
  assert.ok(calls.some((x) => x.url === '/api/coord/flags' && x.method === 'GET'), 'FleetScreen reads the flags');
  assert.ok(calls.some((x) => x.url === '/api/coord/routing' && x.method === 'GET'), 'FleetScreen reads the routing rows');
  assert.equal(domCell(c.root, 'a', 'PAUSED').textContent.replace(/PAUSE|RESUME/, '').trim(), 'off');
  assert.equal(domCell(c.root, 'b', 'WIP').textContent.replace(/SAVE/, '').trim(), '3');
  assert.equal(domCell(c.root, 'a', 'ROUTE').textContent.trim(), 'pool · bh-pool');

  // A 200 that changes nothing: the cell stays off (no optimistic state).
  fire(btnIn(domCell(c.root, 'a', 'PAUSED'), 'PAUSE'), 'click');
  await flush();
  assert.match(c.text(), /PAUSE a/);
  assert.ok(disabled(confirmBtn(c.root)), 'confirm is blocked until a reason is typed');
  assert.ok(disabled(btnIn(domCell(c.root, 'a', 'PAUSED'), 'PAUSE')), 'busy through the dialog');
  typeInto(modalInput(c.root), 'drill');
  await flush();
  assert.ok(!disabled(confirmBtn(c.root)));
  const before = calls.length;
  fire(confirmBtn(c.root), 'click');
  await flush();
  const puts = calls.filter((x) => x.method === 'PUT');
  assert.equal(puts.length, 1);
  assert.equal(puts[0].url, '/api/coord/flags');
  assert.deepEqual(puts[0].body, { name: 'paused-a', active: 1, reason: 'drill' });
  assert.ok(calls.slice(before).some((x) => x.method === 'GET' && x.url === '/api/coord/flags'), 're-reads the flags');
  assert.match(c.text(), /paused-a set on/);
  assert.equal(domCell(c.root, 'a', 'PAUSED').textContent.replace(/PAUSE|RESUME/, '').trim(), 'off', 'the cell shows the re-read, not the click');

  // A PUT that lands: the re-read says ON and the button turns to RESUME.
  state.flags[0].active = 0;
  stubFetch(state, (body) => { state.flags[0] = { name: body.name, active: body.active, value: null }; return [200, { ok: true }]; });
  fire(btnIn(domCell(c.root, 'a', 'PAUSED'), 'PAUSE'), 'click');
  await flush();
  typeInto(modalInput(c.root), 'drill');
  await flush();
  fire(confirmBtn(c.root), 'click');
  await flush();
  assert.equal(domCell(c.root, 'a', 'PAUSED').textContent.replace(/RESUME/, '').trim(), 'ON');
  assert.ok(btnIn(domCell(c.root, 'a', 'PAUSED'), 'RESUME'));

  // CANCEL sends nothing.
  const calls2 = stubFetch(state);
  fire(btnIn(domCell(c.root, 'a', 'PAUSED'), 'RESUME'), 'click');
  await flush();
  fire(all(c.root).find((n) => n.localName === 'button' && n.textContent.trim() === 'CANCEL'), 'click');
  await flush();
  assert.equal(calls2.filter((x) => x.method === 'PUT').length, 0);
  c.unmount();
});

test('F11: WIP SAVE refuses a bad number with no request and PUTs wip-limit-<p> for a good one; a refused PUT shows the error', async () => {
  const state = base();
  let calls = stubFetch(state);
  let c = await mountFleet();
  const input = () => all(domCell(c.root, 'a', 'WIP')).find((n) => n.localName === 'input');
  const form = () => all(domCell(c.root, 'a', 'WIP')).find((n) => n.localName === 'form');
  for (const bad of ['0', '-1', '1.5', '10000', '']) {
    typeInto(input(), bad);
    await flush();
    fire(form(), 'submit');
    await flush();
    assert.equal(calls.filter((x) => x.method === 'PUT').length, 0, `no PUT for ${JSON.stringify(bad)}`);
    assert.match(c.text(), /whole number from 1 to 9999/);
  }
  typeInto(input(), '5');
  await flush();
  fire(form(), 'submit');
  await flush();
  const puts = calls.filter((x) => x.method === 'PUT');
  assert.equal(puts.length, 1);
  assert.deepEqual(puts[0].body, { name: 'wip-limit-a', active: 1, reason: 'set from Mission Control', value: '5' });
  assert.match(c.text(), /wip-limit-a set to 5/);
  assert.equal(domCell(c.root, 'a', 'WIP').textContent.replace(/SAVE/, '').trim(), 'none', 'no optimistic value');
  c.unmount();

  calls = stubFetch(state, () => [400, { error: 'value must be up to 64 characters of A-Za-z0-9._-' }]);
  c = await mountFleet();
  typeInto(input(), '7');
  await flush();
  fire(form(), 'submit');
  await flush();
  assert.match(c.text(), /wip-limit-a refused — value must be up to 64 characters/);
  assert.doesNotMatch(c.text(), /set to 7/);
  assert.ok(calls.filter((x) => x.method === 'GET' && x.url === '/api/coord/flags').length >= 2, 'a refused PUT still re-reads');
  assert.ok(!disabled(btnIn(domCell(c.root, 'a', 'WIP'), 'SAVE')), 'busy clears after a refusal');
  c.unmount();
});

test('F12: a failed flags read renders "—" with no PAUSE button on the mounted screen', async () => {
  const state = { ...base(), flagsStatus: 500 };
  stubFetch(state);
  const c = await mountFleet();
  for (const p of ['a', 'b']) {
    const cell = domCell(c.root, p, 'PAUSED');
    assert.equal(cell.textContent.trim(), '—');
    assert.equal(btnIn(cell, 'PAUSE'), undefined);
    assert.equal(btnIn(cell, 'RESUME'), undefined);
    assert.equal(domCell(c.root, p, 'WIP').textContent.replace(/SAVE/, '').trim(), '—');
  }
  c.unmount();
});
