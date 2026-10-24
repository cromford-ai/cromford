// BH-7978 (BH-7939.4, slice C0): the fleet Machines page in the settings
// shell. The Fly org field, the read-only state of the Fly API token and the
// fleet Tailscale key, and the "no token" gate on the Provision a box button.
//
// G* drive the pure helpers (src/lib/fly-settings.js), M* mount the real page
// (src/screens/settings/fleet/Machines.js) into the fake DOM with seeded
// settings rows, S1 goes through the real shell menu, B1 counts the URLs.
// Onboard step 1 Advanced and the ProjectReady cards (C1-C9 of the parent
// plan) come in slice C1.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';
import {
  installDom, routedFetch, all, fire, isDisabled, buttonIn, byName, type
} from './helpers/fake-dom.bh-5750.js';

installDom();
window.location.pathname = '/settings/fleet/machines';

const {
  flySettingsFrom, checkFlyOrg, flyGate, FLY_GATE_TEXT, FLY_TOKEN_HREF
} = await import('../src/lib/fly-settings.js');
const { FleetMachinesScreen } = await import('../src/screens/settings/fleet/Machines.js');
const { SETTINGS_MENU } = await import('../src/lib/settings-menu.js');
const { SETTINGS_SCREENS, SettingsShellView } = await import('../src/screens/settings/Shell.js');
const { render } = await import('preact-render-to-string');

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const mounted = new Set();
test.afterEach(() => { for (const r of mounted) mount(null, r); mounted.clear(); });

const row = (key, value) => ({ key, value, note: null, updated_at: '2026-10-24T00:00:00Z' });

// Mount the real page with these settings rows. `put` answers the settings PUT.
async function mountPage(rows, { put = () => [200, { ok: true }] } = {}) {
  const doc = installDom();
  const state = { rows: [...rows] };
  const calls = routedFetch((u, method, body) => {
    if (u === '/api/coord/settings' && method === 'GET') return [200, { settings: state.rows }];
    if (u === '/api/coord/settings' && method === 'PUT') return put(body, state);
    return [404, { error: `unrouted ${method} ${u}` }];
  });
  const el = doc.createElement('div');
  mounted.add(el);
  mount(h(FleetMachinesScreen, {}), el);
  await flush();
  return { el, calls, state };
}
const text = (el) => el.textContent.replace(/\s+/g, ' ');
const byId = (el, id) => all(el).find((n) => n.attrs && n.attrs.id === id);
// The fake DOM keeps a rendered value as an attribute, a typed one as a property.
const valueOf = (n) => (n.value !== undefined ? n.value : n.attrs.value);
const provision = (el) => buttonIn(el, 'PROVISION A BOX');

// ------------------------------------------------------------- pure helpers

test('G1: flySettingsFrom reads both answer shapes', () => {
  const rows = [row('fly.org', '  acme-fleet '), row('fly.token_present', '1'), row('tailscale.key_present', '1'), row('other', 'x')];
  for (const res of [rows, { settings: rows }]) {
    const s = flySettingsFrom(res);
    assert.equal(s.org, 'acme-fleet');
    assert.equal(s.tokenPresent, true);
    assert.equal(s.tailscalePresent, true);
  }
  for (const res of [[], { settings: [] }, null, undefined, {}, [null]]) {
    const s = flySettingsFrom(res);
    assert.equal(s.org, '');
    assert.equal(s.tokenPresent, false);
    assert.equal(s.tailscalePresent, false);
  }
});

test('G2: every value that is not 1 closes the gate, with the text and the link', () => {
  for (const v of [undefined, '', '0', 'true', 'yes', '11', null, ' ', '1.0']) {
    const rows = v === undefined ? [] : [row('fly.token_present', v)];
    const s = flySettingsFrom(rows);
    assert.equal(s.tokenPresent, false, `value ${JSON.stringify(v)}`);
    const g = flyGate(s);
    assert.equal(g.enabled, false);
    assert.equal(g.reason, 'Add your Fly API token first');
    assert.equal(g.href, '/settings/fleet/machines#fly-token');
  }
  assert.equal(FLY_GATE_TEXT, 'Add your Fly API token first');
  assert.equal(FLY_TOKEN_HREF, '/settings/fleet/machines#fly-token');
  assert.equal(flyGate({}).enabled, false);
});

test('G3: 1 opens the gate; checkFlyOrg keeps to the slug rule', () => {
  for (const v of ['1', ' 1 ']) {
    const g = flyGate(flySettingsFrom([row('fly.token_present', v)]));
    assert.equal(g.enabled, true, `value ${JSON.stringify(v)}`);
  }
  for (const ok of ['my-org', 'a', 'a'.repeat(63), '  my-org  ', '9lives']) {
    const c = checkFlyOrg(ok);
    assert.equal(c.ok, true, `accepts ${JSON.stringify(ok)}`);
    assert.equal(c.value, ok.trim());
  }
  for (const bad of ['', '   ', 'My-Org', '-org', 'a b', 'org;rm', 'a'.repeat(64), 'org_x', null, undefined]) {
    const c = checkFlyOrg(bad);
    assert.equal(c.ok, false, `refuses ${JSON.stringify(bad)}`);
    assert.match(c.message, /lower-case letters, digits and -/);
  }
});

// ------------------------------------------------------------- the page

test('M1: the page shows the Fly org field with the stored value and a label', async () => {
  const { el } = await mountPage([row('fly.org', 'acme-fleet')]);
  const input = byId(el, 'fly-org');
  assert.ok(input, 'input#fly-org is in the page');
  assert.equal(input.attrs.name, 'fly-org');
  assert.equal(valueOf(input), 'acme-fleet');
  const label = all(el).find((n) => n.localName === 'label' && n.attrs.for === 'fly-org');
  assert.ok(label, 'a <label for="fly-org">');
  assert.match(label.textContent, /Fly org/);
});

test('M2: the Fly API token row says added only when the row is 1', async () => {
  const none = await mountPage([]);
  assert.match(text(byId(none.el, 'fly-token')), /Fly API token\s*not added/);
  assert.match(text(none.el), /Adding it here comes with the fleet accounts update\./);
  mount(null, none.el);
  const zero = await mountPage([row('fly.token_present', '0')]);
  assert.match(text(byId(zero.el, 'fly-token')), /not added/);
  mount(null, zero.el);
  const one = await mountPage([row('fly.token_present', '1')]);
  const t = text(byId(one.el, 'fly-token'));
  assert.match(t, /Fly API token\s*added/);
  assert.doesNotMatch(t, /not added/);
});

test('M3: the Tailscale key row reads its own flag, and no secret value is shown', async () => {
  const decoy = 'fo1_fixture_secret_value_should_not_render';
  const on = await mountPage([row('tailscale.key_present', '1'), row('fly.token', decoy), row('tailscale.key', `${decoy}-ts`)]);
  const ts = text(byId(on.el, 'tailscale-key'));
  assert.match(ts, /Tailscale key\s*added/);
  assert.doesNotMatch(ts, /not added/);
  assert.match(text(byId(on.el, 'fly-token')), /not added/, 'the Tailscale flag does not open the Fly row');
  assert.doesNotMatch(text(on.el), /fixture_secret/);
  const attrs = all(on.el).flatMap((n) => Object.values(n.attrs || {}));
  assert.ok(!attrs.some((v) => String(v).includes('fixture_secret')), 'no attribute holds the secret');
  mount(null, on.el);
  const off = await mountPage([row('fly.token_present', '1')]);
  assert.match(text(byId(off.el, 'tailscale-key')), /not added/);
});

test('M4: SAVE sends one PUT for fly.org and reloads the settings read', async () => {
  const { el, calls } = await mountPage([row('fly.org', 'old-org')], {
    put: (body, state) => { state.rows = [row('fly.org', body.value)]; return [200, { ok: true }]; }
  });
  type(byName(el, 'fly-org'), 'new-org');
  await flush();
  fire(buttonIn(el, 'SAVE'), 'click');
  await flush();
  const puts = calls.filter((c) => c.method === 'PUT');
  assert.equal(puts.length, 1);
  assert.equal(puts[0].url, '/api/coord/settings');
  assert.equal(puts[0].body.key, 'fly.org');
  assert.equal(puts[0].body.value, 'new-org');
  assert.match(puts[0].body.reason, /fly org/);
  assert.equal(calls.filter((c) => c.method === 'GET' && c.url === '/api/coord/settings').length, 2, 'one read on mount, one reload');
  assert.equal(valueOf(byId(el, 'fly-org')), 'new-org');
  assert.match(text(byId(el, 'fly-org-status')), /saved/);
});

test('M5: an invalid org sends nothing; a failed PUT shows the error and keeps the typed value', async () => {
  const bad = await mountPage([]);
  type(byName(bad.el, 'fly-org'), 'Bad Org');
  await flush();
  fire(buttonIn(bad.el, 'SAVE'), 'click');
  await flush();
  assert.equal(bad.calls.filter((c) => c.method === 'PUT').length, 0);
  assert.match(text(byId(bad.el, 'fly-org-status')), /lower-case letters, digits and -/);
  mount(null, bad.el);

  const fail = await mountPage([], { put: () => [500, { error: 'settings write failed' }] });
  type(byName(fail.el, 'fly-org'), 'good-org');
  await flush();
  fire(buttonIn(fail.el, 'SAVE'), 'click');
  await flush();
  assert.equal(fail.calls.filter((c) => c.method === 'PUT').length, 1);
  const status = text(byId(fail.el, 'fly-org-status'));
  assert.doesNotMatch(status, /saved/);
  assert.match(status, /could not save/);
  assert.equal(valueOf(byId(fail.el, 'fly-org')), 'good-org');
});

test('M6: Provision a box is disabled; with no token it shows the gate text and link', async () => {
  const none = await mountPage([]);
  const btn = provision(none.el);
  assert.ok(btn, 'the Provision a box button is in the page');
  assert.equal(isDisabled(btn), true);
  const reason = byId(none.el, btn.attrs['aria-describedby']);
  assert.ok(reason, 'aria-describedby points at the reason line');
  assert.match(text(reason), /Add your Fly API token first/);
  const link = all(reason).find((n) => n.localName === 'a');
  assert.ok(link, 'the reason line holds a link');
  assert.equal(link.attrs.href, '/settings/fleet/machines#fly-token');
  mount(null, none.el);

  const one = await mountPage([row('fly.token_present', '1')]);
  const b2 = provision(one.el);
  assert.equal(isDisabled(b2), true);
  assert.match(text(byId(one.el, b2.attrs['aria-describedby'])), /Not built yet/);
  assert.doesNotMatch(text(one.el), /Add your Fly API token first/);
});

test('M7: the page calls no native dialog', () => {
  const src = fs.readFileSync(path.join(root, 'src/screens/settings/fleet/Machines.js'), 'utf8');
  const code = src.split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
  assert.ok(code.includes('FleetMachinesScreen'), 'read the real page source');
  assert.doesNotMatch(code, /\b(confirm|alert|prompt)\s*\(/);
});

test('M8: a failed settings read shows the error and RETRY reads again', async () => {
  const doc = installDom();
  let fail = true;
  const calls = routedFetch((u) => (fail ? [502, { error: 'coord down' }] : [200, { settings: [row('fly.org', 'acme-fleet')] }]));
  const el = doc.createElement('div');
  mounted.add(el);
  mount(h(FleetMachinesScreen, {}), el);
  await flush();
  assert.match(text(el), /could not load/);
  assert.equal(byId(el, 'fly-org'), undefined, 'no form while the read failed');
  fail = false;
  fire(buttonIn(el, 'RETRY'), 'click');
  await flush();
  assert.equal(calls.length, 2);
  assert.equal(valueOf(byId(el, 'fly-org')), 'acme-fleet');
});

// ------------------------------------------------------------- the shell

test('S1: the menu row links to the page, and the shell mounts it', async () => {
  assert.equal(SETTINGS_SCREENS.machines, FleetMachinesScreen);
  const loaded = { data: { projects: [] }, error: null, loading: false };
  const out = render(h(SettingsShellView, { scope: 'fleet', page: 'lanes', projects: loaded }));
  assert.match(out, /<a[^>]*href="\/settings\/fleet\/machines"[^>]*>Machines and Tailscale<\/a>/);
  assert.doesNotMatch(out, /aria-disabled="true"[^>]*>Machines and Tailscale/);

  // The real shell, the real registry, the real screen map: the page mounts.
  const doc = installDom();
  const calls = routedFetch((u, method) => (u === '/api/coord/settings' && method === 'GET'
    ? [200, { settings: [] }] : [404, {}]));
  const el = doc.createElement('div');
  mounted.add(el);
  mount(h(SettingsShellView, { menu: SETTINGS_MENU, screens: SETTINGS_SCREENS, scope: 'fleet', page: 'machines', projects: loaded }), el);
  await flush();
  assert.doesNotMatch(text(el), /Not built yet( \(soon\))?\./);
  assert.ok(byId(el, 'fly-org'), 'the Machines page is mounted');
  assert.ok(provision(el), 'Provision a box is on the page');
  // B1: the page asks for exactly one URL on mount.
  assert.deepEqual(calls.map((c) => `${c.method} ${c.url}`), ['GET /api/coord/settings']);
});
