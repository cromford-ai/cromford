import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

// BH-6350. A per-project dispatch mode: normal, hotfix-only (with an
// allow-list) or paused. paused is the paused-<p> row; hotfix-only is the
// dispatch-mode-<p> row (scope fleet) ON with a value the shell parser
// (bin/lib/dispatch-mode.sh dm_parse) reads the same way. C1-C2 drive the
// pure lib, C3 renders the real ProjectsTable, C4 mounts the real FleetScreen
// in a small fake DOM against a stubbed fetch, so every write goes through the
// real api.js. R1 runs the real shell parser on what the console writes.

globalThis.window = globalThis.window || {
  location: { pathname: '/', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const {
  modeOf, parseModeValue, formatModeValue, allowInputError, parseAllowInput, modeText, modeRank
} = await import('../src/lib/dispatch-mode.js');
const { shapeFleetCells } = await import('../src/lib/flagrows.js');
const { ProjectsTable, FleetScreen } = await import('../src/screens/Fleet.js');
const { FleetContext } = await import('../src/app.js');

const byName = (rows) => new Map(rows.map((r) => [r.name, r]));
const project = (name, extra = {}) => ({
  project: name, last_run_age_min: 3, last_summary: 'ok', last_rc: 0, paused: false, automerge: true, fleet: {}, ...extra
});

// ------------------------------------------------------------- C1, C2: lib

test('C1: modeOf reads paused, hotfix-only with its allow-list, and normal; an unread cell renders "—"', () => {
  const at = '2026-10-13T00:00:00Z';
  assert.equal(modeOf(byName([{ name: 'paused-p', active: 1 }]), 'p').mode, 'paused');
  // paused wins over a standing dispatch row.
  assert.equal(modeOf(byName([
    { name: 'paused-p', active: 1 }, { name: 'dispatch-mode-p', active: 1, value: 'hotfix-only:5' }
  ]), 'p').mode, 'paused');
  const hf = modeOf(byName([{ name: 'dispatch-mode-p', active: 1, value: 'hotfix-only:5', set_at: at }]), 'p');
  assert.equal(hf.mode, 'hotfix-only');
  assert.deepEqual(hf.allow, [5]);
  assert.equal(hf.set_at, at);
  assert.equal(modeOf(byName([]), 'p').mode, 'normal');
  assert.deepEqual(modeOf(byName([]), 'p').allow, []);
  // A cleared row, a row valued normal, and another project's row are normal.
  assert.equal(modeOf(byName([{ name: 'dispatch-mode-p', active: 0, value: 'hotfix-only' }]), 'p').mode, 'normal');
  assert.equal(modeOf(byName([{ name: 'dispatch-mode-p', active: 1, value: 'normal' }]), 'p').mode, 'normal');
  assert.equal(modeOf(byName([{ name: 'dispatch-mode-pq', active: 1, value: 'hotfix-only' }]), 'p').mode, 'normal');
  // ON with no value, or a value that does not parse, is the stricter mode.
  assert.equal(modeOf(byName([{ name: 'dispatch-mode-p', active: 1, value: null }]), 'p').mode, 'hotfix-only');
  assert.deepEqual(modeOf(byName([{ name: 'dispatch-mode-p', active: 1, value: 'hotfix-only:abc' }]), 'p').allow, []);
  // Through the shaper: flags not loaded is null, which renders "—".
  assert.equal(shapeFleetCells(null, null, ['p']).p.mode, null);
  assert.equal(modeText(null), '—');
  assert.equal(shapeFleetCells({ flags: [{ name: 'dispatch-mode-p', active: 1, value: 'hotfix-only:5' }] }, null, ['p']).p.mode.mode, 'hotfix-only');
  // A readable read with no dispatch-mode-p row is normal; the three BH-5643
  // cells ride along unchanged.
  assert.equal(shapeFleetCells({ flags: [] }, null, ['p']).p.mode.mode, 'normal');
  assert.deepEqual(Object.keys(shapeFleetCells(null, null, ['p']).p), ['paused', 'wip', 'route', 'mode']);
  assert.equal(modeText({ mode: 'normal', allow: [] }), 'normal');
  assert.equal(modeText({ mode: 'hotfix-only', allow: [] }), 'hotfix-only');
  assert.equal(modeText({ mode: 'hotfix-only', allow: [1, 2] }), 'hotfix-only (+2 allowed)');
  assert.equal(modeText({ mode: 'paused', allow: [] }), 'paused');
  assert.deepEqual(['normal', null, 'paused', 'hotfix-only'].sort((a, b) => modeRank(a) - modeRank(b)),
    ['paused', 'hotfix-only', 'normal', null]);
});

test('C1b: parseModeValue and formatModeValue follow the shell grammar', () => {
  assert.deepEqual(parseModeValue(null), { mode: 'hotfix-only', allow: [], bad: false });
  assert.deepEqual(parseModeValue(''), { mode: 'hotfix-only', allow: [], bad: false });
  assert.deepEqual(parseModeValue(' Normal '), { mode: 'normal', allow: [], bad: false });
  assert.deepEqual(parseModeValue('HOTFIX-ONLY'), { mode: 'hotfix-only', allow: [], bad: false });
  assert.deepEqual(parseModeValue('hotfix-only:6291, 6292'), { mode: 'hotfix-only', allow: [6291, 6292], bad: false });
  assert.deepEqual(parseModeValue('hotfix-only: 007 ,7,8'), { mode: 'hotfix-only', allow: [7, 8], bad: false });
  for (const bad of ['hotfix-only:abc', 'hotfix', 'hotfix-only:', 'hotfix-only:1,', 'hotfix-only:0', 'hotfix-only:1,000', 'hotfix-only:-1']) {
    assert.deepEqual(parseModeValue(bad), { mode: 'hotfix-only', allow: [], bad: true }, bad);
  }
  assert.equal(formatModeValue([]), 'hotfix-only');
  assert.equal(formatModeValue([6291, 6292]), 'hotfix-only:6291,6292');
});

test('C2: allowInputError takes comma or space separated whole issue numbers; empty is fine', () => {
  assert.equal(allowInputError('6291, 6292'), null);
  assert.equal(allowInputError('6291 6292'), null);
  assert.equal(allowInputError(''), null);
  assert.equal(allowInputError('   '), null);
  for (const bad of ['62a', '0', '-5', '1.5', '6291;6292', '#6291']) {
    assert.equal(allowInputError(bad), 'whole issue numbers, comma separated', bad);
  }
  assert.match(allowInputError(Array.from({ length: 41 }, (_, i) => i + 1).join(',')) || '', /at most 40/);
  assert.equal(allowInputError(Array.from({ length: 40 }, (_, i) => i + 1).join(',')), null);
  assert.match(allowInputError(Array.from({ length: 40 }, (_, i) => String(100000000000 + i)).join(',')) || '', /512/);
  assert.deepEqual(parseAllowInput(' 6291, 6292 6291 '), [6291, 6292]);
  assert.deepEqual(parseAllowInput(''), []);
});

// ------------------------------------------------------------- fake DOM
// The same small DOM the BH-5643 suite mounts FleetScreen in.
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
const attr = (n, k) => n.getAttribute(k) ?? (n[k] === undefined ? null : String(n[k]));
const disabled = (n) => {
  const v = n.getAttribute('disabled') ?? (n.disabled === undefined ? null : n.disabled);
  return v !== null && v !== false && v !== 'false';
};
const confirmBtn = (root) => {
  const actions = all(root).find((n) => /\bmodal__actions\b/.test(n.attrs.class || ''));
  return actions && actions.childNodes.filter((n) => n.localName === 'button').pop();
};
const modalBody = (root) => all(root).find((n) => /\bmodal__body\b/.test(n.attrs.class || ''));
const byLabel = (root, label) => all(modalBody(root)).find((n) => n.localName === 'input' && attr(n, 'aria-label') === label);
const radio = (root, v) => all(modalBody(root)).find((n) => n.localName === 'input' && attr(n, 'type') === 'radio' && attr(n, 'value') === v);
const typeInto = (node, v) => { node.value = v; fire(node, 'input'); };
const btnIn = (node, label) => all(node).find((n) => n.localName === 'button' && n.textContent.trim() === label);
const projectsTable = (root) => all(root).find((n) => n.localName === 'table'
  && all(n).some((x) => x.localName === 'th' && x.textContent.trim().startsWith('MODE')));
const domCell = (root, name, label) => {
  const table = projectsTable(root);
  assert.ok(table, 'the PROJECTS table with a MODE header');
  const ths = all(table).filter((n) => n.localName === 'th');
  const i = ths.findIndex((t) => t.textContent.replace(/[↑↓]/g, '').trim().startsWith(label));
  assert.ok(i >= 0, `a ${label} header`);
  const tr = all(table).find((n) => n.localName === 'tr'
    && n.childNodes[0] && n.childNodes[0].localName === 'td' && n.childNodes[0].textContent.trim() === name);
  assert.ok(tr, `a row for ${name}`);
  return tr.childNodes.filter((c) => c.localName === 'td')[i];
};
const modeTag = (cell) => all(cell).find((n) => /\btag\b|\bna\b/.test(n.attrs.class || ''));

const mounted = new Set();
test.afterEach(() => { for (const root of mounted) mount(null, root); mounted.clear(); });
function mountNode(vnode) {
  installDom();
  const root = globalThis.document.createElement('div');
  mount(vnode, root);
  mounted.add(root);
  return root;
}

// ------------------------------------------------------------- C3: table

test('C3: the MODE cell reads hotfix-only (+2 allowed), its header sorts, and it links to /flags and the issues', async () => {
  const cells = shapeFleetCells({ flags: [
    { name: 'dispatch-mode-p', active: 1, value: 'hotfix-only:6291,6292', set_at: '2026-10-13T00:00:00Z' },
    { name: 'paused-q', active: 1 }
  ] }, null, ['p', 'q', 'r']);
  const rows = [project('p', { repo: 'example-org/cromford' }), project('q'), project('r')];
  const root = mountNode(h(ProjectsTable, { rows, recentRuns: {}, flagCells: cells, onPause() {}, onSaveWip() {}, onSetMode() {} }));
  await flush();
  const cell = domCell(root, 'p', 'MODE');
  assert.equal(modeTag(cell).textContent.trim(), 'hotfix-only (+2 allowed)');
  assert.match(attr(modeTag(cell), 'title') || '', /6291, 6292/);
  assert.match(attr(modeTag(cell), 'title') || '', /2026-10-13T00:00:00Z/);
  assert.ok(all(cell).some((n) => n.localName === 'a' && attr(n, 'href') === '/flags'), 'a link to /flags');
  assert.ok(all(cell).some((n) => n.localName === 'a' && attr(n, 'href') === 'https://github.com/example-org/cromford/issues/6291'),
    'an allow-list number links to its issue');
  assert.ok(btnIn(cell, 'SET'), 'a SET button');
  assert.equal(modeTag(domCell(root, 'q', 'MODE')).textContent.trim(), 'paused');
  assert.equal(modeTag(domCell(root, 'r', 'MODE')).textContent.trim(), 'normal');
  // No repo slug: the numbers are plain text, never a guessed link.
  const noRepo = mountNode(h(ProjectsTable, { rows: [project('p')], recentRuns: {}, flagCells: cells, onSetMode() {} }));
  await flush();
  assert.ok(!all(domCell(noRepo, 'p', 'MODE')).some((n) => n.localName === 'a' && /github\.com/.test(attr(n, 'href') || '')));

  // The header is a sortable column: aria-sort moves on each click.
  const th = () => all(projectsTable(root)).find((n) => n.localName === 'th' && n.textContent.replace(/[↑↓]/g, '').trim() === 'MODE');
  assert.equal(attr(th(), 'aria-sort'), 'none');
  fire(all(th()).find((n) => n.localName === 'button'), 'click');
  await flush();
  const first = attr(th(), 'aria-sort');
  assert.ok(['ascending', 'descending'].includes(first), `sorted after a click, got ${first}`);
  // Ascending by rank: paused, hotfix-only, normal.
  const order = () => all(projectsTable(root)).filter((n) => n.localName === 'tr' && n.childNodes[0] && n.childNodes[0].localName === 'td')
    .map((tr) => tr.childNodes[0].textContent.trim());
  if (first === 'ascending') assert.deepEqual(order(), ['q', 'p', 'r']);
  fire(all(th()).find((n) => n.localName === 'button'), 'click');
  await flush();
  assert.notEqual(attr(th(), 'aria-sort'), first, 'the second click flips the direction');
});

// ------------------------------------------------------------- C4: SET dialog

function stubFetch(state) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    const method = init.method || 'GET';
    const body = init.body ? JSON.parse(init.body) : null;
    calls.push({ url: u, method, body });
    let res;
    if (method !== 'GET') res = { ok: true };
    else if (u === '/api/dash/projects') res = { projects: state.projects, projects_source: 'fleet_status', snapshot_age_min: 1 };
    else if (u === '/api/coord/flags') res = { flags: state.flags };
    else if (u === '/api/coord/routing') res = { routing: [] };
    else res = {};
    return { ok: true, status: 200, text: async () => JSON.stringify(res) };
  };
  return calls;
}
async function mountFleet() {
  const root = mountNode(h(FleetContext.Provider, { value: { data: null } }, h(FleetScreen)));
  await flush();
  return root;
}
const writes = (calls) => calls.filter((x) => x.method !== 'GET');

test('C4: SET hotfix-only PUTs dispatch-mode-p once; normal on a hotfix-only row DELETEs it with the reason; Escape writes nothing', async () => {
  // hotfix-only from normal.
  let calls = stubFetch({ projects: [project('p')], flags: [] });
  let root = await mountFleet();
  assert.equal(modeTag(domCell(root, 'p', 'MODE')).textContent.trim(), 'normal');
  fire(btnIn(domCell(root, 'p', 'MODE'), 'SET'), 'click');
  await flush();
  assert.match(root.textContent, /SET MODE p/);
  assert.ok(disabled(confirmBtn(root)), 'confirm is blocked until a reason is typed');
  assert.ok(disabled(byLabel(root, 'allow-list')), 'the allow-list is off until hotfix-only is chosen');
  fire(radio(root, 'hotfix-only'), 'change');
  await flush();
  assert.ok(!disabled(byLabel(root, 'allow-list')));
  typeInto(byLabel(root, 'reason'), 'r');
  typeInto(byLabel(root, 'allow-list'), '62a');
  await flush();
  assert.match(modalBody(root).textContent, /whole issue numbers, comma separated/);
  assert.ok(disabled(confirmBtn(root)), 'a bad allow-list blocks confirm');
  typeInto(byLabel(root, 'allow-list'), '6291,6292');
  await flush();
  assert.doesNotMatch(modalBody(root).textContent, /whole issue numbers/);
  assert.ok(!disabled(confirmBtn(root)));
  fire(confirmBtn(root), 'click');
  await flush();
  let w = writes(calls);
  assert.equal(w.length, 1, `one write, got ${JSON.stringify(w)}`);
  assert.equal(w[0].method, 'PUT');
  assert.equal(w[0].url, '/api/coord/flags');
  assert.equal(w[0].body.name, 'dispatch-mode-p');
  assert.equal(w[0].body.active, 1);
  assert.equal(w[0].body.value, 'hotfix-only:6291,6292');
  assert.equal(w[0].body.reason, 'r');
  mount(null, root); mounted.delete(root);

  // normal from hotfix-only: one DELETE through the coord proxy, with the reason.
  calls = stubFetch({ projects: [project('p')], flags: [{ name: 'dispatch-mode-p', active: 1, value: 'hotfix-only:5' }] });
  root = await mountFleet();
  assert.equal(modeTag(domCell(root, 'p', 'MODE')).textContent.trim(), 'hotfix-only (+1 allowed)');
  fire(btnIn(domCell(root, 'p', 'MODE'), 'SET'), 'click');
  await flush();
  fire(radio(root, 'normal'), 'change');
  typeInto(byLabel(root, 'reason'), 'back to normal');
  await flush();
  fire(confirmBtn(root), 'click');
  await flush();
  w = writes(calls);
  assert.equal(w.length, 1, `one write, got ${JSON.stringify(w)}`);
  assert.equal(w[0].method, 'DELETE');
  const u = new URL(w[0].url, 'https://mc.example');
  assert.equal(u.pathname, '/api/coord/flags');
  assert.equal(u.searchParams.get('name'), 'dispatch-mode-p');
  assert.equal(u.searchParams.get('scope'), 'fleet');
  assert.equal(u.searchParams.get('reason'), 'back to normal');

  // paused: one PUT of paused-p on.
  calls = stubFetch({ projects: [project('p')], flags: [] });
  fire(btnIn(domCell(root, 'p', 'MODE'), 'SET'), 'click');
  await flush();
  fire(radio(root, 'paused'), 'change');
  typeInto(byLabel(root, 'reason'), 'hold');
  await flush();
  fire(confirmBtn(root), 'click');
  await flush();
  w = writes(calls);
  assert.equal(w.length, 1);
  assert.equal(w[0].body.name, 'paused-p');
  assert.equal(w[0].body.active, 1);
  assert.equal(w[0].body.reason, 'hold');

  // Escape closes the dialog and writes nothing.
  calls = stubFetch({ projects: [project('p')], flags: [] });
  fire(btnIn(domCell(root, 'p', 'MODE'), 'SET'), 'click');
  await flush();
  fire(radio(root, 'hotfix-only'), 'change');
  typeInto(byLabel(root, 'reason'), 'r');
  await flush();
  fire(globalThis.document, 'keydown', { key: 'Escape' });
  await flush();
  assert.equal(modalBody(root), undefined, 'the dialog is closed');
  assert.equal(writes(calls).length, 0);
  assert.ok(!disabled(btnIn(domCell(root, 'p', 'MODE'), 'SET')), 'SET is free again after a cancel');
});

// ------------------------------------------------------------- R1: shell

const LIB = fileURLToPath(new URL('../../bin/lib/dispatch-mode.sh', import.meta.url));
let hasBash = true;
try { execFileSync('bash', ['-c', 'true']); } catch { hasBash = false; }
const dmParse = (v) => execFileSync('bash',
  ['-c', '. "$1"; dm_parse "$2"; printf "%s|%s|%s\\n" "$DM_MODE" "$DM_ALLOW" "$DM_BAD"', '_', LIB, v],
  { encoding: 'utf8' }).trim();

test('R1: what formatModeValue writes, the shell dm_parse reads back the same; both parsers agree', { skip: hasBash ? false : 'skip: bash is not on this host' }, () => {
  for (const allow of [[], [6291], [6291, 6292], [1, 22, 333]]) {
    assert.equal(dmParse(formatModeValue(allow)), `hotfix-only|${allow.join(' ')}|0`, JSON.stringify(allow));
  }
  for (const v of ['', 'normal', ' NORMAL ', 'hotfix-only', 'hotfix-only:6291, 6292', 'hotfix-only: 007 ,7',
    'hotfix-only:abc', 'hotfix', 'hotfix-only:0', 'hotfix-only:1,']) {
    const p = parseModeValue(v);
    assert.equal(dmParse(v), `${p.mode}|${p.allow.join(' ')}|${p.bad ? 1 : 0}`, JSON.stringify(v));
  }
});
