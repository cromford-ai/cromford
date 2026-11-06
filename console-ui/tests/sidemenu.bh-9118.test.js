// BH-9118: the Mission Control side menu. NAV (src/app.js) is the one table:
// every entry has a group, the side menu lists them by group, a collapse
// button turns it into an icon rail, and on a phone it is a drawer the top
// bar's hamburger opens. The bottom nav keeps five key tabs on one row.
//
// A* read the real NAV and ROUTES, B* drive the pure helpers
// (src/lib/sidemenu.js), C* render the real SideMenu, D* mount the real
// TopBar and App, E* read the stylesheets and render BottomNav.
// tests/drive/sidemenu-drive.mjs measures the same in a browser.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';
import { installDom, routedFetch, all, fire } from './helpers/fake-dom.bh-5750.js';

const store = new Map();
const storage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => { store.set(k, String(v)); },
  removeItem: (k) => { store.delete(k); }
};
const setUrl = (to) => {
  const u = new URL(to, 'http://console.test');
  Object.assign(window.location, { pathname: u.pathname, search: u.search, hash: u.hash });
};
globalThis.window = {
  location: { pathname: '/jobs', search: '', hash: '' },
  dispatchEvent() { return true; }, addEventListener() {}, removeEventListener() {},
  history: { pushState(_s, _t, to) { setUrl(to); }, replaceState(_s, _t, to) { setUrl(to); } },
  scrollTo() {},
  localStorage: storage,
  matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} })
};

const { NAV, NAV_GROUPS, ROUTES, TopBar, BottomNav, App } = await import('../src/app.js');
const { menuGroups, teamLinks, readMenuPrefs, writeMenuPrefs, COLLAPSED_KEY, GROUPS_KEY } = await import('../src/lib/sidemenu.js');
const { SideMenu } = await import('../src/ui/SideMenu.js');
const { navigate } = await import('../src/router.js');
const { render } = await import('preact-render-to-string');

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (rel) => fs.readFileSync(path.join(root, rel), 'utf8');

const ROSTER = { agents: [{ name: 'archie' }, { name: 'watchman' }, { name: 'mill-scout' }] };
const mounted = new Set();
test.afterEach(() => { for (const r of mounted) mount(null, r); mounted.clear(); store.clear(); });

const cls = (n) => ((n.attrs && n.attrs.class) || '').split(/\s+/).filter(Boolean);
const hasCls = (n, c) => cls(n).includes(c);
const byCls = (rootNode, c) => all(rootNode).filter((n) => n.nodeType === 1 && hasCls(n, c));
const links = (rootNode) => all(rootNode).filter((n) => n.localName === 'a');
const sample = (pattern) => pattern.replace(/:agent\b/g, 'archie').replace(/:[a-zA-Z]+/g, 'x1');
const lit = (p) => NAV.filter((n) => n.match(p)).map((n) => n.label);

function mountInto(vnode) {
  const doc = installDom();
  // installDom replaced the document but kept our window; keep our storage.
  window.localStorage = storage;
  const el = doc.createElement('div');
  mounted.add(el);
  mount(vnode, el);
  return { doc, el };
}
const menuProps = (over = {}) => ({ nav: NAV, groups: NAV_GROUPS, path: '/jobs', openAlerts: 2, open: false, onClose() {}, ...over });

// ------------------------------------------------------------------ A: NAV

test('A1 every ROUTES pattern lights exactly one NAV entry; /staff/:agent also lights its Team link', () => {
  const orphans = [];
  const doubles = [];
  for (const [pattern] of ROUTES) {
    const p = sample(pattern);
    const on = lit(p);
    if (on.length === 0) orphans.push(`${pattern} (${p})`);
    if (on.length > 1) doubles.push(`${pattern} (${p}): ${on.join(', ')}`);
  }
  assert.deepEqual(orphans, [], `routes no side-menu entry claims: ${orphans.join('; ')}`);
  assert.deepEqual(doubles, [], `routes more than one entry claims: ${doubles.join('; ')}`);
  assert.ok(ROUTES.some(([p]) => p === '/staff') && ROUTES.some(([p]) => p === '/staff/:agent'), 'the staff routes are in ROUTES');
  const team = teamLinks(ROSTER, sample('/staff/:agent'));
  assert.deepEqual(team.links.filter((l) => l.on).map((l) => l.to), ['/staff/archie']);
  const g = menuGroups(NAV, NAV_GROUPS, '/staff/archie', {}, team).find((x) => x.id === 'team');
  assert.deepEqual(g.items.filter((i) => i.on).map((i) => i.to), ['/staff/archie'], 'the agent link is lit and STAFF is not');
  const staff = menuGroups(NAV, NAV_GROUPS, '/staff', {}, teamLinks(ROSTER, '/staff')).find((x) => x.id === 'team');
  assert.deepEqual(staff.items.filter((i) => i.on).map((i) => i.to), ['/staff']);
  // near misses light nothing
  for (const p of ['/nowhere', '/historyx', '/staff-x', '/costsx']) assert.deepEqual(lit(p), [], p);
  // the cases that moved or joined a section
  assert.deepEqual(lit('/llm-sites'), ['COSTS']);
  assert.deepEqual(lit('/roadmap/x1'), ['IDEAS']);
  assert.deepEqual(lit('/connections'), ['SETTINGS']);
  assert.deepEqual(lit('/projects/x1/ready'), ['FLEET']);
});

test('A2 HISTORY and COMMAND LOG have their own entries; NOW is /now only', () => {
  assert.deepEqual(lit('/history'), ['HISTORY']);
  assert.deepEqual(lit('/history/commands'), ['COMMAND LOG']);
  assert.deepEqual(lit('/now'), ['NOW']);
  const hist = NAV.find((n) => n.label === 'HISTORY');
  const cmds = NAV.find((n) => n.label === 'COMMAND LOG');
  assert.equal(hist.to, '/history');
  assert.equal(cmds.to, '/history/commands');
  assert.equal(hist.group, 'logs');
  assert.equal(cmds.group, 'logs');
});

test('A3 every NAV entry has a known group and an icon; SETTINGS is last; no group is empty', () => {
  const ids = NAV_GROUPS.map((g) => g.id);
  assert.deepEqual(ids, ['overview', 'team', 'reports', 'logs', 'system']);
  for (const n of NAV) {
    assert.ok(ids.includes(n.group), `${n.label} has group ${n.group}`);
    assert.equal(typeof n.icon, 'function', `${n.label} has an icon`);
  }
  assert.equal(NAV[NAV.length - 1].label, 'SETTINGS');
  for (const id of ids) assert.ok(NAV.some((n) => n.group === id), `group ${id} has an entry`);
  const of = (id) => NAV.filter((n) => n.group === id).map((n) => n.label);
  assert.deepEqual(of('team'), ['STAFF']);
  assert.deepEqual(of('reports'), ['COSTS', 'OUTCOMES', 'DORA', 'CI', 'UTIL']);
  assert.deepEqual(of('logs'), ['HISTORY', 'COMMAND LOG', 'JOBS', 'LANES']);
  assert.deepEqual(of('system'), ['IDEAS', 'MODELS', 'HUB', 'SETTINGS']);
});

test('A4 there is no MORE tab', () => {
  assert.equal(NAV.find((n) => /^more$/i.test(n.label)), undefined);
});

// --------------------------------------------------------------- B: helpers

test('B1 writeMenuPrefs then readMenuPrefs round-trips collapsed and groups', () => {
  writeMenuPrefs(storage, { collapsed: true, groups: { reports: false, logs: true } });
  assert.equal(store.get(COLLAPSED_KEY), '1');
  assert.equal(COLLAPSED_KEY, 'ui.sidemenu.collapsed');
  assert.equal(GROUPS_KEY, 'ui.sidemenu.groups');
  assert.deepEqual(readMenuPrefs(storage), { collapsed: true, groups: { reports: false, logs: true } });
  writeMenuPrefs(storage, { collapsed: false, groups: {} });
  assert.equal(store.get(COLLAPSED_KEY), '0');
  assert.deepEqual(readMenuPrefs(storage), { collapsed: false, groups: {} });
});

test('B2 missing, unparseable or throwing storage gives the defaults', () => {
  const DEF = { collapsed: false, groups: {} };
  assert.deepEqual(readMenuPrefs(storage), DEF);
  store.set(GROUPS_KEY, '{not json');
  store.set(COLLAPSED_KEY, 'yes');
  assert.deepEqual(readMenuPrefs(storage), DEF);
  store.set(GROUPS_KEY, '["reports"]');
  assert.deepEqual(readMenuPrefs(storage), DEF);
  store.set(GROUPS_KEY, '{"reports":"no","logs":false}');
  assert.deepEqual(readMenuPrefs(storage).groups, { logs: false }, 'a non-boolean value is dropped');
  const boom = { getItem() { throw new Error('blocked'); }, setItem() { throw new Error('blocked'); } };
  assert.deepEqual(readMenuPrefs(boom), DEF);
  assert.deepEqual(readMenuPrefs(null), DEF);
  assert.doesNotThrow(() => writeMenuPrefs(boom, { collapsed: true, groups: {} }));
});

test('B3 menuGroups closes a saved-closed group, except the one that holds the active screen', () => {
  const at = (p, saved) => Object.fromEntries(menuGroups(NAV, NAV_GROUPS, p, saved).map((g) => [g.id, g.open]));
  assert.equal(at('/jobs', { reports: false }).reports, false);
  assert.equal(at('/jobs', { reports: false }).logs, true, 'an unsaved group is open');
  assert.equal(at('/costs', { reports: false }).reports, true, 'the active screen keeps its group open');
  const groups = menuGroups(NAV, NAV_GROUPS, '/costs', {});
  assert.deepEqual(groups.map((g) => g.id), NAV_GROUPS.map((g) => g.id));
  assert.deepEqual(groups.flatMap((g) => g.items).filter((i) => i.on).map((i) => i.label), ['COSTS']);
  assert.deepEqual(menuGroups([{ to: '/a', label: 'A', group: 'overview', match: () => false }], NAV_GROUPS, '/', {}).map((g) => g.id),
    ['overview'], 'an empty group is dropped');
});

test('B4 teamLinks builds one link per roster agent; a failed read is an error, not an empty roster', () => {
  const t = teamLinks({ agents: [{ name: 'archie' }, { name: 'watchman' }] }, '/staff/watchman');
  assert.deepEqual(t.links.map((l) => [l.to, l.label, l.on]), [['/staff/archie', 'Archie', false], ['/staff/watchman', 'Watchman', true]]);
  assert.equal(t.error, false);
  assert.deepEqual(teamLinks(null, '/'), { links: [], error: true });
  assert.deepEqual(teamLinks({}, '/'), { links: [], error: true });
  assert.deepEqual(teamLinks({ agents: [] }, '/'), { links: [], error: false });
  assert.equal(teamLinks({ agents: [{ name: 'a b' }] }, '/').links[0].to, '/staff/a%20b', 'the name is encoded');
});

// -------------------------------------------------------------- C: render

test('C1 SideMenu at /jobs renders one link per NAV entry, group heads in NAV_GROUPS order', () => {
  const out = render(h(SideMenu, menuProps()));
  assert.match(out, /<nav id="sidemenu" class="sidemenu"[^>]*aria-label="primary"/);
  for (const n of NAV) {
    const re = new RegExp(`<a href="${n.to.replace(/\//g, '\\/')}"[^>]*class="navlink sidemenu__item`, 'g');
    assert.equal((out.match(re) || []).length, 1, `${n.label} has one link`);
  }
  const heads = [...out.matchAll(/<button[^>]*class="sidemenu__grouphead"[^>]*>([\s\S]*?)<\/button>/g)]
    .map((m) => m[1].replace(/<span[^>]*>[^<]*<\/span>/g, '').trim());
  assert.deepEqual(heads, NAV_GROUPS.map((g) => g.label));
});

test('C2 at /jobs only JOBS is lit, with aria-current; ALERTS carries the badge', () => {
  const out = render(h(SideMenu, menuProps()));
  const on = [...out.matchAll(/<a href="([^"]+)"[^>]*class="navlink sidemenu__item navlink--on"[^>]*>/g)];
  assert.deepEqual(on.map((m) => m[1]), ['/jobs']);
  assert.match(on[0][0], /aria-current="page"/);
  assert.equal((out.match(/aria-current="page"/g) || []).length, 1);
  assert.match(out, /<a href="\/alerts"[^>]*>(?:(?!<\/a>)[\s\S])*class="navlink__badge">2</);
  assert.doesNotMatch(render(h(SideMenu, menuProps({ openAlerts: 0 }))), /navlink__badge/);
});

async function mountRoster(payload, status = 200) {
  const calls = routedFetch((u) => (u.includes('/staff/roster') ? [status, payload] : [200, {}]));
  const m = mountInto(h(SideMenu, menuProps({ path: '/staff' })));
  await flush();
  return { ...m, calls };
}
const teamGroup = (el) => byCls(el, 'sidemenu__group').find((g) => g.attrs['data-group'] === 'team');

test('C3 the Team group lists /staff plus one link per roster agent, and follows the roster', async () => {
  const { el, calls } = await mountRoster(ROSTER);
  assert.equal(calls.filter((c) => c.url.includes('/staff/roster')).length, 1, 'one roster read');
  assert.deepEqual(links(teamGroup(el)).map((a) => a.attrs.href), ['/staff', '/staff/archie', '/staff/watchman', '/staff/mill-scout']);
  for (const r of mounted) mount(null, r);
  mounted.clear();
  const two = await mountRoster({ agents: [{ name: 'archie' }, { name: 'gardener' }] });
  assert.deepEqual(links(teamGroup(two.el)).map((a) => a.attrs.href), ['/staff', '/staff/archie', '/staff/gardener']);
});

test('C4 a failed roster read shows STAFF and "Roster did not load.", and no agent link', async () => {
  const { el } = await mountRoster({ error: 'boom' }, 500);
  assert.deepEqual(links(teamGroup(el)).map((a) => a.attrs.href), ['/staff']);
  assert.match(teamGroup(el).textContent, /Roster did not load\./);
  for (const r of mounted) mount(null, r);
  mounted.clear();
  const empty = await mountRoster({ agents: [] });
  assert.deepEqual(links(teamGroup(empty.el)).map((a) => a.attrs.href), ['/staff']);
  assert.doesNotMatch(teamGroup(empty.el).textContent, /did not load/, 'an empty roster is not an error');
  // while it loads: STAFF and a skeleton line, never a fake agent
  const loading = render(h(SideMenu, menuProps()));
  assert.match(loading, /class="skel"/);
});

test('C5 collapsed: the rail has a title and aria-label on every item and a pressed collapse button', () => {
  store.set(COLLAPSED_KEY, '1');
  const out = render(h(SideMenu, menuProps()));
  assert.match(out, /<nav id="sidemenu" class="sidemenu sidemenu--rail"/);
  const items = [...out.matchAll(/<a href="[^"]+"[^>]*class="navlink sidemenu__item[^"]*"[^>]*>/g)].map((m) => m[0]);
  assert.ok(items.length >= NAV.length);
  for (const n of NAV) {
    const a = items.find((s) => s.includes(`href="${n.to}"`));
    assert.ok(a, n.label);
    assert.match(a, new RegExp(`title="${n.label}"`));
    assert.match(a, new RegExp(`aria-label="${n.label}"`));
  }
  assert.match(out, /<button[^>]*class="sidemenu__collapse"[^>]*aria-pressed="true"[^>]*aria-label="Expand menu"/);
  store.clear();
  assert.match(render(h(SideMenu, menuProps())), /class="sidemenu__collapse"[^>]*aria-pressed="false"[^>]*aria-label="Collapse menu"/);
});

test('C5b a click on collapse turns the rail on and saves it', async () => {
  const { el } = mountInto(h(SideMenu, menuProps()));
  await flush();
  const btn = byCls(el, 'sidemenu__collapse')[0];
  fire(btn, 'click');
  await flush();
  assert.ok(hasCls(all(el).find((n) => n.localName === 'nav'), 'sidemenu--rail'));
  assert.equal(store.get(COLLAPSED_KEY), '1');
});

test('C6 every item is a link or a button that Tab reaches, and sidemenu.css has a :focus-visible outline', () => {
  const out = render(h(SideMenu, menuProps()));
  assert.doesNotMatch(out, /tabindex="-1"/);
  const items = [...out.matchAll(/<(\w+)[^>]*class="(?:navlink sidemenu__item|sidemenu__grouphead|sidemenu__collapse)/g)].map((m) => m[1]);
  assert.ok(items.length > NAV.length);
  assert.deepEqual([...new Set(items)].sort(), ['a', 'button']);
  const css = read('src/sidemenu.css');
  assert.match(css, /\.sidemenu[^{]*:focus-visible[^{]*\{[^}]*outline:\s*2px solid var\(--[a-z-]+\)/);
});

test('C7 a click on a group head closes it and saves it', async () => {
  const { el } = mountInto(h(SideMenu, menuProps()));
  await flush();
  const head = () => byCls(el, 'sidemenu__grouphead').find((b) => b.textContent.includes('Reports'));
  assert.equal(head().attrs['aria-expanded'], 'true');
  fire(head(), 'click');
  await flush();
  assert.equal(head().attrs['aria-expanded'], 'false');
  assert.deepEqual(JSON.parse(store.get(GROUPS_KEY)), { reports: false });
  assert.equal(links(el).find((a) => a.attrs.href === '/costs'), undefined, 'the closed group hides its links');
  fire(head(), 'click');
  await flush();
  assert.equal(head().attrs['aria-expanded'], 'true');
  assert.deepEqual(JSON.parse(store.get(GROUPS_KEY)), { reports: true });
});

// ------------------------------------------------------- D: bar and drawer

const BAR = { path: '/jobs', snap: { snapshot_age_min: 1 }, openAlerts: 2, loading: false, secondsLeft: 5, watchdogDown: false,
  identity: { data: { actor: 'ops@example.invalid', access: 'on', email: 'ops@example.invalid' }, error: null } };

test('D1 TopBar renders the menu button and no section nav', () => {
  const out = render(h(TopBar, { ...BAR, menuOpen: false, onMenu() {} }));
  assert.match(out, /<button[^>]*class="topbar__menu"[^>]*aria-label="Open menu"[^>]*aria-expanded="false"[^>]*aria-controls="sidemenu"/);
  assert.doesNotMatch(out, /topbar__nav/);
  assert.match(render(h(TopBar, { ...BAR, menuOpen: true, onMenu() {} })), /class="topbar__menu"[^>]*aria-expanded="true"/);
});

test('D2 the open drawer closes on Escape, on a scrim click and on a link click', async () => {
  const closes = [];
  const { doc, el } = mountInto(h(SideMenu, menuProps({ open: true, onClose: () => closes.push('x') })));
  await flush();
  assert.ok(hasCls(all(el).find((n) => n.localName === 'nav'), 'sidemenu--open'));
  doc.listeners.keydown({ key: 'Escape', preventDefault() {} });
  assert.equal(closes.length, 1, 'Escape');
  fire(byCls(el, 'sidemenu__scrim')[0], 'click');
  assert.equal(closes.length, 2, 'scrim');
  fire(links(el).find((a) => a.attrs.href === '/costs'), 'click');
  assert.equal(closes.length, 3, 'link');
  assert.equal(window.location.pathname, '/costs', 'the link still navigates');
  // closed: no scrim, no key handler
  for (const r of mounted) mount(null, r);
  mounted.clear();
  const shut = mountInto(h(SideMenu, menuProps({ open: false })));
  await flush();
  assert.equal(byCls(shut.el, 'sidemenu__scrim').length, 0);
  assert.equal(shut.doc.listeners.keydown, undefined);
});

const appRoute = (u) => (u.includes('/staff/roster') ? [200, ROSTER] : [200, {}]);
async function mountApp(at) {
  setUrl(at);
  routedFetch(appRoute);
  const m = mountInto(h(App));
  await flush();
  const nav = () => all(m.el).find((n) => n.localName === 'nav' && n.attrs.id === 'sidemenu');
  const btn = () => byCls(m.el, 'topbar__menu')[0];
  return { ...m, nav, btn };
}

test('D3 App: the hamburger opens the drawer and a path change closes it', async () => {
  const { nav, btn } = await mountApp('/nowhere');
  assert.ok(nav(), 'App renders the side menu');
  assert.ok(!hasCls(nav(), 'sidemenu--open'));
  fire(btn(), 'click');
  await flush();
  assert.ok(hasCls(nav(), 'sidemenu--open'), 'the hamburger opens it');
  assert.equal(btn().attrs['aria-expanded'], 'true');
  navigate('/nowhere-else');
  await flush();
  assert.ok(!hasCls(nav(), 'sidemenu--open'), 'a path change closes it');
  assert.equal(btn().attrs['aria-expanded'], 'false');
});

test('D4 App: focus moves to the first item on open and back to the hamburger on close; Tab cycles', async () => {
  const { doc, nav, btn } = await mountApp('/nowhere');
  fire(btn(), 'click');
  await flush();
  const items = links(nav());
  assert.ok(doc.activeElement === items[0], 'the first item has focus');
  assert.equal(items[0].attrs.href, '/world');
  // Shift+Tab on the first focusable wraps to the last; Tab on the last wraps to the first
  const focusables = all(nav()).filter((n) => n.localName === 'a' || n.localName === 'button');
  focusables[0].focus();
  let prevented = 0;
  doc.listeners.keydown({ key: 'Tab', shiftKey: true, preventDefault() { prevented++; } });
  assert.ok(doc.activeElement === focusables[focusables.length - 1], 'Shift+Tab on the first wraps to the last');
  doc.listeners.keydown({ key: 'Tab', shiftKey: false, preventDefault() { prevented++; } });
  assert.ok(doc.activeElement === focusables[0], 'Tab on the last wraps to the first');
  assert.equal(prevented, 2);
  doc.listeners.keydown({ key: 'Escape', preventDefault() {} });
  await flush();
  assert.ok(!hasCls(nav(), 'sidemenu--open'));
  assert.ok(doc.activeElement === btn(), 'focus is back on the hamburger');
});

test('D5 the rail survives a remount (a reload)', async () => {
  store.set(COLLAPSED_KEY, '1');
  let m = mountInto(h(SideMenu, menuProps()));
  await flush();
  assert.ok(hasCls(all(m.el).find((n) => n.localName === 'nav'), 'sidemenu--rail'));
  for (const r of mounted) mount(null, r);
  mounted.clear();
  store.set(COLLAPSED_KEY, '1');
  m = mountInto(h(SideMenu, menuProps()));
  await flush();
  assert.ok(hasCls(all(m.el).find((n) => n.localName === 'nav'), 'sidemenu--rail'));
  // the open drawer always shows the full menu
  for (const r of mounted) mount(null, r);
  mounted.clear();
  store.set(COLLAPSED_KEY, '1');
  m = mountInto(h(SideMenu, menuProps({ open: true })));
  await flush();
  assert.ok(!hasCls(all(m.el).find((n) => n.localName === 'nav'), 'sidemenu--rail'));
});

// ------------------------------------------------- E: no sideways scroll

const stripComments = (css) => css.replace(/\/\*[\s\S]*?\*\//g, '');
function navRules(css) {
  const out = [];
  const re = /([^{}]+)\{([^{}]*)\}/g;
  for (let m; (m = re.exec(stripComments(css)));) {
    const sel = m[1].trim();
    if (/\.(topbar__nav|bottomnav|sidemenu)\b/.test(sel)) out.push({ sel, body: m[2] });
  }
  return out;
}

test('E1 no nav rule scrolls sideways or hides a scrollbar; the old tab row is gone', () => {
  const bad = [];
  for (const f of ['src/styles.css', 'src/sidemenu.css', 'src/phone-floor.css']) {
    for (const r of navRules(read(f))) {
      if (/overflow(-x)?\s*:\s*(auto|scroll)/.test(r.body)) bad.push(`${f} ${r.sel}: overflow-x auto/scroll`);
      if (/scrollbar-width\s*:\s*none/.test(r.body)) bad.push(`${f} ${r.sel}: scrollbar-width none`);
      if (/::-webkit-scrollbar/.test(r.sel)) bad.push(`${f} ${r.sel}: hides a scrollbar`);
      if (/\.topbar__nav\b/.test(r.sel)) bad.push(`${f} ${r.sel}: .topbar__nav still styled`);
    }
  }
  assert.deepEqual(bad, []);
  assert.ok(navRules(read('src/styles.css')).some((r) => r.sel === '.bottomnav' && /overflow:\s*hidden/.test(r.body)), '.bottomnav clips, one row');
});

test('E2 BottomNav renders exactly the five key tabs, with the alert badge', () => {
  const out = render(h(BottomNav, { path: '/jobs', openAlerts: 3 }));
  assert.deepEqual([...out.matchAll(/<a href="([^"]+)"/g)].map((m) => m[1]), ['/', '/now', '/kanban', '/alerts', '/needs']);
  assert.match(out, /class="bottomnav__badge">3</);
});

test('E3 the side menu scrolls up and down, never sideways', () => {
  const r = navRules(read('src/sidemenu.css')).find((x) => x.sel === '.sidemenu');
  assert.ok(r, '.sidemenu rule');
  assert.match(r.body, /overflow-y:\s*auto/);
  assert.match(r.body, /overflow-x:\s*hidden/);
  assert.match(read('src/main.js'), /import '\.\/sidemenu\.css';/);
});
