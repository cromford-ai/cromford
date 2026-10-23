// BH-7938 (slice C0): the settings side menu. The registry is data
// (src/lib/settings-menu.js), the shell renders it (src/screens/settings/Shell.js),
// and App resolves the legacy /settings and /settings/appearance paths to the
// shell with a replace, so the first paint is already the new screen.
//
// R* drive the registry, S* render the shell, A* go through the real ROUTES
// table and the real App, B1 counts every URL the shell asks for, C1 reads the
// stylesheet. The 390px chip row is measured in a browser by
// tests/drive/settings-shell.bh-7938-drive.mjs.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';
import { installDom, routedFetch, all } from './helpers/fake-dom.bh-5750.js';

// A window whose history really moves location, so a replace is visible to
// the router and App re-renders on the new path rather than looping.
const replaced = [];
const pushed = [];
const setUrl = (to) => {
  const u = new URL(to, 'http://console.test');
  Object.assign(window.location, { pathname: u.pathname, search: u.search, hash: u.hash });
};
globalThis.window = globalThis.window || {
  location: { pathname: '/settings', search: '', hash: '' },
  dispatchEvent() { return true; }, addEventListener() {}, removeEventListener() {},
  history: {
    pushState(_s, _t, to) { pushed.push(to); setUrl(to); },
    replaceState(_s, _t, to) { replaced.push(to); setUrl(to); }
  },
  scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} })
};

const { ROUTES, App, resolveRoute } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const {
  SETTINGS_MENU, LEGACY_REDIRECTS, itemHref, menuFor, findItem, redirectFor
} = await import('../src/lib/settings-menu.js');
const {
  SETTINGS_SCREENS, SettingsShellView, SettingsFleetScreen, SettingsProjectScreen
} = await import('../src/screens/settings/Shell.js');
const { SettingsScreen, LaneDetailScreen } = await import('../src/screens/Settings.js');
const { AppearanceScreen } = await import('../src/screens/Appearance.js');
const { render } = await import('preact-render-to-string');

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const mounted = new Set();
test.afterEach(() => { for (const r of mounted) mount(null, r); mounted.clear(); });

const loaded = (rows) => ({ data: { projects: rows }, error: null, loading: false });
const LOADING = { data: null, error: null, loading: true };
const view = (props) => render(h(SettingsShellView, { projects: loaded([]), ...props }));
const Probe = (label) => () => h('p', { class: 'probe' }, label);
const stubScreens = { lanes: Probe('LANES PAGE'), appearance: Probe('APPEARANCE PAGE') };

// ------------------------------------------------------------- registry

test('R1: the fleet and project rows of decision 3, in order, with their tags', () => {
  const ids = (scope) => SETTINGS_MENU[scope].flatMap((g) => g.items.map((i) => i.id));
  assert.deepEqual(ids('fleet'), ['ai-vendors', 'github-app', 'machines', 'prompts', 'lanes', 'appearance']);
  assert.deepEqual(ids('project'), ['general', 'tickets', 'ai-accounts', 'builds', 'deploy', 'alerts', 'prompts', 'pause']);
  assert.equal(findItem(SETTINGS_MENU, 'fleet', 'lanes').tag, undefined);
  assert.equal(findItem(SETTINGS_MENU, 'fleet', 'appearance').tag, undefined);
  assert.equal(findItem(SETTINGS_MENU, 'fleet', 'prompts').tag, 'wave 6b');
  assert.equal(findItem(SETTINGS_MENU, 'project', 'prompts').tag, 'wave 6b');
  assert.equal(findItem(SETTINGS_MENU, 'fleet', 'ai-vendors').tag, 'wave 4');
  assert.equal(findItem(SETTINGS_MENU, 'project', 'ai-accounts').tag, 'wave 4');
  assert.equal(findItem(SETTINGS_MENU, 'project', 'tickets').tag, 'wave 3');
  assert.equal(findItem(SETTINGS_MENU, 'fleet', 'nope'), null);
  assert.ok(LEGACY_REDIRECTS.length >= 3);
});

test('R2: redirectFor sends the legacy paths to the shell and leaves every near miss alone', () => {
  const cases = [
    [['/settings'], '/settings/fleet/lanes'],
    [['/settings/'], '/settings/fleet/lanes'],
    [['/settings', '?project=project-3'], '/settings/fleet/lanes?project=project-3'],
    [['/settings/appearance'], '/settings/fleet/appearance'],
    [['/settings/appearance', '', '#custom'], '/settings/fleet/appearance#custom'],
    [['/settings/fleet'], '/settings/fleet/lanes'],
    [['/settings/merge-conductor'], null],
    [['/settings/run-triage', '?project=x'], null],
    [['/settings/fleet/lanes'], null],
    [['/settings/p/project-3/general'], null],
    [['/settingsx'], null],
    [['/config'], null],
    [['/settings/appearancex'], null],
    [['/'], null]
  ];
  for (const [args, want] of cases) assert.equal(redirectFor(...args), want, `redirectFor(${JSON.stringify(args)})`);
});

test('R3: menuFor resolves hrefs, marks the active row, and gives a tagged row no href', () => {
  const groups = menuFor(SETTINGS_MENU, { scope: 'fleet', page: 'lanes' });
  const items = groups.flatMap((g) => g.items);
  const lanes = items.find((i) => i.id === 'lanes');
  assert.equal(lanes.href, '/settings/fleet/lanes');
  assert.equal(lanes.current, true);
  assert.equal(items.filter((i) => i.current).length, 1);
  for (const i of items.filter((x) => x.tag)) assert.equal(i.href, null, `${i.id} is tagged`);
  assert.equal(items.find((i) => i.id === 'appearance').href, '/settings/fleet/appearance');
});

test('R4: a project name is URI-encoded in the href and decoded by the route', () => {
  const href = itemHref('project', 'general', 'a b@c');
  assert.equal(href, '/settings/p/a%20b%40c/general');
  assert.deepEqual(matchRoute('/settings/p/:project/:page', href), { project: 'a b@c', page: 'general' });
  assert.equal(itemHref('fleet', 'lanes'), '/settings/fleet/lanes');
});

// ------------------------------------------------------------- shell

test('S1: a new page is one registry row plus one screen entry', () => {
  const menu = {
    ...SETTINGS_MENU,
    fleet: SETTINGS_MENU.fleet.map((g, i) => (i === 0 ? { ...g, items: [...g.items, { id: 'zz-test', label: 'ZZ test' }] } : g))
  };
  const screens = { ...stubScreens, 'zz-test': Probe('FIXTURE PAGE') };
  const out = view({ menu, screens, scope: 'fleet', page: 'zz-test' });
  assert.match(out, /<a[^>]*href="\/settings\/fleet\/zz-test"[^>]*aria-current="page"[^>]*>ZZ test<\/a>/);
  assert.match(out, /FIXTURE PAGE/);
  const r = resolveRoute('/settings/fleet/zz-test');
  assert.equal(r.Component, SettingsFleetScreen);
  assert.equal(r.params.page, 'zz-test');
  assert.equal(r.redirect, null);
});

test('S2: a tagged row is disabled, shows its tag, and its page mounts nothing', () => {
  const out = view({ screens: stubScreens, scope: 'fleet', page: 'lanes' });
  assert.match(out, /<span[^>]*aria-disabled="true"[^>]*>Prompts\s*<span class="tag">wave 6b<\/span><\/span>/);
  assert.doesNotMatch(out, /href="[^"]*\/prompts"/);
  const page = view({ screens: { ...stubScreens, prompts: Probe('SHOULD NOT MOUNT') }, scope: 'fleet', page: 'prompts' });
  assert.match(page, /Not built yet \(wave 6b\)\./);
  assert.doesNotMatch(page, /SHOULD NOT MOUNT/);
});

test('S3: a project swaps in its own menu with a back link; the fleet menu lists projects by name', () => {
  const p = view({ screens: stubScreens, scope: 'project', project: 'project-3', page: 'general', projects: loaded([{ project: 'project-3' }]) });
  assert.match(p, /<a[^>]*href="\/settings\/fleet\/lanes"[^>]*>← ALL SETTINGS<\/a>/);
  assert.match(p, /project-3/);
  for (const label of ['General', 'Tickets', 'AI accounts', 'Builds and machines', 'Deploy and QA', 'Alerts', 'Prompts', 'Pause and remove']) {
    assert.ok(p.includes(`>${label}`), `project row ${label}`);
  }
  assert.doesNotMatch(p, />FLEET</);
  assert.doesNotMatch(p, />Lanes</);

  const f = view({ screens: stubScreens, scope: 'fleet', page: 'lanes', projects: loaded([{ project: 'zeta' }, { project: 'alpha' }]) });
  assert.match(f, />FLEET</);
  assert.match(f, />PROJECTS</);
  const a = f.indexOf('href="/settings/p/alpha"');
  const z = f.indexOf('href="/settings/p/zeta"');
  assert.ok(a > 0 && z > a, 'alpha links before zeta');
  assert.doesNotMatch(f, /← ALL SETTINGS/);
});

test('S4: lanes mounts SettingsScreen and appearance mounts AppearanceScreen', () => {
  assert.equal(SETTINGS_SCREENS.lanes, SettingsScreen);
  assert.equal(SETTINGS_SCREENS.appearance, AppearanceScreen);
  assert.match(view({ screens: stubScreens, scope: 'fleet', page: 'lanes' }), /LANES PAGE/);
  assert.match(view({ screens: stubScreens, scope: 'fleet', page: 'appearance' }), /APPEARANCE PAGE/);
});

test('S5: an unknown page and an unknown project say so, but not while the list loads', () => {
  const nope = view({ screens: stubScreens, scope: 'fleet', page: 'nope' });
  assert.match(nope, /No settings page called nope\./);
  assert.doesNotMatch(nope, /LANES PAGE/);
  const ghost = view({ screens: stubScreens, scope: 'project', project: 'ghost', page: 'general', projects: loaded([{ project: 'project-3' }]) });
  assert.match(ghost, /No project called ghost\./);
  const wait = view({ screens: stubScreens, scope: 'project', project: 'ghost', page: 'general', projects: LOADING });
  assert.doesNotMatch(wait, /No project called/);
  const failed = view({ screens: stubScreens, scope: 'project', project: 'ghost', page: 'general', projects: { data: null, error: new Error('x'), loading: false } });
  assert.doesNotMatch(failed, /No project called/);
});

test('S6: a projects-load error is an inline line, not an empty group', () => {
  const out = view({ screens: stubScreens, scope: 'fleet', page: 'lanes', projects: { data: null, error: new Error('hub 502'), loading: false } });
  assert.match(out, /could not load projects/);
  assert.match(out, /hub 502/);
  const loading = view({ screens: stubScreens, scope: 'fleet', page: 'lanes', projects: LOADING });
  assert.match(loading, /class="skel"/);
});

test('S7: a project with no page asks for one and links to its lanes', () => {
  const out = view({ screens: stubScreens, scope: 'project', project: 'project-3', projects: loaded([{ project: 'project-3' }]) });
  assert.match(out, /Pick a page\./);
  assert.match(out, /href="\/settings\/fleet\/lanes\?project=project-3"/);
});

// ------------------------------------------------------------- routes and App

test('A1: the legacy paths resolve to the shell, with the redirect kept for the address bar', () => {
  const r = resolveRoute('/settings', '?project=project-3', '');
  assert.equal(r.Component, SettingsFleetScreen);
  assert.deepEqual(r.params, { page: 'lanes' });
  assert.equal(r.redirect, '/settings/fleet/lanes?project=project-3');
  const a = resolveRoute('/settings/appearance');
  assert.equal(a.Component, SettingsFleetScreen);
  assert.equal(a.params.page, 'appearance');
  assert.equal(a.redirect, '/settings/fleet/appearance');
  const p = resolveRoute('/settings/p/project-3');
  assert.equal(p.Component, SettingsProjectScreen);
  assert.deepEqual(p.params, { project: 'project-3' });
  const pp = resolveRoute('/settings/p/project-3/tickets');
  assert.equal(pp.Component, SettingsProjectScreen);
  assert.deepEqual(pp.params, { project: 'project-3', page: 'tickets' });
});

test('A2: a lane still opens LaneDetail, and the legacy ROUTES rows are unchanged', () => {
  const r = resolveRoute('/settings/merge-conductor');
  assert.equal(r.Component, LaneDetailScreen);
  assert.equal(r.redirect, null);
  const first = (p) => ROUTES.find(([pat]) => matchRoute(pat, p));
  assert.equal(first('/settings/appearance')[1], AppearanceScreen);
  assert.equal(first('/settings')[1], SettingsScreen);
  assert.equal(resolveRoute('/no/such/screen').Component, null);
});

const apiRoute = (u) => {
  if (u.startsWith('/api/dash/projects')) return [200, { projects: [{ project: 'project-3' }, { project: 'alpha' }] }];
  if (u.startsWith('/api/coord/settings')) return [200, { settings: [] }];
  return [200, {}];
};

test('A3: App at /settings replaces the URL once and paints the shell', async () => {
  const doc = installDom();
  window.location.pathname = '/settings';
  window.location.search = '?project=project-3';
  window.location.hash = '';
  replaced.length = 0;
  const calls = routedFetch(apiRoute);
  const registryReads = () => calls.filter((c) => c.url === '/api/coord/lanes/registry').length;
  const el = doc.createElement('div');
  mounted.add(el);
  mount(h(App), el);
  await flush();
  assert.deepEqual(replaced, ['/settings/fleet/lanes?project=project-3']);
  assert.equal(window.location.pathname, '/settings/fleet/lanes');
  const nav = all(el).find((n) => n.localName === 'nav' && (n.attrs.class || '').split(' ').includes('settings-menu'));
  assert.ok(nav, 'nav.settings-menu is in the DOM');
  const cur = all(nav).find((n) => n.attrs && n.attrs['aria-current'] === 'page');
  assert.equal(cur && cur.textContent.trim(), 'Lanes');
  // The redirect did not remount the lanes page: the registry was read once.
  assert.equal(registryReads(), 1);

  // A project tab on the lanes page pushes the legacy /settings?project= URL
  // (Settings.js onTab). It lands back on the shell with no remount.
  const { navigate } = await import('../src/router.js');
  navigate('/settings?project=alpha');
  await flush();
  assert.deepEqual(replaced, ['/settings/fleet/lanes?project=project-3', '/settings/fleet/lanes?project=alpha']);
  assert.equal(window.location.pathname + window.location.search, '/settings/fleet/lanes?project=alpha');
  assert.equal(registryReads(), 1, 'the tab switch kept the mounted lanes page');
});

test('B1: the shell and its pages ask only same-origin /api/ URLs', async () => {
  const doc = installDom();
  window.location.pathname = '/settings/fleet/lanes';
  window.location.search = '';
  const calls = routedFetch(apiRoute);
  for (const node of [
    h(SettingsFleetScreen, { page: 'lanes' }),
    h(SettingsFleetScreen, { page: 'appearance' }),
    h(SettingsProjectScreen, { project: 'project-3' })
  ]) {
    const el = doc.createElement('div');
    mounted.add(el);
    mount(node, el);
  }
  await flush();
  assert.ok(calls.length > 0, 'the screens made their reads');
  assert.ok(calls.some((c) => c.url === '/api/dash/projects'), 'the shell read the project list');
  for (const c of calls) assert.ok(c.url.startsWith('/api/'), `same-origin API call: ${c.url}`);
});

test('C1: the shell stylesheet uses tokens only (no hex, no rgb/rgba)', () => {
  const css = fs.readFileSync(path.join(root, 'src/settings-shell.css'), 'utf8');
  assert.ok(css.includes('.settings-menu'), 'the stylesheet styles the menu');
  assert.doesNotMatch(css, /#[0-9a-f]{3,8}\b/i);
  assert.doesNotMatch(css, /rgba?\(/i);
  const main = fs.readFileSync(path.join(root, 'src/main.js'), 'utf8');
  assert.match(main, /^import '\.\/settings-shell\.css';$/m);
});
