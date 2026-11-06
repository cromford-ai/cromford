// BH-4990 (BH-4947 wave 1, "The Line"): the shared shell pieces.
//
// The top bar's theme switch (one button per built-in, pressed state from the
// page, a click persists the pick and repaints :root), the identity pill and
// the menu button it carries (the section links moved to the side menu, BH-9118), and the headline, stat grid and section head every
// redrawn screen will use.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

const store = new Map();
globalThis.window = globalThis.window || {
  location: { pathname: '/jobs', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};
window.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => { store.set(k, String(v)); },
  removeItem: (k) => { store.delete(k); }
};

class FakeNode {
  constructor(nodeType, name, data) {
    this.nodeType = nodeType; this.localName = name; this.nodeName = name ? name.toUpperCase() : '#text';
    this.data = data; this.childNodes = []; this.parentNode = null; this.attrs = {}; this.style = {}; this.listeners = {};
  }
  get firstChild() { return this.childNodes[0] || null; }
  get nextSibling() { if (!this.parentNode) return null; const s = this.parentNode.childNodes; return s[s.indexOf(this) + 1] || null; }
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
function installDom(themeId) {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  const root = new FakeNode(1, 'html');
  root.props = new Map();
  root.style = { setProperty: (k, v) => root.props.set(k, v) };
  if (themeId) root.setAttribute('data-theme', themeId);
  doc.documentElement = root;
  doc.querySelector = () => null;
  globalThis.document = doc;
  return doc;
}
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };

const { TopBar, NAV } = await import('../src/app.js');
const { PageHeadline, StatGrid, SectionHead } = await import('../src/ui/line.js');
const { BUILTIN_THEMES, THEME_ORDER } = await import('../src/theme/themes.js');
const { render } = await import('preact-render-to-string');

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BASE = { path: '/jobs', snap: { snapshot_age_min: 1 }, openAlerts: 2, loading: false, secondsLeft: 5, watchdogDown: false,
  identity: { data: { actor: 'operator@example.com', access: 'on', email: 'operator@example.com' }, error: null } };

function between(markup, openRe) {
  const s = String(markup);
  const m = openRe.exec(s);
  assert.ok(m, `no ${openRe}`);
  const tag = m[0].match(/^<([a-z0-9]+)/)[1];
  const re = new RegExp(`<${tag}\\b[^>]*>|</${tag}>`, 'g');
  re.lastIndex = m.index;
  let depth = 0;
  for (let t; (t = re.exec(s));) { depth += t[0].startsWith('</') ? -1 : 1; if (!depth) return s.slice(m.index, re.lastIndex); }
  return s.slice(m.index);
}

test('S1 the top bar has one theme button per built-in, in a labelled group, pressed on the page\'s theme', () => {
  installDom('paper');
  const out = render(h(TopBar, BASE));
  const group = between(out, /<div class="themeswitch" role="group" aria-label="Theme"/);
  const btns = [...group.matchAll(/<button[^>]*data-theme-switch="([^"]+)"[^>]*aria-pressed="(true|false)"[^>]*>([^<]*)<\/button>/g)]
    .map((m) => [m[1], m[2], m[3].trim()]);
  assert.deepEqual(btns, [['mill', 'false', 'Mill'], ['paper', 'true', 'Paper'], ['phosphor', 'false', 'Phosphor']]);
  assert.deepEqual(btns.map((b) => b[0]), THEME_ORDER);
  installDom('phosphor');
  assert.match(render(h(TopBar, BASE)), /data-theme-switch="phosphor"[^>]*aria-pressed="true"/);
});

test('S2 a click on Paper persists the pick, paints Paper, and presses its button', async () => {
  store.clear();
  const doc = installDom('mill');
  const el = doc.createElement('div');
  mount(h(TopBar, BASE), el);
  await flush();
  const btn = (id) => all(el).find((n) => n.localName === 'button' && n.getAttribute('data-theme-switch') === id);
  btn('paper').listeners.Click.call(btn('paper'), { type: 'Click' });
  await flush();
  assert.equal(store.get('ui.theme'), 'paper');
  assert.equal(doc.documentElement.getAttribute('data-theme'), 'paper');
  assert.equal(doc.documentElement.props.get('--surface-0'), BUILTIN_THEMES.paper.tokens['--surface-0']);
  assert.equal(btn('paper').getAttribute('aria-pressed'), 'true');
  assert.equal(btn('mill').getAttribute('aria-pressed'), 'false');
  mount(null, el);
});

test('S3 the bar keeps the identity pill, the snapshot age and the menu button; the NAV links are not in it', () => {
  installDom('mill');
  const out = render(h(TopBar, BASE));
  assert.match(out, /<span class="pill"[^>]*>operator@cto\.com<\/span>/);
  assert.match(out, /WATCHDOG OK/);
  // BH-9118: the section links live in the side menu (tests/sidemenu.bh-9118.test.js C1, C2).
  assert.doesNotMatch(out, /topbar__nav/);
  assert.match(out, /<button[^>]*class="topbar__menu"[^>]*aria-controls="sidemenu"/);
  for (const n of NAV.filter((x) => x.to !== '/')) assert.doesNotMatch(out, new RegExp(`<a href="${n.to.replace(/\//g, '\\/')}"`), n.label);
  assert.match(out, /<a href="\/"[^>]*class="topbar__brand"/);
  assert.match(out, /class="topbar__snap"/);
});

test('S4 headline, section head and stat grid render what they are given', () => {
  const hl = render(h(PageHeadline, { chip: 'Jobs · live', asOf: 'as of 21:40Z', line1: '3 jobs on the line.', line2: '1 parked. 2 lost.', lede: 'No claimed job has stopped beating.' }));
  assert.match(hl, /<h1 class="line-headline">3 jobs on the line\.<br\/?><span class="line-headline__dim">1 parked\. 2 lost\.<\/span><\/h1>/);
  assert.match(hl, /<p class="lede">No claimed job has stopped beating\.<\/p>/);
  assert.match(hl, /Jobs · live/);
  assert.doesNotMatch(render(h(PageHeadline, { line1: 'a', line2: 'b', lede: '' })), /class="lede"/);
  const sh = render(h(SectionHead, { num: 1, title: 'The line', note: 'one row per ticket' }));
  assert.match(sh, /<span class="sechead__num">01<\/span>\s*<h2>The line<\/h2>\s*<p>one row per ticket<\/p>/);
  const sg = render(h(StatGrid, { items: [
    { label: 'Claimed now', value: 3, tone: 'live' },
    { label: 'Parked', value: 1, tone: 'warn' },
    { label: 'Orphaned', value: 0 },
    { label: 'Spend', value: 'x', to: '/costs' }
  ] }));
  assert.equal((sg.match(/class="statgrid__cell[^"]*"/g) || []).length, 4);
  assert.equal((sg.match(/statgrid__cell--warn/g) || []).length, 1);
  assert.equal((sg.match(/statgrid__cell--live/g) || []).length, 1);
  assert.match(sg, /<a href="\/costs" class="statgrid__cell[^"]*"/);
});

test('S5 the new shell files hold no colour literal', () => {
  for (const f of ['src/ui/line.js', 'src/ui/TopBar.js', 'src/lib/line.js', 'src/screens/Ticket.js', 'src/screens/Jobs.js']) {
    const src = fs.readFileSync(path.join(root, f), 'utf8');
    assert.ok(src.length > 200, `${f} is there`);
    assert.doesNotMatch(src, /#[0-9a-fA-F]{3,8}\b|rgba?\(/, `${f} carries a colour; use a var(--token)`);
  }
});
