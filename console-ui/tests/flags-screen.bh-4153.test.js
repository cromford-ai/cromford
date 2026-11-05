import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

// BH-4153 (BH-4141.1): the /flags screen, every flag row from both stores with
// its scope, a SET FLAG… and a CLEAR that each go through an in-app modal with
// a required reason. The pure half (lib/flags.js) is driven directly,
// FlagsView is rendered server-side for every load state, and the routed
// FlagsScreen (the real ROUTES table and matchRoute) is mounted into a small
// fake DOM against a stubbed fetch, so every read and write goes through the
// real api.js. The coord proxy rows are driven through the real onRequest.

globalThis.window = globalThis.window || {
  location: { pathname: '/flags', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const lib = await import('../src/lib/flags.js');
const { flagRowsAll, flagProject, setBody, clearQuery, validateFlagName, validateScope } = lib;
const { FlagsView } = await import('../src/screens/Flags.js');
const { ConfigView } = await import('../src/screens/Config.js');
const { ROUTES, NAV, FleetContext } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const { onRequest } = await import('../functions/api/coord/[[path]].js');
const { render } = await import('preact-render-to-string');

// ---------------------------------------------------------------- fixtures
// Fixed instants only; no case asserts an age, so the wall clock never matters.
const FLAGS = [
  { scope: 'fleet', name: 'paused-project-3', value: null, set_by: 'console', reason: 'deploy freeze', set_at: '2026-10-01T10:00:00Z', cleared_at: null, active: 1, actor: 'console', updated_at: '2026-10-01T10:00:00Z' },
  { scope: 'fleet', name: 'automerge-disabled', value: null, set_by: 'hub-1', reason: 'main is red', set_at: '2026-10-01T09:00:00Z', cleared_at: null, active: 1, actor: 'hub-1', updated_at: '2026-10-01T09:00:00Z' },
  { scope: 'boxa', name: 'lanedown-boxa-codex-20261003', value: '3', set_by: 'boxa', reason: 'canary failed', set_at: '2026-10-03T00:00:00Z', cleared_at: null, active: 1, actor: 'boxa', updated_at: '2026-10-03T00:00:00Z' },
  { scope: 'fleet', name: 'paused-ghost', value: null, set_by: 'console', reason: 'old project', set_at: '2026-09-01T00:00:00Z', cleared_at: null, active: 1, actor: 'console', updated_at: '2026-09-01T00:00:00Z' },
  { scope: 'fleet', name: 'alerts-db', value: null, set_by: 'operator', reason: 'quiet hours', set_at: '2026-09-30T00:00:00Z', cleared_at: '2026-10-02T00:00:00Z', active: 0, actor: 'operator', updated_at: '2026-10-02T00:00:00Z' },
  { scope: 'fleet', name: 'paused-project-2', value: null, set_by: 'console', reason: 'resumed', set_at: '2026-09-29T00:00:00Z', cleared_at: '2026-10-02T12:00:00Z', active: 0, actor: 'console', updated_at: '2026-10-02T12:00:00Z' }
];
const PROJECTS = ['project-3', 'project-2'];
const ok = (data) => ({ data, error: null, loading: false, reload() {} });
const view = (over = {}) => render(h(FlagsView, {
  flags: ok({ flags: FLAGS, as_of: '2026-10-03T00:00:00Z' }), projects: PROJECTS,
  filter: '', showCleared: false, onFilter() {}, onShowCleared() {}, onSet() {}, onClear() {},
  busy: false, note: null, dialog: null, ...over
}));
const count = (hay, re) => (hay.match(re) || []).length;

// ------------------------------------------------------------ pure helpers
test('L1: flagRowsAll hides cleared rows by default and shows them with SHOW CLEARED', () => {
  const on = flagRowsAll({ flags: FLAGS }, {});
  assert.deepEqual(on.rows.map((r) => r.name).sort(),
    ['automerge-disabled', 'lanedown-boxa-codex-20261003', 'paused-ghost', 'paused-project-3']);
  assert.ok(on.rows.every((r) => r.on === true));
  assert.equal(on.hidden, 2, 'it counts what it hid');
  const all = flagRowsAll({ flags: FLAGS }, { showCleared: true });
  assert.equal(all.rows.length, FLAGS.length);
  assert.equal(all.rows.find((r) => r.name === 'alerts-db').on, false);
  assert.equal(all.hidden, 0);
});

test('L2: the filter matches name, scope and reason, case blind', () => {
  const names = (f, showCleared = false) => flagRowsAll({ flags: FLAGS }, { filter: f, showCleared }).rows.map((r) => r.name).sort();
  assert.deepEqual(names('project-3'), ['paused-project-3']);
  assert.deepEqual(names('boxa'), ['lanedown-boxa-codex-20261003'], 'scope');
  assert.deepEqual(names('main is'), ['automerge-disabled'], 'reason');
  assert.deepEqual(names('quiet'), [], 'a cleared row stays hidden under a matching filter');
  assert.deepEqual(names('quiet', true), ['alerts-db']);
  assert.deepEqual(names('   '), names(''), 'a blank filter is no filter');
});

test('L3: a read with no flags array is a failed read (null), never an empty list; truncated passes through', () => {
  assert.equal(flagRowsAll(null, {}), null);
  assert.equal(flagRowsAll({ error: 'x' }, {}), null);
  assert.equal(flagRowsAll({ flags: {} }, {}), null);
  assert.equal(flagRowsAll({ flags: FLAGS }, {}).truncated, false);
  assert.equal(flagRowsAll({ flags: FLAGS, truncated: true }, {}).truncated, true);
  assert.deepEqual(flagRowsAll({ flags: [] }, {}).rows, []);
});

test('L4: flagProject names a project only for paused-<p> / automerge-disabled-<p> with <p> in the fleet', () => {
  assert.equal(flagProject('paused-project-3', PROJECTS), 'project-3');
  assert.equal(flagProject('automerge-disabled-project-2', PROJECTS), 'project-2');
  assert.equal(flagProject('paused-ghost', PROJECTS), null, 'not a fleet project');
  assert.equal(flagProject('paused-all', PROJECTS), null);
  assert.equal(flagProject('automerge-disabled', PROJECTS), null);
  assert.equal(flagProject('lanedown-project-3', PROJECTS), null);
  assert.equal(flagProject('xpaused-project-3', PROJECTS), null);
  assert.equal(flagProject('paused-project-3', null), null, 'no project list, no link');
});

test('L5: validateFlagName uses the worker alphabet; validateScope takes fleet or a box name', () => {
  assert.deepEqual(validateFlagName(' paused-project-3 '), { ok: true, value: 'paused-project-3' });
  assert.equal(validateFlagName('').ok, false);
  assert.equal(validateFlagName('paused project-3').ok, false);
  assert.equal(validateFlagName('paused/project-3').ok, false);
  assert.equal(validateFlagName('a'.repeat(128)).ok, true);
  assert.equal(validateFlagName('a'.repeat(129)).ok, false);
  assert.match(validateFlagName('x y').message, /letters, digits/);
  assert.deepEqual(validateScope(''), { ok: true, value: 'fleet' });
  assert.deepEqual(validateScope('fleet'), { ok: true, value: 'fleet' });
  assert.deepEqual(validateScope(' boxa '), { ok: true, value: 'boxa' });
  assert.equal(validateScope('a'.repeat(65)).ok, false);
  assert.equal(validateScope('box a').ok, false);
});

test('L6: setBody is {name, scope, value, active:1, reason}; clearQuery is name&scope&reason', () => {
  assert.deepEqual(setBody({ name: ' paused-project-3 ', scope: '', value: '', reason: ' deploy ' }),
    { name: 'paused-project-3', scope: 'fleet', value: null, active: 1, reason: 'deploy' });
  assert.deepEqual(setBody({ name: 'lanedown-x', scope: 'boxa', value: ' 3 ', reason: 'r' }),
    { name: 'lanedown-x', scope: 'boxa', value: '3', active: 1, reason: 'r' });
  const q = new URLSearchParams(clearQuery({ name: 'paused-project-3', scope: 'fleet', reason: ' done & dusted ' }));
  assert.deepEqual([...q.keys()], ['name', 'scope', 'reason']);
  assert.equal(q.get('reason'), 'done & dusted');
  assert.equal(new URLSearchParams(clearQuery({ name: 'n', reason: 'r' })).get('scope'), 'fleet');
});

// ------------------------------------------------------------ server render
test('R1: every header but ACTION has aria-sort, inside a wide .tablewrap; NAME sorts ascending by default', () => {
  const out = view();
  assert.equal(count(out, /class="tablewrap tablewrap--wide"/g), 1);
  for (const label of ['SCOPE', 'NAME', 'PROJECT', 'VALUE', 'STATE', 'SET BY', 'SET AT', 'CLEARED AT', 'REASON']) {
    assert.match(out, new RegExp(`<th aria-sort="(ascending|descending|none)"[^>]*><button[^>]*>\\s*${label}`), label);
  }
  assert.equal(count(out, /aria-sort="/g), 9);
  assert.match(out, /<th(?![^>]*aria-sort)[^>]*>ACTION/);
  assert.match(out, /<th aria-sort="ascending"[^>]*><button[^>]*>\s*NAME/);
});

test('R2: NAME links to its history; PROJECT links only for a fleet project; a box scope links to /machines', () => {
  const out = view();
  for (const r of FLAGS.filter((x) => x.cleared_at === null)) {
    assert.match(out, new RegExp(`<a[^>]*href="/config/flag/${r.name}"`), r.name);
  }
  assert.match(out, /<a[^>]*href="\/p\/project-3"[^>]*>project-3<\/a>/);
  assert.doesNotMatch(out, /href="\/p\/ghost"/, 'paused-ghost is not a fleet project');
  assert.match(out, /<a[^>]*href="\/machines"[^>]*>boxa<\/a>/);
  assert.doesNotMatch(out, /<a[^>]*href="\/machines"[^>]*>fleet<\/a>/, 'fleet is not a box');
  assert.equal(count(out, />CLEAR</g), 4, 'one CLEAR per ON row');
  assert.equal(count(out, />cleared</g), 0, 'cleared rows are hidden by default');
  assert.doesNotMatch(out, /<input[^>]*type="checkbox"[^>]*checked/, 'SHOW CLEARED is off by default');
  assert.match(out, />SET FLAG…</);
});

test('R3: with SHOW CLEARED, a cleared row reads cleared, has no CLEAR, and an ON row reads — under CLEARED AT', () => {
  const out = view({ showCleared: true });
  assert.equal(count(out, />cleared</g), 2);
  assert.equal(count(out, />CLEAR</g), 4);
  assert.match(out, /<a[^>]*href="\/p\/project-2"/);
  assert.match(out, /<input[^>]*type="checkbox"[^>]*checked/);
});

test('R4 (D7): zero rows is the empty state; a failed read is an ErrorBox with RETRY; truncated says so', () => {
  const empty = view({ flags: ok({ flags: [] }) });
  assert.match(empty, /no flags/);
  assert.doesNotMatch(empty, /could not load/);
  assert.doesNotMatch(empty, /<table/);

  const failed = view({ flags: { data: null, error: new Error('network unreachable'), loading: false, reload() {} } });
  assert.match(failed, /could not load — <b>network unreachable/);
  assert.match(failed, />RETRY</);
  assert.doesNotMatch(failed, /no flags/);

  const bad = view({ flags: ok({ error: 'x' }) });
  assert.match(bad, /could not load/);
  assert.doesNotMatch(bad, /no flags/);

  const kept = view({ flags: { data: { flags: FLAGS }, error: new Error('timeout'), loading: false, reload() {} } });
  assert.match(kept, /could not load — <b>timeout/);
  assert.match(kept, /href="\/config\/flag\/paused-project-3"/, 'a failed poll keeps the rows');

  assert.match(view({ flags: ok({ flags: FLAGS, truncated: true }) }), /truncated/);
  assert.doesNotMatch(view(), /truncated/);
  assert.match(view({ filter: 'zzz' }), /no flag matches/);
});

test('R5: no native dialogs and no em dashes in the new copy', async () => {
  const { readFileSync } = await import('node:fs');
  for (const f of ['../src/screens/Flags.js', '../src/lib/flags.js']) {
    const src = readFileSync(new URL(f, import.meta.url), 'utf8');
    const code = src.split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
    assert.doesNotMatch(code, /window\.(confirm|alert|prompt)\s*\(|\b(confirm|alert|prompt)\s*\(/, f);
    // The em dash is only the shared "no value" cell mark, never prose.
    const dashes = code.split('\n').filter((l) => l.includes('—') && !/'—'|"—"|>—</.test(l));
    assert.deepEqual(dashes, [], `${f}: an em dash in copy`);
  }
});

test('N1: /flags is routed and rides the SETTINGS nav tab; /config links ALL FLAGS →', () => {
  assert.ok(ROUTES.find(([p]) => p === '/flags'), '/flags is in ROUTES');
  const settings = NAV.find((n) => n.label === 'SETTINGS');
  assert.equal(settings.match('/flags'), true);
  assert.equal(NAV.filter((n) => n.match('/flags')).length, 1, 'no new nav slot');
  const out = render(h(ConfigView, {
    settings: ok({ settings: [] }), flags: ok({ flags: [] }),
    changes: { loading: false, error: null, data: { changes: [], truncated: false } }
  }));
  assert.match(out, /<a[^>]*href="\/flags"[^>]*>ALL FLAGS →<\/a>/);
});

// ------------------------------------------------------------- fake DOM
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
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const fire = (node, type, extra = {}) => {
  const key = Object.keys(node.listeners).find((k) => k.toLowerCase() === type);
  assert.ok(key, `a ${type} listener on <${node.localName}>`);
  return node.listeners[key].call(node, { type: key, target: node, currentTarget: node, button: 0, preventDefault() {}, ...extra });
};
const buttons = (root, label) => all(root).filter((n) => n.localName === 'button' && n.textContent.trim() === label);
const byLabel = (root, label) => all(root).find((n) => (n.localName === 'input') && n.attrs['aria-label'] === label);
const typeInto = (node, v) => { node.value = v; fire(node, 'input'); };
const confirmBtn = (root) => {
  const actions = all(root).find((n) => /\bmodal__actions\b/.test(n.attrs.class || ''));
  return actions && actions.childNodes.filter((n) => n.localName === 'button').pop();
};
const modalOpen = (root) => all(root).some((n) => /\bmodal__body\b/.test(n.attrs.class || ''));
const modalText = (root) => all(root).filter((n) => /\bmodal\b/.test(n.attrs.class || '')).map((n) => n.textContent).join(' ');
const disabled = (n) => n.getAttribute('disabled') !== null && n.getAttribute('disabled') !== 'false';
// The NAME cell text of each body row, top to bottom.
const rowNames = (root) => all(root).filter((n) => n.localName === 'tbody')
  .flatMap((tb) => tb.childNodes.filter((tr) => tr.localName === 'tr')).map((tr) => tr.childNodes[1].textContent.trim());
const header = (root, label) => all(root).find((n) => n.localName === 'th' && n.textContent.trim().startsWith(label));
const pressKey = (key) => {
  const fn = globalThis.document.listeners.keydown;
  assert.ok(fn, 'the modal listens for keys');
  fn({ key, preventDefault() {}, shiftKey: false });
};

// Every GET answers the fixtures; a write answers what `write` says.
function stubFetch({ write = () => [200, { ok: true }] } = {}) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    const method = init.method || 'GET';
    calls.push({ url: u, method, body: init.body ? JSON.parse(init.body) : null });
    let status = 200; let body;
    if (method !== 'GET') [status, body] = write(u, init);
    else if (u.startsWith('/api/coord/flags')) body = { flags: FLAGS, as_of: '2026-10-03T00:00:00Z' };
    else body = {};
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) };
  };
  return calls;
}

// A failed assertion must not leave the screen mounted: its 60 s poll would
// keep node alive and the run would hang instead of going red.
let mounted = null;
afterEach(() => { if (mounted) { mounted.unmount(); mounted = null; } });

async function mountFlags() {
  const doc = installDom();
  const hit = ROUTES.map(([p, C]) => [matchRoute(p, '/flags'), C]).find(([params]) => params);
  assert.ok(hit, 'a route matches /flags');
  const root = doc.createElement('div');
  const vnode = () => h(FleetContext.Provider, { value: { data: { projects: PROJECTS } } }, h(hit[1], hit[0]));
  mount(vnode(), root);
  await flush();
  mounted = { root, text: () => root.textContent, rerender: () => mount(vnode(), root), unmount: () => mount(null, root) };
  return mounted;
}

test('M1: the mounted screen reads /api/coord/flags, links PROJECT from the fleet list, and a header click toggles the sort', async () => {
  const calls = stubFetch();
  const c = await mountFlags();
  assert.ok(calls.some((x) => x.method === 'GET' && x.url.startsWith('/api/coord/flags')));
  assert.deepEqual(rowNames(c.root), ['automerge-disabled', 'lanedown-boxa-codex-20261003', 'paused-ghost', 'paused-project-3']);
  const project_3 = all(c.root).find((n) => n.localName === 'a' && n.attrs.href === '/p/project-3');
  assert.ok(project_3, 'PROJECT links project-3, a fleet project');
  assert.ok(!all(c.root).some((n) => n.localName === 'a' && n.attrs.href === '/p/ghost'));

  fire(all(header(c.root, 'NAME')).find((n) => n.localName === 'button'), 'click');
  await flush();
  assert.equal(header(c.root, 'NAME').getAttribute('aria-sort'), 'descending');
  assert.deepEqual(rowNames(c.root), ['paused-project-3', 'paused-ghost', 'lanedown-boxa-codex-20261003', 'automerge-disabled']);
  c.unmount();
});

test('M2: with SHOW CLEARED, a null CLEARED AT sorts last in both directions', async () => {
  stubFetch();
  const c = await mountFlags();
  const box = all(c.root).find((n) => n.localName === 'input' && n.attrs.type === 'checkbox');
  assert.ok(box, 'a SHOW CLEARED checkbox');
  box.checked = true;
  fire(box, 'change');
  await flush();
  assert.equal(rowNames(c.root).length, FLAGS.length);
  const sortBy = async () => { fire(all(header(c.root, 'CLEARED AT')).find((n) => n.localName === 'button'), 'click'); await flush(); };
  await sortBy();
  assert.equal(header(c.root, 'CLEARED AT').getAttribute('aria-sort'), 'ascending');
  let names = rowNames(c.root);
  assert.deepEqual(names.slice(0, 2), ['alerts-db', 'paused-project-2']);
  assert.ok(names.slice(2).every((n) => FLAGS.find((r) => r.name === n).cleared_at === null), 'nulls last ascending');
  await sortBy();
  assert.equal(header(c.root, 'CLEARED AT').getAttribute('aria-sort'), 'descending');
  names = rowNames(c.root);
  assert.deepEqual(names.slice(0, 2), ['paused-project-2', 'alerts-db']);
  assert.ok(names.slice(2).every((n) => FLAGS.find((r) => r.name === n).cleared_at === null), 'nulls last descending');
  c.unmount();
});

test('M3: SET FLAG… blocks confirm with an inline hint until NAME and REASON are valid; a refusal stays in the modal with the draft', async () => {
  let answer = [400, { error: 'name must match the flag alphabet' }];
  const calls = stubFetch({ write: () => answer });
  const c = await mountFlags();
  fire(buttons(c.root, 'SET FLAG…')[0], 'click');
  await flush();
  assert.ok(modalOpen(c.root));
  const name = byLabel(c.root, 'name');
  const scope = byLabel(c.root, 'scope');
  const value = byLabel(c.root, 'value');
  const reason = byLabel(c.root, 'reason');
  assert.ok(name && scope && value && reason, 'NAME, SCOPE, VALUE and REASON inputs');
  assert.equal(scope.getAttribute('value') ?? scope.value, 'fleet', 'scope starts at fleet');
  assert.ok(disabled(confirmBtn(c.root)), 'confirm starts blocked');
  assert.match(modalText(c.root), /needs a name and a reason/);

  typeInto(name, 'paused project-3');
  typeInto(reason, 'deploy freeze');
  await flush();
  assert.ok(disabled(confirmBtn(c.root)), 'a name outside the alphabet blocks');
  assert.match(modalText(c.root), /letters, digits/);
  typeInto(name, 'paused-project-3');
  typeInto(reason, '  ');
  await flush();
  assert.ok(disabled(confirmBtn(c.root)), 'a blank reason blocks');
  typeInto(reason, 'deploy freeze');
  typeInto(scope, 'box a');
  await flush();
  assert.ok(disabled(confirmBtn(c.root)), 'a bad scope blocks');
  typeInto(scope, 'fleet');
  await flush();
  assert.ok(!disabled(confirmBtn(c.root)), 'valid name and reason enable confirm');

  fire(confirmBtn(c.root), 'click');
  await flush();
  const put = calls.filter((x) => x.method === 'PUT').pop();
  assert.equal(put.url, '/api/coord/flags');
  assert.deepEqual(put.body, { name: 'paused-project-3', scope: 'fleet', value: null, active: 1, reason: 'deploy freeze' });
  assert.ok(modalOpen(c.root), 'a refusal keeps the modal open');
  assert.match(modalText(c.root), /refused: name must match the flag alphabet/);
  assert.equal(byLabel(c.root, 'reason').value, 'deploy freeze', 'the draft is kept');
  assert.equal(byLabel(c.root, 'name').value, 'paused-project-3');

  answer = [200, { ok: true }];
  const before = calls.length;
  fire(confirmBtn(c.root), 'click');
  await flush();
  assert.ok(!modalOpen(c.root), 'a 2xx closes the modal');
  assert.match(c.text(), /paused-project-3 set/);
  assert.ok(calls.slice(before).some((x) => x.method === 'GET' && x.url.startsWith('/api/coord/flags')), 're-reads the list');
  c.unmount();
});

test('M4: CLEAR needs a reason and sends DELETE name&scope&reason; Escape cancels with no write', async () => {
  let answer = [409, { error: 'row moved' }];
  const calls = stubFetch({ write: () => answer });
  const c = await mountFlags();
  const row = all(c.root).find((n) => n.localName === 'tr' && n.childNodes[1] && n.childNodes[1].textContent.trim() === 'lanedown-boxa-codex-20261003');
  fire(all(row).find((n) => n.localName === 'button' && n.textContent.trim() === 'CLEAR'), 'click');
  await flush();
  assert.ok(modalOpen(c.root));
  assert.equal(byLabel(c.root, 'name'), undefined, 'CLEAR asks only for a reason');
  const reason = byLabel(c.root, 'reason');
  assert.ok(reason);
  assert.ok(disabled(confirmBtn(c.root)));
  typeInto(reason, 'lane is back');
  await flush();
  assert.ok(!disabled(confirmBtn(c.root)));
  fire(confirmBtn(c.root), 'click');
  await flush();
  const del = calls.filter((x) => x.method === 'DELETE').pop();
  const u = new URL(del.url, 'https://x');
  assert.equal(u.pathname, '/api/coord/flags');
  assert.deepEqual([...u.searchParams.entries()], [['name', 'lanedown-boxa-codex-20261003'], ['scope', 'boxa'], ['reason', 'lane is back']]);
  assert.equal(del.body, null, 'no body on the DELETE');
  assert.ok(modalOpen(c.root), 'a refusal keeps the modal open');
  assert.match(modalText(c.root), /refused: row moved/);
  assert.equal(byLabel(c.root, 'reason').value, 'lane is back');

  answer = [200, { ok: true }];
  fire(confirmBtn(c.root), 'click');
  await flush();
  assert.ok(!modalOpen(c.root), 'a 2xx closes it');
  assert.match(c.text(), /lanedown-boxa-codex-20261003 cleared/);

  // Escape cancels a fresh one and writes nothing.
  const writes = calls.filter((x) => x.method !== 'GET').length;
  fire(buttons(c.root, 'CLEAR')[0], 'click');
  await flush();
  typeInto(byLabel(c.root, 'reason'), 'never sent');
  await flush();
  pressKey('Escape');
  await flush();
  assert.ok(!modalOpen(c.root), 'Escape closes');
  assert.equal(calls.filter((x) => x.method !== 'GET').length, writes);
  c.unmount();
});

test('M5: a re-render mid-typing (the 60s poll) keeps the SET draft', async () => {
  stubFetch();
  const c = await mountFlags();
  fire(buttons(c.root, 'SET FLAG…')[0], 'click');
  await flush();
  const name = byLabel(c.root, 'name');
  typeInto(name, 'paused-project-3');
  typeInto(byLabel(c.root, 'reason'), 'half typed');
  await flush();
  c.rerender();
  await flush();
  assert.equal(byLabel(c.root, 'name'), name, 'the same input node');
  assert.equal(byLabel(c.root, 'reason').value, 'half typed');
  c.unmount();
});

// ---------------------------------------------------------------- proxy
const JOBS = 'https://harness-jobs.operator.workers.dev';
function stubUpstream() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith('https://harness-console.operator.workers.dev')) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response('{"ok":true}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}
let cookieSeq = 0;
const call = (rest, method, body, search = '') => onRequest({
  request: new Request(`https://console.example.pages.dev/api/coord/${rest}${search}`, {
    method, headers: { cookie: `dash=bh4153-${++cookieSeq}`, 'content-type': 'application/json' }, body
  }),
  env: { HARNESS_SECRET: 'test-harness-secret' },
  params: { path: rest.split('/') }
});

test('P1: PUT flags forwards scope and value with the stamped actor', async () => {
  const f = stubUpstream();
  try {
    const res = await call('flags', 'PUT', JSON.stringify({ name: 'lanedown-x', scope: 'boxa', value: '3', active: 1, reason: 'r', actor: 'mallory', x: 1 }));
    assert.equal(res.status, 200);
    assert.equal(f.seen[0].url, `${JOBS}/api/flags`);
    assert.deepEqual(JSON.parse(f.seen[0].body), { name: 'lanedown-x', scope: 'boxa', value: '3', active: 1, reason: 'r', actor: 'console' });
  } finally { f.restore(); }
});

test('P2: DELETE flags forwards only name/scope/reason plus actor=console, with no body', async () => {
  const f = stubUpstream();
  try {
    const res = await call('flags', 'DELETE', undefined, '?name=paused-project-3&scope=fleet&reason=done&actor=mallory&smuggled=1');
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    const u = new URL(f.seen[0].url);
    assert.equal(`${u.origin}${u.pathname}`, `${JOBS}/api/flags`);
    assert.deepEqual([...u.searchParams.keys()].sort(), ['actor', 'name', 'reason', 'scope']);
    assert.deepEqual(u.searchParams.getAll('actor'), ['console']);
    assert.equal(u.searchParams.get('reason'), 'done');
    assert.equal(f.seen[0].method, 'DELETE');
    assert.equal(f.seen[0].body, undefined);
  } finally { f.restore(); }
});

test('P3: DELETE flags with a blank or missing reason is 400 and forwards nothing; DELETE flags/x is still 405', async () => {
  const f = stubUpstream();
  try {
    for (const q of ['?name=paused-project-3&scope=fleet', '?name=paused-project-3&scope=fleet&reason=%20%20']) {
      const res = await call('flags', 'DELETE', undefined, q);
      assert.equal(res.status, 400, q);
      assert.match((await res.json()).error, /reason is required/);
    }
    const res = await call('flags/x', 'DELETE', undefined, '?reason=r');
    assert.equal(res.status, 405);
    assert.equal((await res.json()).error, 'method DELETE not allowed on /api/coord/flags/x');
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('CB1: the COST BREAKER card reads the paused-* rows by prefix, so lanedown-* rows cannot push a trip off the capped list', async () => {
  const calls = stubFetch();
  installDom();
  const { CostBreakerSection } = await import('../src/screens/CostBreaker.js');
  const root = globalThis.document.createElement('div');
  mount(h(CostBreakerSection, {}), root);
  mounted = { unmount: () => mount(null, root) };
  await flush();
  const reads = calls.filter((x) => x.method === 'GET' && x.url.startsWith('/api/coord/flags'));
  assert.ok(reads.length > 0, 'the card reads the flags');
  for (const r of reads) {
    const u = new URL(r.url, 'https://x');
    assert.equal(u.pathname, '/api/coord/flags');
    assert.equal(u.searchParams.get('prefix'), 'paused-', r.url);
  }
});
