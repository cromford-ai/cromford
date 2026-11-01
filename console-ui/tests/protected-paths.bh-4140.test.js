import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';
import { render } from 'preact-render-to-string';
import { onRequest } from '../functions/api/coord/[[path]].js';
import { api } from '../src/api.js';
import {
  DEFAULT_REPO, ProtectedPathsView, ProtectedPathsPanel, LeadAuthorityHint,
  addProtectedPath, removeProtectedPath, modeOf, flipLeadAuthority
} from '../src/ui/ProtectedPaths.js';
import { Modal } from '../src/ui/Modal.js';
import { SettingsView } from '../src/screens/Settings.js';
import { flush } from './helpers/settle.js';

// BH-4147 (BH-4140.2): the PROTECTED PATHS panel on /settings, the api client
// methods behind it, and the coord proxy row that lets its PUT through. The
// proxy cases go through the real onRequest; the panel cases mount the real
// component in a fake DOM with a faked fetch.
// TEST-CHANGE BH-5035: lead_authority_mode is lane only; the hint has no SET human button, a stored human row shows SET lane (H1, H2).

const ROWS = [
  { repo: 'example-org/cromford', glob: 'bin/**', added_by: 'seed', added_at: '2026-10-01T00:00:00Z', removed_at: null },
  { repo: 'example-org/cromford', glob: 'worker/**', added_by: 'seed', added_at: '2026-10-02T00:00:00Z', removed_at: null },
  { repo: 'example-org/cromford', glob: 'cron/**', added_by: 'operator@example.com', added_at: '2026-10-03T00:00:00Z', removed_at: null }
];

// ---- the fake DOM (tests/build-queue-panel.bh-2510.test.js) ----------------
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
  addEventListener(t, fn) { this.listeners[t.toLowerCase()] = fn; (this.types = this.types || {})[t.toLowerCase()] = t; }
  removeEventListener(t) { delete this.listeners[t.toLowerCase()]; }
  focus() {}
  querySelector() { return null; }
  querySelectorAll() { return []; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const byText = (root, tag, text) => all(root).filter((n) => n.localName === tag && n.textContent.trim() === text);
const modalBtn = (root, text) => {
  const box = all(root).find((n) => n.attrs && n.attrs.class === 'modal__actions');
  return box ? byText(box, 'button', text)[0] : undefined;
};
const inputNamed = (root, label) => all(root).find((n) => n.localName === 'input' && n.attrs['aria-label'] === label);
const fire = (node, type, extra = {}) => node.listeners[type].call(node, { type: node.types[type], ...extra });

let mounted = null;
const realFetch = globalThis.fetch;
afterEach(async () => {
  if (mounted) { const { render: mount } = await import('preact'); mount(null, mounted); mounted = null; }
  globalThis.fetch = realFetch;
  delete globalThis.confirm;
});

function fakeDom() {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };
  globalThis.window.location = globalThis.window.location || { pathname: '/settings', search: '' };
  return doc;
}
function fakeFetch(respond) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    calls.push({ url: u, method: init.method || 'GET', body: init.body });
    const [status, body] = respond(u, init);
    return { ok: status < 300, status, text: async () => JSON.stringify(body) };
  };
  return calls;
}
async function mount(vnode) {
  const doc = fakeDom();
  const { render: m } = await import('preact');
  const root = doc.createElement('div');
  m(vnode, root);
  mounted = root;
  await flush();
  return { root, doc };
}

// ---- api client -------------------------------------------------------------
test('R1: api.protectedPaths reads through the coord proxy with the repo encoded', async () => {
  const calls = fakeFetch(() => [200, { rows: [] }]);
  await api.protectedPaths('example-org/cromford');
  assert.deepEqual(calls.map((c) => `${c.method} ${c.url}`), ['GET /api/coord/lead-protected-paths?repo=example-org%2Fcromford']);
});

// ---- the view ---------------------------------------------------------------
const view = (state, extra = {}) => render(h(ProtectedPathsView, { repo: DEFAULT_REPO, state, busy: false, onRemove() {}, ...extra }));

test('R2: rows render in one table with REPO, GLOB, ADDED BY, ADDED AT and every glob', () => {
  const out = view({ data: { rows: ROWS }, loading: false, error: null });
  assert.equal((out.match(/<table/g) || []).length, 1);
  for (const hd of ['REPO', 'GLOB', 'ADDED BY', 'ADDED AT', 'REMOVE']) assert.ok(out.includes(`${hd}`), `header ${hd}`);
  for (const r of ROWS) assert.ok(out.includes(r.glob), r.glob);
  assert.equal((out.match(/>REMOVE<\/button>/g) || []).length, 3, 'one REMOVE button per row');
  assert.ok(out.includes('operator@example.com'));
});

test('R3: clicking the GLOB header flips the row order and its aria-sort', async () => {
  const { root } = await mount(h(ProtectedPathsView, { repo: DEFAULT_REPO, state: { data: { rows: ROWS }, loading: false, error: null }, busy: false, onRemove() {} }));
  const globsInOrder = () => all(root).filter((n) => n.localName === 'span' && n.attrs.class === 'mono')
    .map((n) => n.textContent.trim());
  const th = () => all(root).find((n) => n.localName === 'th' && n.textContent.includes('GLOB'));
  assert.deepEqual(globsInOrder(), ['bin/**', 'cron/**', 'worker/**'], 'default sort is glob ascending');
  assert.equal(th().attrs['aria-sort'], 'ascending');
  fire(all(th()).find((n) => n.localName === 'button'), 'click');
  await flush();
  assert.deepEqual(globsInOrder(), ['worker/**', 'cron/**', 'bin/**']);
  assert.equal(th().attrs['aria-sort'], 'descending');
  // ADDED AT sorts too: oldest first on the first click
  fire(all(all(root).find((n) => n.localName === 'th' && n.textContent.includes('ADDED AT'))).find((n) => n.localName === 'button'), 'click');
  await flush();
  assert.deepEqual(globsInOrder(), ['bin/**', 'worker/**', 'cron/**']);
});

test('R4: the REPO cell links to the project page (no dead rows)', () => {
  const out = view({ data: { rows: ROWS.slice(0, 1) }, loading: false, error: null });
  assert.ok(out.includes('href="/p/cromford"'), out);
});

test('R5: the table scrolls inside its own overflow-x:auto container', () => {
  const out = view({ data: { rows: ROWS }, loading: false, error: null });
  const wrap = out.indexOf('overflow-x:auto');
  assert.ok(wrap > -1 && wrap < out.indexOf('<table'), 'the wrapper sits outside the table');
});

test('R6: a load failure is an error state, never the empty state; zero rows is the empty state', () => {
  const err = view({ data: null, loading: false, error: new Error('harness-jobs unreachable'), reload() {} });
  assert.match(err, /harness-jobs unreachable/);
  assert.match(err, /protected paths/i);
  assert.ok(err.includes('RETRY'));
  assert.ok(!err.includes('NO PROTECTED PATHS'), 'an error is never shown as an empty list');
  const empty = view({ data: { rows: [] }, loading: false, error: null });
  assert.ok(empty.includes('NO PROTECTED PATHS'));
  assert.ok(empty.includes(DEFAULT_REPO), 'the empty state names the repo');
  assert.ok(!empty.includes('could not load'));
  const loading = view({ data: null, loading: true, error: null });
  assert.ok(loading.includes('skel') && !loading.includes('NO PROTECTED PATHS'));
  // a body with no rows array is not "zero rows"
  const odd = view({ data: {}, loading: false, error: null, reload() {} });
  assert.ok(!odd.includes('NO PROTECTED PATHS'), 'a malformed answer is not an empty list');
});

// ---- add / remove flows -------------------------------------------------------
test('A1: add sends exactly {repo, glob, op:add}; created:false reads "already protected"; blank makes no call', async () => {
  const sent = [];
  const write = async (b) => { sent.push(b); return { created: true, row: {} }; };
  const r = await addProtectedPath({ write, repo: 'example-org/cromford', glob: 'tmp/**' });
  assert.deepEqual(sent, [{ repo: 'example-org/cromford', glob: 'tmp/**', op: 'add' }]);
  assert.equal(r.ok, true);
  assert.match(r.text, /added tmp\/\*\*/);
  const again = await addProtectedPath({ write: async () => ({ created: false, row: {} }), repo: 'a/b', glob: 'x' });
  assert.equal(again.ok, true);
  assert.match(again.text, /already protected/);
  assert.doesNotMatch(again.text, /added/);
  const odd = await addProtectedPath({ write: async () => ({}), repo: 'a/b', glob: 'x' });
  assert.equal(odd.ok, false, 'an answer without created is not a success');
  const bad = await addProtectedPath({ write: async () => { throw Object.assign(new Error('glob must be a string of 1-200 chars with no whitespace'), { status: 400 }); }, repo: 'a/b', glob: 'a b' });
  assert.equal(bad.ok, false);
  assert.match(bad.text, /no whitespace/);
  let called = 0;
  const w = async () => { called++; return { created: true }; };
  assert.equal((await addProtectedPath({ write: w, repo: 'a/b', glob: '  ' })).ok, false);
  assert.equal((await addProtectedPath({ write: w, repo: '', glob: 'x' })).ok, false);
  assert.equal(called, 0, 'a blank repo or glob makes no call');
  // through the real api client: a PUT with that JSON body
  const calls = fakeFetch(() => [201, { created: true, row: {} }]);
  await addProtectedPath({ write: api.setProtectedPath, repo: 'example-org/cromford', glob: 'tmp/**' });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, 'PUT');
  assert.equal(calls[0].url, '/api/coord/lead-protected-paths');
  assert.deepEqual(JSON.parse(calls[0].body), { repo: 'example-org/cromford', glob: 'tmp/**', op: 'add' });
});

test('M1: remove asks the in-app confirm, never the native one, then sends {repo, glob, op:remove}', async () => {
  globalThis.confirm = () => { throw new Error('native confirm called'); };
  const asked = [];
  const sent = [];
  const r = await removeProtectedPath({
    confirm: async (o) => { asked.push(o); return true; },
    write: async (b) => { sent.push(b); return { removed: true, row: {} }; },
    row: ROWS[0]
  });
  assert.equal(asked.length, 1);
  assert.equal(asked[0].title, 'REMOVE PROTECTED PATH');
  assert.equal(asked[0].confirmLabel, 'REMOVE');
  assert.equal(asked[0].tone, 'danger');
  assert.deepEqual(sent, [{ repo: 'example-org/cromford', glob: 'bin/**', op: 'remove' }]);
  assert.equal(r.ok, true);
  assert.match(r.text, /removed bin\/\*\*/);
  const gone = await removeProtectedPath({ confirm: async () => true, write: async () => { throw Object.assign(new Error('not live'), { status: 404 }); }, row: ROWS[0] });
  assert.equal(gone.ok, true);
  assert.match(gone.text, /already removed/);
  const fail = await removeProtectedPath({ confirm: async () => true, write: async () => { throw Object.assign(new Error('d1 down'), { status: 503 }); }, row: ROWS[0] });
  assert.equal(fail.ok, false);
  assert.match(fail.text, /d1 down/);
  const odd = await removeProtectedPath({ confirm: async () => true, write: async () => ({}), row: ROWS[0] });
  assert.equal(odd.ok, false, 'a 200 without removed:true is not a success');
});

test('M2: a cancelled confirm sends nothing', async () => {
  let called = 0;
  const r = await removeProtectedPath({ confirm: async () => false, write: async () => { called++; }, row: ROWS[0] });
  assert.deepEqual(r, { sent: false });
  assert.equal(called, 0);
});

test('M3: the Modal resolves cancel on Escape', async () => {
  let cancelled = 0;
  let confirmed = 0;
  const { doc } = await mount(h(Modal, { title: 'REMOVE PROTECTED PATH', body: 'x', onConfirm: () => confirmed++, onCancel: () => cancelled++ }));
  doc.listeners.keydown({ key: 'Escape', preventDefault() {} });
  assert.equal(cancelled, 1);
  assert.equal(confirmed, 0);
});

// ---- the mounted panel (production component, faked fetch) -------------------
function panelFetch({ rows = ROWS, putStatus = 201, putBody = { created: true, row: {} }, mode = null } = {}) {
  let live = rows.slice();
  return fakeFetch((u, init) => {
    if (u.startsWith('/api/coord/settings/')) return [200, { key: 'lead_authority_mode', setting: mode, source: mode ? 'settings' : 'none' }];
    if (u === '/api/coord/settings' && init.method === 'PUT') {
      const b = JSON.parse(init.body);
      mode = { key: b.key, value: b.value };
      return [200, { setting: mode }];
    }
    if (u.startsWith('/api/coord/lead-protected-paths') && init.method === 'PUT') {
      const b = JSON.parse(init.body);
      if (b.op === 'remove' && putStatus < 300) live = live.filter((r) => r.glob !== b.glob);
      if (b.op === 'add' && putStatus < 300 && putBody.created) live = live.concat({ repo: b.repo.toLowerCase(), glob: b.glob, added_by: 'console', added_at: '2026-10-04T00:00:00Z' });
      // the worker's shapes: add {created,row}, remove {removed:true,row}
      return [putStatus, b.op === 'remove' && putStatus < 300 ? { removed: true, row: {} } : putBody];
    }
    if (u.startsWith('/api/coord/lead-protected-paths?')) return [200, { rows: live }];
    return [404, { error: 'unknown' }];
  });
}

test('PANEL: loads the default repo, ADD puts op:add and reloads; REMOVE confirms then puts op:remove', async () => {
  globalThis.confirm = () => { throw new Error('native confirm called'); };
  const calls = panelFetch();
  const { root } = await mount(h(ProtectedPathsPanel));
  assert.ok(calls.some((c) => c.url === `/api/coord/lead-protected-paths?repo=${encodeURIComponent(DEFAULT_REPO)}`));
  assert.ok(root.textContent.includes('worker/**'));
  fire(inputNamed(root, 'glob'), 'input', { target: { value: 'tmp/**' } });
  await flush();
  fire(byText(root, 'button', 'ADD')[0], 'click');
  await flush();
  const puts = () => calls.filter((c) => c.method === 'PUT' && c.url === '/api/coord/lead-protected-paths');
  assert.equal(puts().length, 1);
  assert.deepEqual(JSON.parse(puts()[0].body), { repo: DEFAULT_REPO, glob: 'tmp/**', op: 'add' });
  assert.match(root.textContent, /added tmp\/\*\*/);
  assert.ok(root.textContent.includes('tmp/**'), 'the reload shows the new row');
  // REMOVE on tmp/**: modal first, nothing sent until confirm
  const row = all(root).find((n) => n.localName === 'tr' && n.textContent.includes('tmp/**'));
  fire(byText(row, 'button', 'REMOVE')[0], 'click');
  await flush();
  assert.match(root.textContent, /REMOVE PROTECTED PATH/);
  assert.equal(puts().length, 1, 'nothing sent before the modal answers');
  fire(modalBtn(root, 'REMOVE'), 'click');
  await flush();
  assert.equal(puts().length, 2);
  assert.deepEqual(JSON.parse(puts()[1].body), { repo: DEFAULT_REPO, glob: 'tmp/**', op: 'remove' });
  assert.match(root.textContent, /removed tmp\/\*\*/);
  assert.ok(!all(root).some((n) => n.localName === 'tr' && n.textContent.includes('tmp/**')), 'the row is gone after reload');
});

test('PANEL: Escape in the remove modal sends no PUT', async () => {
  const calls = panelFetch();
  const { root, doc } = await mount(h(ProtectedPathsPanel));
  fire(byText(all(root).find((n) => n.localName === 'tr' && n.textContent.includes('bin/**')), 'button', 'REMOVE')[0], 'click');
  await flush();
  assert.match(root.textContent, /REMOVE PROTECTED PATH/);
  doc.listeners.keydown({ key: 'Escape', preventDefault() {} });
  await flush();
  assert.equal(calls.filter((c) => c.method === 'PUT').length, 0);
  assert.doesNotMatch(root.textContent, /REMOVE PROTECTED PATH/);
});

test('PANEL: a refused add shows the worker error and is not "added"', async () => {
  panelFetch({ putStatus: 400, putBody: { error: 'glob must be a string of 1-200 chars with no whitespace' } });
  const { root } = await mount(h(ProtectedPathsPanel));
  fire(inputNamed(root, 'glob'), 'input', { target: { value: 'a b' } });
  await flush();
  fire(byText(root, 'button', 'ADD')[0], 'click');
  await flush();
  assert.match(root.textContent, /no whitespace/);
  assert.doesNotMatch(root.textContent, /added a b/);
  const add = byText(root, 'button', 'ADD')[0];
  assert.ok(!add.disabled && add.attrs.disabled === undefined, 'the busy latch is reset');
});

// ---- the lead_authority_mode hint -------------------------------------------------
test('H1: the hint names the value; no row and lane read lane with no button; a stored human row is refused, with SET lane only', () => {
  const hint = (state) => render(h(LeadAuthorityHint, { state, busy: false, onSet() {} }));
  const human = hint({ data: { setting: { value: 'human' } }, loading: false, error: null });
  assert.match(human, /lead_authority_mode/);
  assert.match(human, /removed by BH-5035/);
  assert.match(human, /lane = the lead review signs protected paths\./);
  assert.doesNotMatch(human, /human = a person must/);
  assert.ok(human.includes('SET lane'));
  assert.ok(!human.includes('SET human'));
  const none = hint({ data: { setting: null }, loading: false, error: null });
  assert.match(none, /no row, so lane/);
  assert.ok(!none.includes('SET '), 'no row is lane: no button');
  const lane = hint({ data: { setting: { value: 'lane' } }, loading: false, error: null });
  assert.ok(!lane.includes('SET '), 'lane: no button');
  const err = hint({ data: null, loading: false, error: new Error('boom') });
  assert.match(err, /could not read lead_authority_mode/);
  assert.ok(!err.includes('SET '), 'no SET button when the value is unknown');
  assert.doesNotMatch(err, /so lane/);
  const m = modeOf({ data: { setting: { value: ' Human ' } }, error: null });
  assert.equal(m.kind, 'unknown');
  assert.equal(m.next, 'lane');
  assert.match(m.label, /BH-5035/);
  assert.equal(modeOf({ data: { setting: { value: 'off' } }, error: null }).kind, 'unknown');
  assert.equal(modeOf({ data: {}, error: null }).kind, 'error', 'a body with no setting key is not "no row"');
});

test('H2: SET lane confirms through the modal, then PUTs the settings row and re-reads', async () => {
  const sent = [];
  const r = await flipLeadAuthority({ confirm: async () => true, write: async (b) => { sent.push(b); return { setting: { value: 'lane' } }; }, to: 'lane' });
  assert.deepEqual(sent, [{ key: 'lead_authority_mode', value: 'lane', note: 'BH-4147 console' }]);
  assert.equal(r.ok, true);
  let called = 0;
  assert.deepEqual(await flipLeadAuthority({ confirm: async () => false, write: async () => { called++; }, to: 'lane' }), { sent: false });
  assert.equal(called, 0);
  assert.equal((await flipLeadAuthority({ confirm: async () => true, write: async () => ({ setting: { value: 'human' } }), to: 'lane' })).ok, false,
    'a row that came back with another value is not a success');
  // mounted: a stored human row -> SET lane -> modal -> PUT settings -> re-read shows lane, no button
  const calls = panelFetch({ mode: { key: 'lead_authority_mode', value: 'human' } });
  const { root } = await mount(h(ProtectedPathsPanel));
  assert.match(root.textContent, /removed by BH-5035/);
  assert.equal(byText(root, 'button', 'SET human').length, 0);
  fire(byText(root, 'button', 'SET lane')[0], 'click');
  await flush();
  assert.equal(calls.filter((c) => c.method === 'PUT').length, 0, 'nothing sent before the modal answers');
  fire(modalBtn(root, 'SET lane'), 'click');
  await flush();
  const put = calls.filter((c) => c.method === 'PUT');
  assert.equal(put.length, 1);
  assert.equal(put[0].url, '/api/coord/settings');
  assert.deepEqual(JSON.parse(put[0].body), { key: 'lead_authority_mode', value: 'lane', note: 'BH-4147 console' });
  assert.ok(byText(root, 'b', 'lane').length, 'the re-read shows lane');
  assert.equal(byText(root, 'button', 'SET lane').length, 0, 'lane offers no button');
});

// ---- the Settings screen ----------------------------------------------------------
test('S1: the hub tab of Settings carries PROTECTED PATHS and the hint; a project tab does not', () => {
  const base = { tabs: [{ id: 'hub', label: 'HUB' }], rows: [], boxRows: [], status: null, error: null, loading: false,
    busy: null, setBusy() {}, note: null, onDismissNote() {}, actions: {}, accountActions: null, dialog: null, onTab() {}, onReload() {}, controlKinds: [] };
  globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };
  const hub = render(h(SettingsView, { ...base, activeTab: 'hub' }));
  assert.ok(hub.includes('PROTECTED PATHS'));
  assert.ok(hub.includes('lead_authority_mode'));
  const proj = render(h(SettingsView, { ...base, activeTab: 'project-3' }));
  assert.ok(!proj.includes('PROTECTED PATHS'));
  assert.ok(!proj.includes('lead_authority_mode'));
});

// ---- the coord proxy row ----------------------------------------------------------
const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
function proxyFetch() {
  const seen = [];
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response('{"created":true}', { status: 201, headers: { 'content-type': 'application/json' } });
  };
  return seen;
}
let cookieSeq = 0;
const proxy = (method, body) => onRequest({
  request: new Request('https://console.example.pages.dev/api/coord/lead-protected-paths', {
    method, headers: { cookie: `dash=bh4147-${++cookieSeq}`, 'content-type': 'application/json' }, body
  }),
  env: { HARNESS_SECRET: 'test-secret' },
  params: { path: ['lead-protected-paths'] }
});

test('P1: PUT forwards exactly {repo, glob, op, added_by, actor} with the proxy actor, never the browser one', async () => {
  const seen = proxyFetch();
  const res = await proxy('PUT', JSON.stringify({ repo: 'example-org/cromford', glob: 'tmp/**', op: 'add', added_by: 'mallory', actor: 'mallory', smuggled: 1 }));
  assert.equal(res.status, 201);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].url, `${JOBS}/api/lead-protected-paths`);
  assert.equal(seen[0].method, 'PUT');
  assert.deepEqual(JSON.parse(seen[0].body), { repo: 'example-org/cromford', glob: 'tmp/**', op: 'add', added_by: 'console', actor: 'console' });
  const rm = await proxy('PUT', JSON.stringify({ repo: 'example-org/cromford', glob: 'tmp/**', op: 'remove' }));
  assert.equal(rm.status, 201);
  assert.deepEqual(JSON.parse(seen[1].body), { repo: 'example-org/cromford', glob: 'tmp/**', op: 'remove', added_by: 'console', actor: 'console' });
});

test('P2: a bad op, a non-string glob or repo, or a non-object body is a 400 that forwards nothing', async () => {
  const seen = proxyFetch();
  const bodies = [
    {}, { repo: 'a/b', glob: 'x', op: 'delete' }, { repo: 'a/b', glob: 'x', op: ['add'] }, { repo: 'a/b', glob: 'x' },
    { repo: 'a/b', glob: 7, op: 'add' }, { repo: ['a/b'], glob: 'x', op: 'add' }, { repo: null, glob: 'x', op: 'add' }
  ];
  for (const b of bodies) {
    const res = await proxy('PUT', JSON.stringify(b));
    assert.equal(res.status, 400, JSON.stringify(b));
  }
  assert.equal((await proxy('PUT', '[1]')).status, 400);
  assert.equal((await proxy('PUT', 'not json')).status, 400);
  assert.equal(seen.length, 0);
});

test('P3: POST, DELETE and PATCH lead-protected-paths stay 405', async () => {
  const seen = proxyFetch();
  for (const m of ['POST', 'DELETE', 'PATCH']) {
    const res = await proxy(m, JSON.stringify({ repo: 'a/b', glob: 'x', op: 'add' }));
    assert.equal(res.status, 405, m);
  }
  assert.equal(seen.length, 0);
});
