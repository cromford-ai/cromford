// BH-4846 (Mission Control wave 4): custom themes on /settings/appearance.
//
// The pure views (AppearanceView, ThemeEditorView) are rendered to strings;
// then the real screen is mounted through ROUTES into a small fake DOM over a
// stubbed fetch that keeps its own settings table, so NEW FROM, SAVE, SET AS
// FLEET DEFAULT, EXPORT, IMPORT and DELETE all run through the real handlers,
// the real api.js and the real confirm modal.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

const store = new Map();
globalThis.window = globalThis.window || {
  location: { pathname: '/settings/appearance', search: '' },
  dispatchEvent() { return true; }, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};
window.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => { store.set(k, String(v)); },
  removeItem: (k) => { store.delete(k); }
};

const { ROUTES } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const { AppearanceScreen, AppearanceView } = await import('../src/screens/Appearance.js');
const { ThemeEditorView } = await import('../src/screens/ThemeEditor.js');
const { BUILTIN_THEMES } = await import('../src/theme/themes.js');
const { docFromTheme, exportTheme, toTheme, COLOR_KEYS, FONT_CHOICES } = await import('../src/theme/custom.js');
const { parseColor } = await import('../src/theme/tokens.js');
const { render } = await import('preact-render-to-string');

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const noop = () => {};
const isHex = (v) => /^#[0-9a-f]{3}([0-9a-f]{3})?$/i.test(v);

const NIGHT_DOC = docFromTheme(BUILTIN_THEMES.mill, 'Night Shift');
NIGHT_DOC.tokens['--accent'] = '#e07a50';
const NIGHT = { id: 'custom.night', slug: 'night', doc: NIGHT_DOC, theme: toTheme(NIGHT_DOC, 'night'), actor: 'operator@example.com' };

// --------------------------------------------------------- the pure editor

const editor = (doc, over = {}) => render(h(ThemeEditorView, {
  doc, saving: false, saveError: null, onChange: noop, onSave: noop, onCancel: noop, onExport: noop, ...over
}));
const count = (s, re) => (s.match(re) || []).length;

test('E1 one colour picker per hex colour token, a text field for each rgba one', () => {
  const out = editor(docFromTheme(BUILTIN_THEMES.mill, 'Mine'));
  const hexKeys = COLOR_KEYS.filter((k) => isHex(BUILTIN_THEMES.mill.tokens[k]));
  const rgbaKeys = COLOR_KEYS.filter((k) => !isHex(BUILTIN_THEMES.mill.tokens[k]));
  assert.ok(hexKeys.length > 60 && rgbaKeys.length > 0);
  const colorInputs = [...out.matchAll(/<input type="color"[^>]*data-token="([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual(colorInputs, hexKeys);
  for (const k of rgbaKeys) assert.match(out, new RegExp(`<input type="text"[^>]*data-token="${k}"`));
  // A picker is handed #rrggbb: --shadow is #000 in Mill.
  assert.match(out, /<input type="color"[^>]*value="#000000"[^>]*data-token="--shadow"/);
});

test('E2 three font role selects offering only the self-hosted set, and three radius sliders 0-24', () => {
  const out = editor(docFromTheme(BUILTIN_THEMES.mill, 'Mine'));
  assert.equal(count(out, /<select[^>]*data-font-role=/g), 3);
  for (const role of ['--font-display', '--font-body', '--font-mono']) assert.match(out, new RegExp(`data-font-role="${role}"`));
  assert.equal(count(out, /<option /g), 3 * FONT_CHOICES.length);
  const ranges = [...out.matchAll(/<input type="range"([^>]*)>/g)].map((m) => m[1]);
  assert.equal(ranges.length, 3);
  for (const r of ranges) { assert.match(r, /min="0"/); assert.match(r, /max="24"/); }
  assert.match(out, /type="range"[^>]*value="10"[^>]*data-radius="--radius-md"/);
});

test('E3 the live preview has a panel, a table and pills, styled from the edited tokens', () => {
  const doc = docFromTheme(BUILTIN_THEMES.mill, 'Mine');
  doc.tokens['--accent'] = '#a1b2c3';
  const out = editor(doc);
  const preview = out.slice(out.indexOf('data-theme-preview'));
  assert.ok(preview.length > 100, 'there is a preview');
  assert.match(preview, /theme-card__panel/);
  assert.match(preview, /<table/);
  assert.match(preview, /theme-card__pill--ok/);
  assert.match(out, /data-theme-preview[^>]*style="[^"]*--accent:#a1b2c3/);
  assert.match(out, /data-theme-preview[^>]*style="[^"]*--radius-md:10px/);
});

test('E4 a contrast failure is listed by pair and SAVE is disabled; a clean doc can save', () => {
  const bad = docFromTheme(BUILTIN_THEMES.mill, 'Mine');
  bad.tokens['--text'] = bad.tokens['--surface-0'];
  const out = editor(bad);
  assert.match(out, /data-contrast-warn/);
  assert.match(out, /--text on --surface-0/);
  assert.match(out, /<button[^>]*data-theme-save[^>]*disabled/);
  const good = editor(docFromTheme(BUILTIN_THEMES.mill, 'Mine'));
  assert.doesNotMatch(good, /data-contrast-warn/);
  assert.doesNotMatch(good, /<button[^>]*data-theme-save[^>]*disabled/);
  // Any validation error blocks too (an empty name), and so does a save in flight.
  assert.match(editor({ ...docFromTheme(BUILTIN_THEMES.mill, 'x'), name: '' }), /<button[^>]*data-theme-save[^>]*disabled/);
  assert.match(editor(docFromTheme(BUILTIN_THEMES.mill, 'Mine'), { saving: true }), /<button[^>]*data-theme-save[^>]*disabled/);
  assert.match(editor(docFromTheme(BUILTIN_THEMES.mill, 'Mine'), { saveError: 'value must be non-empty' }), /Couldn.t save: value must be non-empty/);
});

// ------------------------------------------------------------ the pure page

const view = (over = {}) => render(h(AppearanceView, {
  activeId: 'mill', viewerId: null, fleet: { state: 'ok', id: null, hasRow: false, raw: null },
  saveFailed: false, onPick: noop, onClearPick: noop,
  customs: { state: 'ok', themes: [NIGHT], skipped: [] }, canSetFleet: false, ...over
}));

test('V1 a saved custom theme is a card in the picker, saying who saved it', () => {
  const out = view();
  assert.match(out, /<section class="theme-card[^"]*" data-theme-id="custom\.night" style="[^"]*--accent:#e07a50/);
  assert.match(out, />Night Shift</);
  assert.match(out, /saved by operator@example\.com/);
  assert.match(out, /data-theme-pick="custom\.night"/);
  assert.match(out, /data-theme-export="custom\.night"/);
  assert.match(out, /data-theme-delete="custom\.night"/);
});

test('V2 NEW THEME FROM lists every built-in, and IMPORT takes a .json file', () => {
  const out = view();
  const sel = out.match(/<select[^>]*data-new-from[^>]*>([\s\S]*?)<\/select>/);
  assert.ok(sel, 'a New-from select');
  const opts = [...sel[1].matchAll(/<option value="([^"]*)"/g)].map((m) => m[1]).filter(Boolean);
  assert.deepEqual(opts, ['mill', 'paper', 'phosphor']);
  assert.match(out, /<input type="file"[^>]*accept="[^"]*\.json[^"]*"[^>]*data-theme-import/);
});

test('V3 SET AS FLEET DEFAULT is on every card only for a verified Access identity', () => {
  const on = view({ canSetFleet: true });
  assert.deepEqual([...on.matchAll(/data-fleet-pick="([^"]+)"/g)].map((m) => m[1]), ['mill', 'paper', 'phosphor', 'custom.night']);
  assert.equal(count(view({ canSetFleet: false }), /data-fleet-pick=/g), 0);
});

test('V4 the custom list says loading, failed and empty apart', () => {
  assert.match(view({ customs: { state: 'ok', themes: [], skipped: [] } }), /No custom themes yet/);
  const failed = view({ customs: { state: 'error', themes: [], skipped: [], error: new Error('http_500') } });
  assert.match(failed, /Couldn.t read custom themes \(http_500\)/);
  assert.doesNotMatch(failed, /No custom themes yet/);
  assert.match(view({ customs: { state: 'loading', themes: [], skipped: [] } }), /Reading custom themes/);
  const skipped = view({ customs: { state: 'ok', themes: [], skipped: [{ key: 'ui.theme.custom.bad', errors: ['--x is not a colour token'] }] } });
  assert.match(skipped, /ui\.theme\.custom\.bad/);
});

test('V5 the fleet line names a custom default, and says so when that theme is gone', () => {
  assert.match(view({ fleet: { state: 'ok', id: 'custom.night', hasRow: true, raw: 'custom.night' }, activeId: 'custom.night' }),
    /Fleet default: <a [^>]*>Night Shift<\/a> \(settings row\)/);
  assert.match(view({ fleet: { state: 'ok', id: 'custom.gone', hasRow: true, raw: 'custom.gone' } }),
    /Fleet default: <a [^>]*>Mill<\/a> \(the settings row names custom\.gone, and no saved theme has that id\)/);
});

test('V6 the editor opens in the page, and the new screens hold no colour of their own', () => {
  const out = view({ editor: { doc: docFromTheme(BUILTIN_THEMES.phosphor, 'Green'), saving: false, error: null } });
  assert.match(out, /data-theme-editor/);
  for (const f of ['Appearance.js', 'ThemeEditor.js']) {
    const src = fs.readFileSync(path.join(root, 'src', 'screens', f), 'utf8');
    assert.ok(src.length > 200);
    assert.doesNotMatch(src, /#[0-9a-fA-F]{3,8}\b|rgba?\(/, f);
    assert.doesNotMatch(src, /window\.(confirm|alert|prompt)|\bconfirm\(['"`]/, f);
  }
});

// ---------------------------------------------------------- the mounted page

class FakeNode {
  constructor(nodeType, name, data) {
    this.nodeType = nodeType;
    this.localName = name;
    this.nodeName = name ? name.toUpperCase() : '#text';
    this.data = data;
    this.childNodes = [];
    this.parentNode = null;
    this.attrs = {};
    this.style = { setProperty() {} };
    this.listeners = {};
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
  querySelector() { return null; }
  querySelectorAll() { return []; }
  focus() {}
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}

const downloads = [];
function installDom() {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => {
    const n = new FakeNode(1, t);
    if (t === 'a') n.click = function () { downloads.push({ download: this.download, href: this.href }); };
    return n;
  };
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  doc.hidden = false;
  doc.body = new FakeNode(1, 'body');
  const htmlEl = new FakeNode(1, 'html');
  htmlEl.props = new Map();
  htmlEl.style = { setProperty: (k, v) => htmlEl.props.set(k, v) };
  doc.documentElement = htmlEl;
  doc.metas = { 'color-scheme': new FakeNode(1, 'meta'), 'theme-color': new FakeNode(1, 'meta') };
  doc.querySelector = (sel) => doc.metas[(sel.match(/name="([^"]+)"/) || [])[1]] || null;
  globalThis.document = doc;
  return doc;
}
const mounted = new Set();
test.afterEach(() => { for (const r of mounted) mount(null, r); mounted.clear(); });
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };

// A worker in miniature: a settings table, the proxy's stamped actor, and
// the custom-theme DELETE.
function stubWorker(rows) {
  const table = new Map(rows.map((r) => [r.key, { ...r }]));
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    const method = init.method || 'GET';
    calls.push({ method, url: u, body: init.body ? JSON.parse(init.body) : undefined });
    let body;
    if (u === '/api/coord/whoami') body = { actor: 'operator@example.com', access: 'on', email: 'operator@example.com' };
    else if (method === 'GET' && u === '/api/coord/settings') body = { settings: [...table.values()] };
    else if (method === 'GET' && u.startsWith('/api/coord/settings/')) {
      const key = decodeURIComponent(u.slice('/api/coord/settings/'.length));
      body = { key, setting: table.get(key) || null, source: 'd1' };
    } else if (method === 'PUT' && u === '/api/coord/settings') {
      const b = JSON.parse(init.body);
      table.set(b.key, { key: b.key, value: b.value, actor: 'operator@example.com', updated_at: 't' });
      body = { setting: table.get(b.key) };
    } else if (method === 'DELETE') {
      const key = decodeURIComponent(u.slice('/api/coord/settings/'.length).split('?')[0]);
      body = { key, deleted: table.delete(key) };
    } else body = { error: 'unexpected' };
    return { ok: !body.error, status: body.error ? 500 : 200, text: async () => JSON.stringify(body) };
  };
  return { table, calls };
}

async function mountAppearance() {
  const doc = installDom();
  const hit = ROUTES.map(([pat, C]) => [matchRoute(pat, '/settings/appearance'), C]).find(([params]) => params);
  assert.equal(hit[1], AppearanceScreen);
  const el = doc.createElement('div');
  mounted.add(el);
  mount(h(hit[1], hit[0]), el);
  await flush();
  const find = (pred) => all(el).find(pred);
  const by = (attr, val) => find((n) => n.getAttribute && n.getAttribute(attr) === val);
  const fire = async (n, type, target = n) => { n.listeners[type].call(n, { type, target, currentTarget: n, preventDefault() {} }); await flush(); };
  return { doc, el, find, by, fire, text: () => el.textContent };
}

test('M1 create, save, reload, set as fleet default, export, import, delete: the QA flow through the real screen', async () => {
  store.clear();
  downloads.length = 0;
  const w = stubWorker([
    { key: 'ui.theme.default', value: 'custom.night', actor: 'operator@example.com', updated_at: 't' },
    { key: 'ui.theme.custom.night', value: exportTheme(NIGHT_DOC), actor: 'operator@example.com', updated_at: 't' }
  ]);
  let s = await mountAppearance();

  // The saved theme is in the picker, and as the fleet default it is what the page wears.
  assert.ok(s.by('data-theme-id', 'custom.night'), 'the custom card');
  assert.match(s.text(), /saved by operator@example\.com/);
  assert.match(s.text(), /Fleet default: Night Shift \(settings row\)/);
  assert.equal(s.doc.documentElement.getAttribute('data-theme'), 'custom.night');
  assert.equal(s.doc.documentElement.props.get('--accent'), '#e07a50');
  assert.ok(JSON.parse(store.get('ui.theme.cache')).id === 'custom.night');

  // NEW THEME FROM Mill opens the editor.
  const from = s.find((n) => n.localName === 'select' && n.getAttribute('data-new-from') !== null);
  from.value = 'mill';
  await s.fire(from, 'Change');
  assert.ok(s.find((n) => n.getAttribute && n.getAttribute('data-theme-editor') !== null), 'the editor is open');
  const save = () => s.find((n) => n.localName === 'button' && n.getAttribute('data-theme-save') !== null);
  const setToken = async (k, v) => { const n = s.by('data-token', k); n.value = v; await s.fire(n, 'Input'); };

  // --text-dim on the surface: the warning shows and SAVE is disabled.
  await setToken('--text-dim', BUILTIN_THEMES.mill.tokens['--surface-1']);
  assert.ok(s.find((n) => n.getAttribute && n.getAttribute('data-contrast-warn') !== null), 'the contrast warning');
  assert.equal(save().getAttribute('disabled') !== null, true, 'SAVE disabled');
  // Fixed, renamed, a new accent and radius: SAVE writes the row.
  await setToken('--text-dim', BUILTIN_THEMES.mill.tokens['--text-dim']);
  await setToken('--accent', '#f08a60');
  const radius = s.by('data-radius', '--radius-md');
  radius.value = '4';
  await s.fire(radius, 'Input');
  const name = s.find((n) => n.getAttribute && n.getAttribute('data-theme-name') !== null);
  name.value = 'Day Shift';
  await s.fire(name, 'Input');
  assert.equal(save().getAttribute('disabled'), null, 'SAVE enabled');
  await s.fire(save(), 'Click');
  const put = w.calls.find((c) => c.method === 'PUT');
  assert.equal(put.url, '/api/coord/settings');
  assert.equal(put.body.key, 'ui.theme.custom.day-shift');
  assert.equal(put.body.actor, undefined, 'the browser never names the actor');
  const saved = JSON.parse(put.body.value);
  assert.equal(saved.name, 'Day Shift');
  assert.equal(saved.tokens['--accent'], '#f08a60');
  assert.equal(saved.shape['--radius-md'], '4px');
  assert.ok(s.by('data-theme-id', 'custom.day-shift'), 'the new card');
  assert.ok(!s.find((n) => n.getAttribute && n.getAttribute('data-theme-editor') !== null), 'the editor closed');

  // Reload: a fresh mount reads it back from the settings table.
  mount(null, [...mounted][0]);
  mounted.clear();
  s = await mountAppearance();
  assert.ok(s.by('data-theme-id', 'custom.day-shift'), 'still there after a reload');

  // SET AS FLEET DEFAULT.
  await s.fire(s.by('data-fleet-pick', 'custom.day-shift'), 'Click');
  const fleetPut = w.calls.filter((c) => c.method === 'PUT').at(-1);
  assert.deepEqual(fleetPut.body, { key: 'ui.theme.default', value: 'custom.day-shift' });
  assert.match(s.text(), /Fleet default: Day Shift \(settings row\)/);
  assert.equal(s.doc.documentElement.getAttribute('data-theme'), 'custom.day-shift');
  assert.equal(s.doc.documentElement.props.get('--accent'), '#f08a60');

  // EXPORT downloads the canonical JSON.
  await s.fire(s.by('data-theme-export', 'custom.day-shift'), 'Click');
  assert.equal(downloads.length, 1);
  assert.equal(downloads[0].download, 'day-shift.theme.json');

  // IMPORT: a bad file shows the validator's errors; a good one opens the editor unchanged.
  const file = s.find((n) => n.localName === 'input' && n.getAttribute('data-theme-import') !== null);
  const bad = { ...saved, tokens: { ...saved.tokens, '--surface-0': 'red' } };
  await s.fire(file, 'Change', { files: [{ text: async () => JSON.stringify(bad) }], value: 'x' });
  assert.match(s.text(), /--surface-0/);
  assert.ok(s.find((n) => n.getAttribute && n.getAttribute('data-import-errors') !== null));
  await s.fire(file, 'Change', { files: [{ text: async () => exportTheme(saved) }], value: 'x' });
  const opened = s.find((n) => n.getAttribute && n.getAttribute('data-theme-name') !== null);
  assert.equal(opened.value ?? opened.getAttribute('value'), 'Day Shift');
  await s.fire(s.find((n) => n.localName === 'button' && /CANCEL/.test(n.textContent) && n.getAttribute('data-theme-cancel') !== null), 'Click');

  // DELETE goes through the in-app confirm: CANCEL deletes nothing.
  await s.fire(s.by('data-theme-delete', 'custom.day-shift'), 'Click');
  assert.equal(w.calls.filter((c) => c.method === 'DELETE').length, 0, 'nothing deleted before the confirm');
  const cancelBtn = s.find((n) => n.localName === 'button' && n.textContent === 'CANCEL' && n.getAttribute('data-theme-cancel') === null);
  assert.ok(cancelBtn, 'the confirm modal has a cancel');
  await s.fire(cancelBtn, 'Click');
  assert.equal(w.calls.filter((c) => c.method === 'DELETE').length, 0, 'cancel deletes nothing');
  assert.ok(s.by('data-theme-id', 'custom.day-shift'), 'still listed after a cancel');
  // Confirmed, it is deleted and the page falls back to Mill.
  await s.fire(s.by('data-theme-delete', 'custom.day-shift'), 'Click');
  const confirmBtn = s.find((n) => n.localName === 'button' && n.textContent === 'DELETE');
  assert.ok(confirmBtn, 'the confirm modal');
  await s.fire(confirmBtn, 'Click');
  const del = w.calls.filter((c) => c.method === 'DELETE');
  assert.equal(del.length, 1);
  assert.equal(del[0].url, '/api/coord/settings/ui.theme.custom.day-shift');
  assert.ok(!s.by('data-theme-id', 'custom.day-shift'));
  assert.match(s.text(), /the settings row names custom\.day-shift, and no saved theme has that id/);
  assert.equal(s.doc.documentElement.getAttribute('data-theme'), 'mill');
  assert.equal(store.has('ui.theme.cache'), false);
});

test('M2 a failed save keeps the editor open with the worker\'s error; whoami off hides the fleet control', async () => {
  store.clear();
  const w = stubWorker([]);
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    if (String(url) === '/api/coord/whoami') return { ok: true, status: 200, text: async () => JSON.stringify({ access: 'off', actor: 'console' }) };
    if (init.method === 'PUT') return { ok: false, status: 400, text: async () => JSON.stringify({ error: 'value must be non-empty and <= 256 chars' }) };
    return real(url, init);
  };
  const s = await mountAppearance();
  assert.ok(!s.find((n) => n.getAttribute && n.getAttribute('data-fleet-pick') !== null));
  assert.match(s.text(), /No custom themes yet/);
  const from = s.find((n) => n.localName === 'select' && n.getAttribute('data-new-from') !== null);
  from.value = 'phosphor';
  await s.fire(from, 'Change');
  await s.fire(s.find((n) => n.localName === 'button' && n.getAttribute('data-theme-save') !== null), 'Click');
  assert.ok(s.find((n) => n.getAttribute && n.getAttribute('data-theme-editor') !== null), 'still open');
  assert.match(s.text(), /Couldn.t save: value must be non-empty and <= 256 chars/);
  assert.ok(!s.by('data-theme-id', 'custom.phosphor'));
  assert.equal(w.table.size, 0);
});

test('M3 the colour helpers never hand a picker anything but #rrggbb', () => {
  for (const id of Object.keys(BUILTIN_THEMES)) {
    const out = editor(docFromTheme(BUILTIN_THEMES[id], 'x'));
    for (const m of out.matchAll(/<input type="color"[^>]*value="([^"]*)"/g)) {
      assert.match(m[1], /^#[0-9a-f]{6}$/, `${id}: ${m[1]}`);
      assert.ok(parseColor(m[1]));
    }
  }
});
