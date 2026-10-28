// BH-8674 (slice C1 of BH-7924): the /connections screen (src/screens/Connections.js), its pure half
// (src/lib/connections.js), the PROBE NOW fallback in the Pages proxy
// (functions/_lib/connection-probe-command.js + functions/api/[[path]].js), the
// coord write row (functions/_lib/coord-writes.d/7924-connections.js) and the
// two entry points (the Settings menu row and the Project page link).
//
//   C1 four rows render, one per project, each PROJECT cell links to /p/<p>
//   C2 each of the 6 data columns sorts asc then desc, with aria-sort
//   C3 EDIT opens the in-app Modal (a native dialog throws); Escape closes it;
//      no OAuth control
//   C4 a token-shaped value is refused with the env var name, never echoed;
//      confirm stays blocked; the near misses pass; a good save PUTs the body
//   C5 PROBE NOW sends the run_script command; "probe queued" only on an
//      answer with command_id or ok; the Pages fallback queues it and refuses
//      any other script or args
//   C6 a failed row shows the error and the missing var names as visible text
//   C7 ?project=<p> highlights that row only
//   C8 the table sits in the overflow-x:auto wrapper; no card wall, no fixed
//      page width (a real 375 px measure is a QA screen, not this suite)
//   C9 the Settings menu row reaches the screen, and the Project page's
//      CONNECTION link opens it with the row highlighted (the entry points)
//   C10 (BH-8674) the LAST PROBE stale bound is the knob
//      connections.probe_stale_min, read in parallel; a bad or missing answer
//      is the fallback 120
//   C11 (BH-8674) no OAuth control and no billing surface; the form sends no
//      key outside the coord write row's body list
//
// Fixture tokens carry the word "fixture" (D64). Every mount uses the fake
// DOM of tests/helpers/fake-dom.bh-5750.js, whose native dialogs throw.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { h, render as mount } from 'preact';
import { render } from 'preact-render-to-string';
import { flush } from './helpers/settle.js';
import {
  installDom, routedFetch, all, fire, isDisabled, dialogOf, buttonIn, byName, rowsOf
} from './helpers/fake-dom.bh-5750.js';

// A window whose history really moves location (the settings-shell pattern),
// so a Link click lands on the next screen through the real router.
const setUrl = (to) => {
  const u = new URL(to, 'http://console.test');
  Object.assign(window.location, { pathname: u.pathname, search: u.search, hash: u.hash });
};
globalThis.window = globalThis.window || {
  location: { pathname: '/connections', search: '', hash: '' },
  dispatchEvent() { return true; }, addEventListener() {}, removeEventListener() {},
  history: { pushState(_s, _t, to) { setUrl(to); }, replaceState(_s, _t, to) { setUrl(to); } },
  scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} })
};

const { App } = await import('../src/app.js');
const {
  connectionRows, checkConnectionForm, credentialSummary, isTokenShaped, envVarFor, PROBE_QUEUED,
  probeStaleMin, PROBE_STALE_KEY, PROBE_STALE_MIN, draftFor
} = await import('../src/lib/connections.js');
const { ConnectionsScreen, ConnectionsView } = await import('../src/screens/Connections.js');
const { SETTINGS_MENU, findItem } = await import('../src/lib/settings-menu.js');
const { SETTINGS_SCREENS } = await import('../src/screens/settings/Shell.js');
const { CONNECTION_PROBE_TYPES, connectionProbeCommand } = await import('../functions/_lib/connection-probe-command.js');
const { onRequest: dash } = await import('../functions/api/[[path]].js');
const { onRequest: coord } = await import('../functions/api/coord/[[path]].js');
const { FRAGMENT_WRITES } = await import('./lib/coord-writes.node.js');

const mounted = new Set();
test.afterEach(() => { for (const r of mounted) mount(null, r); mounted.clear(); });

// The GET /api/connections shape (plan T3), four adapters.
const API = {
  as_of: '2026-10-27T17:30:00Z',
  webhookSecrets: { linear: true, jira: false },
  connections: [
    {
      project: 'alpha-linear', adapter: 'linear', adapterSource: 'row', team: 'CRO', label: 'ai-build',
      states: null, jira: null,
      webhookRoute: { key: 'cro', repo: 'example-org/cromford-sandbox-linear' },
      status: {
        adapter: 'linear', ok: true, checkedAt: '2026-10-27T17:00:00Z', error: null,
        credentialVars: { LINEAR_API_KEY: 'present' }, webhookRoute: 'webhook_route.linear.cro', webhookSecret: 'present'
      }
    },
    {
      project: 'bravo-jira', adapter: 'jira', adapterSource: 'row', team: null, label: 'ai-build', states: null,
      jira: { write_projects: 'SCRUM', read_projects: 'SCRUM', comment_projects: '', status_map: 'review=In Review;done=Done' },
      webhookRoute: { key: 'scrum', repo: 'example-org/cromford-sandbox-jira' },
      status: {
        adapter: 'jira', ok: false, checkedAt: '2026-10-27T15:00:00Z',
        error: 'jira: HTTP 401 Unauthorized from /rest/api/3/myself',
        credentialVars: { JIRA_BASE: 'present', JIRA_EMAIL: 'present', JIRA_API_TOKEN: 'missing' },
        webhookRoute: null, webhookSecret: 'missing'
      }
    },
    {
      project: 'charlie-board', adapter: 'board', adapterSource: 'registry', team: null, label: null, states: null,
      jira: null, webhookRoute: null, status: null
    },
    {
      project: 'delta-gh', adapter: 'github-issues', adapterSource: 'registry', team: null, label: null, states: null,
      jira: null, webhookRoute: null,
      status: { adapter: 'github-issues', ok: true, checkedAt: '2026-10-27T16:00:00Z', error: null, credentialVars: {}, webhookRoute: null, webhookSecret: 'missing' }
    }
  ]
};
const PROJECTS = API.connections.map((c) => c.project);

// One fake API for the mounted screens. `put` and `action` answers can be
// swapped per test; every call is kept.
function apiFake({ put = [200, { ok: true }], action = [200, { ok: true, type: 'run_script', command_id: 41 }], setting = null } = {}) {
  return routedFetch((u, method) => {
    if (setting && u === `/api/coord/settings/${encodeURIComponent(PROBE_STALE_KEY)}`) return setting;
    if (u.startsWith('/api/coord/connections') && method === 'PUT') return put;
    if (u.startsWith('/api/coord/connections')) return [200, API];
    if (u.startsWith('/api/dash/action')) return action;
    if (u.startsWith('/api/dash/projects')) return [200, { projects: PROJECTS.map((project) => ({ project })) }];
    if (u.startsWith('/api/dash/p/')) return [200, { runs: [], builds: [], alerts: [], board: {} }];
    if (u.startsWith('/api/coord/settings')) return [200, { settings: [] }];
    return [200, {}];
  });
}

async function mountScreen(search = '', fake = {}) {
  const doc = installDom();
  setUrl(`/connections${search}`);
  const calls = apiFake(fake);
  const el = doc.createElement('div');
  mounted.add(el);
  mount(h(ConnectionsScreen, {}), el);
  await flush();
  return { el, calls, doc };
}

async function mountApp(path, fake = {}) {
  const doc = installDom();
  setUrl(path);
  const calls = apiFake(fake);
  const el = doc.createElement('div');
  mounted.add(el);
  mount(h(App), el);
  await flush();
  return { el, calls, doc };
}

const tbodyRows = (root) => rowsOf(root).filter((tr) => tr.parentNode && tr.parentNode.localName === 'tbody');
const projectOf = (tr) => {
  const a = all(tr).find((n) => n.localName === 'a' && String(n.attrs.href || '').startsWith('/p/'));
  return a ? a.textContent.trim() : null;
};
const order = (root) => tbodyRows(root).map(projectOf);
const rowOf = (root, project) => tbodyRows(root).find((tr) => projectOf(tr) === project);
const headerOf = (root, label) => all(root).find((n) => n.localName === 'th'
  && all(n).some((b) => b.localName === 'button' && b.textContent.replace(/[↑↓]/g, '').trim() === label));
const linkTo = (root, href) => all(root).find((n) => n.localName === 'a' && n.attrs.href === href);
const text = (root) => root.textContent.replace(/\s+/g, ' ');

// ------------------------------------------------------------------ C1

test('C1 four rows, one per project; each PROJECT cell links to /p/<project>; the 7 headers', async () => {
  const rows = connectionRows(API);
  assert.deepEqual(rows.map((r) => r.project), ['alpha-linear', 'bravo-jira', 'charlie-board', 'delta-gh']);
  assert.deepEqual(rows.map((r) => r.adapter), ['linear', 'jira', 'board', 'github-issues']);
  assert.equal(rows[1].ok, false);
  assert.equal(rows[2].ok, null, 'never probed is unknown, not failed');
  assert.deepEqual(rows[1].missingVars, ['JIRA_API_TOKEN']);
  assert.equal(rows[0].route, 'example-org/cromford-sandbox-linear');
  assert.deepEqual(connectionRows(null), []);
  assert.deepEqual(connectionRows({ connections: [null, { adapter: 'linear' }] }), [], 'a row with no project is dropped');

  const { el, calls } = await mountScreen();
  assert.equal(calls.filter((c) => c.url === '/api/coord/connections').length, 1, 'ONE read');
  assert.deepEqual(order(el), PROJECTS);
  for (const p of PROJECTS) assert.ok(linkTo(el, `/p/${p}`), `${p} links to its project page`);
  const ths = all(el).filter((n) => n.localName === 'th').map((n) => n.textContent.replace(/[↑↓]/g, '').trim());
  assert.deepEqual(ths, ['PROJECT', 'TRACKER', 'CREDENTIAL', 'LAST PROBE', 'WEBHOOK', 'ROUTE', 'ACTIONS']);
  assert.match(text(rowOf(el, 'alpha-linear')), /linear/);
  assert.match(text(rowOf(el, 'charlie-board')), /board/);
  assert.match(text(rowOf(el, 'charlie-board')), /not probed/);
});

// ------------------------------------------------------------------ C2

test('C2 each of the 6 data columns sorts ascending then descending, with aria-sort', async () => {
  const { el } = await mountScreen();
  const want = {
    PROJECT: [PROJECTS, [...PROJECTS].reverse()],
    TRACKER: [['charlie-board', 'delta-gh', 'bravo-jira', 'alpha-linear'], ['alpha-linear', 'bravo-jira', 'delta-gh', 'charlie-board']],
    // 1 present < missing JIRA_API_TOKEN < none needed; never probed sinks both ways.
    CREDENTIAL: [['alpha-linear', 'bravo-jira', 'delta-gh', 'charlie-board'], ['delta-gh', 'bravo-jira', 'alpha-linear', 'charlie-board']],
    'LAST PROBE': [['bravo-jira', 'delta-gh', 'alpha-linear', 'charlie-board'], ['alpha-linear', 'delta-gh', 'bravo-jira', 'charlie-board']],
    // missing < present; a board without webhooks (n/a) sinks.
    WEBHOOK: [['bravo-jira', 'alpha-linear', 'charlie-board', 'delta-gh'], ['alpha-linear', 'bravo-jira', 'charlie-board', 'delta-gh']],
    ROUTE: [['bravo-jira', 'alpha-linear', 'charlie-board', 'delta-gh'], ['alpha-linear', 'bravo-jira', 'charlie-board', 'delta-gh']]
  };
  for (const [label, [asc, desc]] of Object.entries(want)) {
    const click = async () => {
      fire(all(headerOf(el, label)).find((n) => n.localName === 'button'), 'click');
      await flush();
    };
    await click();
    if (headerOf(el, label).attrs['aria-sort'] !== 'ascending') await click();
    assert.equal(headerOf(el, label).attrs['aria-sort'], 'ascending', `${label} asc`);
    assert.deepEqual(order(el), asc, `${label} ascending`);
    await click();
    assert.equal(headerOf(el, label).attrs['aria-sort'], 'descending', `${label} desc`);
    assert.deepEqual(order(el), desc, `${label} descending`);
  }
});

// ------------------------------------------------------------------ C3

test('C3 EDIT opens the in-app Modal with the form; Escape closes it; no OAuth control', async () => {
  const { el, doc } = await mountScreen();
  assert.equal(dialogOf(el), undefined);
  fire(buttonIn(rowOf(el, 'alpha-linear'), 'EDIT'), 'click');
  await flush();
  const dlg = dialogOf(el);
  assert.ok(dlg, 'a role=dialog opened (a native confirm would have thrown)');
  assert.match(dlg.attrs['aria-label'], /alpha-linear/);
  for (const name of ['adapter', 'team', 'label', 'states', 'webhook_route', 'reason']) {
    assert.ok(byName(dlg, name), `the linear form has ${name}`);
  }
  // preact sets value as an attribute on a node with no value property.
  const team = byName(dlg, 'team');
  assert.equal(team.value !== undefined ? team.value : team.attrs.value, 'CRO', 'the form starts from the stored row');
  assert.equal(byName(dlg, 'write_projects'), undefined, 'jira fields are not on a linear form');
  assert.doesNotMatch(text(dlg), /oauth|sign in with|authorize/i);
  // Switch to jira: its fields come in.
  const sel = byName(dlg, 'adapter');
  sel.value = 'jira';
  fire(sel, 'change');
  await flush();
  for (const name of ['write_projects', 'read_projects', 'comment_projects', 'status_map']) {
    assert.ok(byName(dialogOf(el), name), `the jira form has ${name}`);
  }
  fire(doc, 'keydown', { key: 'Escape' });
  await flush();
  assert.equal(dialogOf(el), undefined, 'Escape closed the dialog');
});

// ------------------------------------------------------------------ C4

test('C4a checkConnectionForm refuses every token-shaped value with the env var, never echoing it', () => {
  const base = { project: 'alpha-linear', adapter: 'linear', team: 'CRO', label: 'ai-build', reason: 'set up' };
  const refused = [
    ['label', 'sk-ant-api03-fixture0001', 'LINEAR_API_KEY'],
    ['team', 'lin_api_fixtureAbC123', 'LINEAR_API_KEY'],
    ['label', 'lin_oauth_fixture77', 'LINEAR_API_KEY'],
    ['reason', 'my key is ATATT3xFfGF0fixture', 'LINEAR_API_KEY'],
    ['webhook_route', 'ghp_fixture123', 'LINEAR_API_KEY'],
    ['label', 'github_pat_11Afixture', 'LINEAR_API_KEY'],
    ['label', 'gho_fixture', 'LINEAR_API_KEY'],
    ['label', 'ghs_fixture', 'LINEAR_API_KEY'],
    ['label', 'SK-1', 'LINEAR_API_KEY']
  ];
  for (const [field, value, envVar] of refused) {
    const r = checkConnectionForm({ ...base, [field]: value });
    assert.equal(r.ok, false, `${field}=${value} must be refused`);
    assert.equal(r.env_var, envVar, value);
    assert.match(r.message, new RegExp(`API keys are not stored here\\. Set ${envVar} in env/alpha-linear\\.env on the box that runs alpha-linear\\.`));
    assert.ok(r.errors[field], `the refusal sits on ${field}`);
    assert.ok(!JSON.stringify(r).includes(value), `the refusal never echoes ${value}`);
    assert.equal(r.body, undefined, 'a refused form has no body to send');
  }
  const jira = checkConnectionForm({ project: 'bravo-jira', adapter: 'jira', write_projects: 'ATATT3xFfGF0fixture', reason: 'x' });
  assert.equal(jira.env_var, 'JIRA_API_TOKEN');
  assert.equal(checkConnectionForm({ ...base, api_key: 'anything' }).ok, false, 'a body key api_key is refused');
  assert.equal(checkConnectionForm({ ...base, LINEAR_API_KEY: 'x' }).ok, false, 'a body key LINEAR_API_KEY is refused');
  assert.equal(envVarFor('board', { CRO_INTERNAL_API_TOKEN: 'present', CRO_API_BASE: 'present' }), 'CRO_INTERNAL_API_TOKEN');
  assert.equal(envVarFor('board', {}), 'INTERNAL_API_TOKEN', 'the worker\'s fallback name');
  assert.equal(checkConnectionForm({ ...base, adapter: 'github-issues', GH_TOKEN: 'x' }).env_var, 'GH_TOKEN', 'an env var key names itself');
  assert.match(checkConnectionForm({ ...base, adapter: '', label: 'ghp_fixture' }).message, /Set the tracker API key in env\/alpha-linear\.env/);
  assert.equal(isTokenShaped('ai-build'), false);
  assert.equal(isTokenShaped('review=In Review;done=ATATTfixture'), true, 'a token after a separator is caught');
  assert.equal(isTokenShaped('task-board'), false, 'sk- inside a word is not a token');
});

test('C4b the near misses pass; the shapes are checked; the body carries only this adapter\'s fields', () => {
  const ok = checkConnectionForm({
    project: 'alpha-linear', adapter: 'linear', team: 'SK', label: 'ai-build', states: '{"review":"In Review"}',
    webhook_route: 'example-org/cromford-sandbox-linear', reason: ' wire it ', write_projects: 'IGNORED'
  });
  assert.equal(ok.ok, true, JSON.stringify(ok));
  assert.deepEqual(ok.body, {
    project: 'alpha-linear', adapter: 'linear', team: 'SK', label: 'ai-build', states: '{"review":"In Review"}',
    webhook_route: 'example-org/cromford-sandbox-linear', reason: 'wire it'
  });
  const j = checkConnectionForm({
    project: 'bravo-jira', adapter: 'jira', write_projects: 'SKY SCRUM', read_projects: 'SKY', comment_projects: '',
    label: 'hotfix', status_map: 'review=In Review;done=Done', webhook_route: '', reason: 'x'
  });
  assert.equal(j.ok, true, JSON.stringify(j));
  assert.equal(j.body.comment_projects, '', 'an empty field is sent: the worker deletes that row');
  assert.equal(j.body.team, undefined);
  const bad = (d, field) => {
    const r = checkConnectionForm({ project: 'p', adapter: 'linear', reason: 'x', ...d });
    assert.equal(r.ok, false, JSON.stringify(d));
    assert.ok(r.errors[field], `${field}: ${JSON.stringify(r.errors)}`);
  };
  bad({ adapter: 'trello' }, 'adapter');
  bad({ team: 'cro' }, 'team');
  bad({ team: 'C'.repeat(11) }, 'team');
  bad({ label: 'has space' }, 'label');
  bad({ label: 'a\u0007b' }, 'label');
  bad({ states: '[1]' }, 'states');
  bad({ states: 'not json' }, 'states');
  bad({ webhook_route: 'no-slash' }, 'webhook_route');
  bad({ reason: '   ' }, 'reason');
  bad({ adapter: 'jira', write_projects: 'S' }, 'write_projects');
  bad({ adapter: 'jira', read_projects: 'sky' }, 'read_projects');
  bad({ adapter: 'jira', status_map: 'Review=In Review' }, 'status_map');
  bad({ adapter: 'jira', status_map: 'review=In=Review' }, 'status_map');
  assert.equal(credentialSummary(connectionRows(API)[0]), '1 present');
  assert.equal(credentialSummary(connectionRows(API)[1]), 'missing JIRA_API_TOKEN');
  assert.equal(credentialSummary(connectionRows(API)[2]), null);
  assert.equal(credentialSummary(connectionRows(API)[3]), 'none needed');
});

test('C4c the form shows the refusal with the env var, keeps confirm blocked, and a good save PUTs the body', async () => {
  const { el, calls } = await mountScreen();
  fire(buttonIn(rowOf(el, 'alpha-linear'), 'EDIT'), 'click');
  await flush();
  const confirm = () => buttonIn(dialogOf(el), 'SAVE');
  assert.ok(isDisabled(confirm()), 'blocked until a reason is typed');
  const typeIn = async (name, value) => {
    const f = byName(dialogOf(el), name);
    f.value = value;
    fire(f, 'input');
    await flush();
  };
  await typeIn('reason', 'route the sandbox');
  assert.ok(!isDisabled(confirm()), 'a valid form can be saved');
  await typeIn('label', 'lin_api_fixture123');
  assert.ok(isDisabled(confirm()), 'a token-shaped value blocks SAVE');
  assert.match(text(dialogOf(el)), /API keys are not stored here\. Set LINEAR_API_KEY in env\/alpha-linear\.env/);
  assert.ok(!text(dialogOf(el)).includes('lin_api_fixture123'), 'the refusal never echoes the value');
  fire(confirm(), 'click');
  await flush();
  assert.equal(calls.filter((c) => c.method === 'PUT').length, 0, 'a blocked SAVE sends nothing');
  await typeIn('label', 'hotfix');
  fire(confirm(), 'click');
  await flush();
  const puts = calls.filter((c) => c.method === 'PUT');
  assert.equal(puts.length, 1);
  assert.equal(puts[0].url, '/api/coord/connections');
  assert.equal(puts[0].body.project, 'alpha-linear');
  assert.equal(puts[0].body.adapter, 'linear');
  assert.equal(puts[0].body.label, 'hotfix');
  assert.equal(puts[0].body.team, 'CRO');
  assert.equal(puts[0].body.reason, 'route the sandbox');
  assert.equal(dialogOf(el), undefined, 'a saved form closes');
  assert.equal(calls.filter((c) => c.url === '/api/coord/connections' && c.method === 'GET').length, 2, 'the save re-reads');
});

test('C4d a worker refusal shows its error text in the modal, which stays open', async () => {
  const { el } = await mountScreen('', { put: [400, { error: 'API keys are not stored here. Set LINEAR_API_KEY in env/alpha-linear.env on the box that runs alpha-linear.', env_var: 'LINEAR_API_KEY' }] });
  fire(buttonIn(rowOf(el, 'alpha-linear'), 'EDIT'), 'click');
  await flush();
  const f = byName(dialogOf(el), 'reason');
  f.value = 'try';
  fire(f, 'input');
  await flush();
  fire(buttonIn(dialogOf(el), 'SAVE'), 'click');
  await flush();
  assert.ok(dialogOf(el), 'the dialog stays open');
  assert.match(text(dialogOf(el)), /not saved — API keys are not stored here\. Set LINEAR_API_KEY/);
});

test('C4f a worker 409 (a route row another project owns) shows its error text in the open modal', async () => {
  const msg = 'webhook_route.jira.scrum routes to acme/other, not this project\'s repo';
  const { el, calls } = await mountScreen('', { put: [409, { error: msg, key: 'webhook_route.jira.scrum', repo: 'acme/other' }] });
  fire(buttonIn(rowOf(el, 'bravo-jira'), 'EDIT'), 'click');
  await flush();
  const f = byName(dialogOf(el), 'reason');
  f.value = 'move the route';
  fire(f, 'input');
  await flush();
  fire(buttonIn(dialogOf(el), 'SAVE'), 'click');
  await flush();
  const dlg = dialogOf(el);
  assert.ok(dlg, 'the dialog stays open on a 409');
  const alertNode = all(dlg).find((n) => n.nodeType === 1 && n.attrs.role === 'alert');
  assert.ok(alertNode, 'the refusal is an alert line in the modal');
  assert.equal(alertNode.textContent.trim(), `not saved — ${msg}`);
  for (let p = alertNode; p; p = p.parentNode) {
    assert.ok(!('hidden' in (p.attrs || {})), 'not hidden');
    assert.ok(!/display:\s*none/.test(String(p.attrs && p.attrs.style)), 'not display:none');
  }
  const puts = calls.filter((c) => c.method === 'PUT');
  assert.equal(puts.length, 1);
  assert.equal(puts[0].body.route_override, undefined, 'the console never forces another project\'s route');
  assert.equal(calls.filter((c) => c.url === '/api/coord/connections' && c.method === 'GET').length, 1, 'no reload on a refusal');
});

test('C4e the coord write row: PUT connections forwards the listed string fields only, actor stamped', async () => {
  const rows = FRAGMENT_WRITES.filter((r) => r.method === 'PUT' && r.path === 'connections');
  assert.equal(rows.length, 1);
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const u = new URL(typeof input === 'string' ? input : input.url);
    if (u.pathname.startsWith('/api/dash/')) return new Response('{}', { status: 200 });
    seen.push({ path: u.pathname, method: init.method, body: init.body ? JSON.parse(init.body) : null });
    return new Response('{"ok":true}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  try {
    const body = {
      project: 'alpha-linear', adapter: 'linear', team: 'CRO', label: 7, api_key: 'tok-fixture-1', reason: 'r', actor: 'spoof'
    };
    const res = await coord({
      request: new Request('https://console.example.test/api/coord/connections', {
        method: 'PUT', headers: { cookie: 'dash=bh7924-fixture', 'content-type': 'application/json' }, body: JSON.stringify(body)
      }),
      env: { HARNESS_SECRET: 'harness-secret-fixture' },
      params: { path: ['connections'] }
    });
    assert.equal(res.status, 200);
    assert.equal(seen.length, 1);
    assert.equal(seen[0].path, '/api/connections');
    assert.equal(seen[0].method, 'PUT');
    assert.equal(seen[0].body.project, 'alpha-linear');
    assert.equal(seen[0].body.team, 'CRO');
    assert.equal(seen[0].body.label, undefined, 'a non-string value is not forwarded');
    assert.equal(seen[0].body.api_key, undefined, 'an unlisted key never travels');
    assert.notEqual(seen[0].body.actor, 'spoof', 'the actor is stamped by the proxy');
  } finally {
    globalThis.fetch = real;
  }
});

// ------------------------------------------------------------------ C5

test('C5a PROBE NOW sends the run_script command and says "probe queued" with a REFRESH', async () => {
  const { el, calls } = await mountScreen();
  fire(buttonIn(rowOf(el, 'bravo-jira'), 'PROBE NOW'), 'click');
  await flush();
  const sent = calls.filter((c) => c.url === '/api/dash/action');
  assert.equal(sent.length, 1);
  assert.deepEqual(sent[0].body, { type: 'run_script', project: 'bravo-jira', script: 'connection-probe.sh', args: ['bravo-jira'] });
  assert.match(text(el), new RegExp(`bravo-jira: ${PROBE_QUEUED}`));
  assert.equal(PROBE_QUEUED, 'probe queued; the row updates when the box answers');
  const reads = () => calls.filter((c) => c.url === '/api/coord/connections').length;
  assert.equal(reads(), 1);
  fire(buttonIn(el, 'REFRESH'), 'click');
  await flush();
  assert.equal(reads(), 2, 'REFRESH re-reads the list');
});

test('C5b "probe queued" shows only when the answer has command_id or ok', async () => {
  const a = await mountScreen('', { action: [200, { queued: 'maybe' }] });
  fire(buttonIn(rowOf(a.el, 'bravo-jira'), 'PROBE NOW'), 'click');
  await flush();
  assert.doesNotMatch(text(a.el), /probe queued/);
  assert.match(text(a.el), /bravo-jira: the probe was not confirmed/);
  for (const r of mounted) mount(null, r);
  mounted.clear();
  const b = await mountScreen('', { action: [400, { error: 'unknown action' }] });
  fire(buttonIn(rowOf(b.el, 'bravo-jira'), 'PROBE NOW'), 'click');
  await flush();
  assert.doesNotMatch(text(b.el), /probe queued/);
  assert.match(text(b.el), /bravo-jira: probe refused — unknown action/);
  assert.ok(!isDisabled(buttonIn(rowOf(b.el, 'bravo-jira'), 'PROBE NOW')), 'the button is usable again after a refusal');
});

test('C5c connectionProbeCommand accepts only connection-probe.sh with the project as its one arg', (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2026-10-27T18:04:59Z') });
  assert.ok(CONNECTION_PROBE_TYPES.has('run_script'));
  const cmd = connectionProbeCommand({ type: 'run_script', project: 'bravo-jira', script: 'connection-probe.sh', args: ['bravo-jira'], actor: 'console' });
  assert.equal(cmd.error, undefined);
  assert.equal(cmd.type, 'run_script');
  assert.equal(cmd.project, 'bravo-jira');
  assert.equal(cmd.ckey, 'bravo-jira:run_script:connection-probe:2026-10-27T18:04');
  assert.deepEqual(cmd.payload, { script: 'connection-probe.sh', args: ['bravo-jira'], actor: 'console' });
  const refused = [
    { script: 'security-audit-launch.sh', args: ['bravo-jira'] },
    { script: 'connection-probe.sh', args: ['--box'] },
    { script: 'connection-probe.sh', args: ['other'] },
    { script: 'connection-probe.sh', args: ['bravo-jira', 'x'] },
    { script: 'connection-probe.sh', args: [] },
    { script: 'connection-probe.sh' },
    { script: '../connection-probe.sh', args: ['bravo-jira'] },
    { type: 'run_triage', script: 'connection-probe.sh', args: ['bravo-jira'] },
    { project: 'a/b', script: 'connection-probe.sh', args: ['a/b'] }
  ];
  for (const over of refused) {
    const r = connectionProbeCommand({ type: 'run_script', project: 'bravo-jira', ...over });
    assert.equal(r.error, 'unknown action', JSON.stringify(over));
    assert.equal(r.ckey, undefined, JSON.stringify(over));
  }
});

// The real Pages onRequest over a SQLite commands table (the BH-7708 pattern).
function commandsDb() {
  const sqlite = new DatabaseSync(':memory:');
  sqlite.exec(`CREATE TABLE commands (
    id INTEGER PRIMARY KEY AUTOINCREMENT, ckey TEXT UNIQUE, type TEXT, project TEXT, payload TEXT,
    status TEXT DEFAULT 'pending', attempts INTEGER DEFAULT 0, lease_until TEXT, result TEXT,
    created_at TEXT, updated_at TEXT)`);
  const db = {
    prepare(sql) {
      const stmt = sqlite.prepare(sql);
      return {
        bind: (...args) => ({
          run: async () => ({ success: true, meta: { changes: Number(stmt.run(...args).changes) } }),
          first: async () => stmt.get(...args) || null,
          all: async () => ({ results: stmt.all(...args) })
        })
      };
    }
  };
  return { db, rows: () => sqlite.prepare('SELECT * FROM commands ORDER BY id').all() };
}

test('C5d the Pages fallback queues the probe on the worker\'s unknown action, and refuses another script', async (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2026-10-27T18:04:59Z') });
  t.mock.method(globalThis, 'fetch', async (url, init) => {
    if (new URL(String(url)).pathname === '/api/dash/fleet') {
      const good = new Headers(init && init.headers).get('cookie') === 'dash=good';
      return new Response('{}', { status: good ? 200 : 403 });
    }
    return new Response(JSON.stringify({ error: 'unknown action' }), { status: 400, headers: { 'content-type': 'application/json' } });
  });
  const w = commandsDb();
  const post = async (body, cookie = 'dash=good') => {
    const res = await dash({
      request: new Request('https://console.example/api/dash/action', {
        method: 'POST', headers: { 'content-type': 'application/json', cookie }, body: JSON.stringify(body)
      }),
      env: { CONSOLE_DB: w.db }
    });
    return { status: res.status, json: JSON.parse(await res.text()) };
  };
  const good = { type: 'run_script', project: 'bravo-jira', script: 'connection-probe.sh', args: ['bravo-jira'] };
  const r = await post(good);
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.ok, true);
  assert.equal(r.json.ckey, 'bravo-jira:run_script:connection-probe:2026-10-27T18:04');
  const rows = w.rows();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].type, 'run_script');
  assert.equal(rows[0].project, 'bravo-jira');
  assert.equal(r.json.command_id, rows[0].id);
  const p = JSON.parse(rows[0].payload);
  assert.equal(p.script, 'connection-probe.sh');
  assert.deepEqual(p.args, ['bravo-jira']);
  const other = await post({ ...good, script: 'security-audit-launch.sh' });
  assert.equal(other.status, 400);
  assert.deepEqual(other.json, { error: 'unknown action' });
  const noAuth = await post(good, 'dash=bad');
  assert.equal(noAuth.status, 403);
  assert.equal(w.rows().length, 1, 'only the one good probe was queued');
});

// ------------------------------------------------------------------ C6

test('C6 a failed row shows the error and the missing var names as visible text', async () => {
  const { el } = await mountScreen();
  const bravo = rowOf(el, 'bravo-jira');
  const errNode = all(bravo).find((n) => n.nodeType === 1 && n.attrs['data-testid'] === 'conn-error');
  assert.ok(errNode, 'the failed row has an error line');
  assert.match(errNode.textContent, /HTTP 401 Unauthorized from \/rest\/api\/3\/myself/);
  const varsNode = all(bravo).find((n) => n.nodeType === 1 && n.attrs['data-testid'] === 'conn-missing');
  assert.ok(varsNode, 'the failed row names the missing vars');
  assert.match(varsNode.textContent, /JIRA_API_TOKEN/);
  for (const node of [errNode, varsNode]) {
    for (let p = node; p; p = p.parentNode) {
      assert.ok(!('hidden' in (p.attrs || {})), 'not hidden');
      assert.ok(p.localName !== 'details' || 'open' in p.attrs, 'not inside a closed details');
      assert.ok(!/display:\s*none/.test(String(p.attrs && p.attrs.style)), 'not display:none');
    }
  }
  assert.match(text(bravo), /failed/);
  const alpha = rowOf(el, 'alpha-linear');
  assert.equal(all(alpha).find((n) => n.nodeType === 1 && n.attrs['data-testid'] === 'conn-error'), undefined, 'an ok row has no error line');
  assert.ok(all(alpha).some((n) => n.localName === 'span' && /\btag--green\b/.test(n.attrs.class || '') && n.textContent.trim() === 'ok'), 'the ok badge');
});

// ------------------------------------------------------------------ C7

test('C7 ?project=<p> highlights that row and only that row', async () => {
  const { el } = await mountScreen('?project=bravo-jira');
  const cls = (p) => String(rowOf(el, p).attrs.class || '');
  assert.match(cls('bravo-jira'), /\brow--hl\b/);
  for (const p of ['alpha-linear', 'charlie-board', 'delta-gh']) assert.doesNotMatch(cls(p), /row--hl/, p);
  for (const r of mounted) mount(null, r);
  mounted.clear();
  const none = await mountScreen('');
  for (const p of PROJECTS) assert.doesNotMatch(String(rowOf(none.el, p).attrs.class || ''), /row--hl/);
});

// ------------------------------------------------------------------ C8

test('C8 the table scrolls inside its own overflow-x:auto wrapper; no cards; no fixed page width', () => {
  const out = render(h(ConnectionsView, { data: API, error: null, loading: false, highlight: null }));
  assert.match(out, /<div class="tablewrap[^"]*">\s*<table class="tbl"/);
  const css = fs.readFileSync(new URL('../src/styles.css', import.meta.url), 'utf8');
  const rule = css.match(/\.tablewrap \{[^}]*\}/);
  assert.ok(rule, 'the .tablewrap rule exists');
  assert.match(rule[0], /overflow-x:\s*auto/);
  assert.match(rule[0], /max-width:\s*100%/);
  assert.doesNotMatch(out, /class="[^"]*\bcard\b/, 'a dense list, not a card wall');
  assert.doesNotMatch(out, /(?:^|[;"\s])(?:min-)?width:\s*(?:3[8-9]\d|[4-9]\d\d|\d{4,})px/, 'no element is pinned wider than 375px');
  assert.doesNotMatch(out, /white-space:\s*nowrap/, 'the error text wraps');
  // The load failure is told apart from an empty list.
  const failed = render(h(ConnectionsView, { data: null, error: new Error('worker 502'), loading: false }));
  assert.match(failed, /could not load — <b>worker 502<\/b>/);
  const empty = render(h(ConnectionsView, { data: { connections: [] }, error: null, loading: false }));
  assert.match(empty, /NO PROJECTS/);
  assert.doesNotMatch(empty, /could not load/);
});

// ------------------------------------------------------------------ C9

test('C9a the Settings menu row reaches the screen inside the shell', async () => {
  const item = findItem(SETTINGS_MENU, 'fleet', 'connections');
  assert.ok(item && !item.tag, 'a built fleet row');
  assert.equal(item.label, 'Tracker connections');
  assert.equal(SETTINGS_SCREENS.connections, ConnectionsScreen);
  const { el } = await mountApp('/settings/fleet/lanes');
  const row = linkTo(el, '/settings/fleet/connections');
  assert.ok(row, 'the Settings menu has the Tracker connections row');
  assert.equal(row.textContent.trim(), 'Tracker connections');
  fire(row, 'click');
  await flush();
  assert.equal(window.location.pathname, '/settings/fleet/connections');
  const cur = all(el).find((n) => n.attrs && n.attrs['aria-current'] === 'page');
  assert.equal(cur && cur.textContent.trim(), 'Tracker connections');
  assert.deepEqual(order(el), PROJECTS, 'the table renders in the shell');
});

test('C9b the Project page CONNECTION link opens /connections with that row highlighted', async () => {
  const { el } = await mountApp('/p/bravo-jira');
  const link = linkTo(el, '/connections?project=bravo-jira');
  assert.ok(link, 'the Project page links to its connection');
  assert.equal(link.textContent.trim(), 'CONNECTION');
  fire(link, 'click');
  await flush();
  assert.equal(window.location.pathname + window.location.search, '/connections?project=bravo-jira');
  assert.deepEqual(order(el), PROJECTS);
  assert.match(String(rowOf(el, 'bravo-jira').attrs.class || ''), /\brow--hl\b/);
});

// ------------------------------------------------------------------ C10

// The LAST PROBE age span of a row: <span title=checkedAt><Age/></span>.
const ageOf = (tr, checkedAt) => {
  const wrap = all(tr).find((n) => n.nodeType === 1 && n.attrs.title === checkedAt);
  return wrap && all(wrap).find((n) => n !== wrap && n.localName === 'span');
};
// preact writes a string style to el.style.cssText; the SSR path uses the attr.
const hot = (span) => /var\(--amber\)/.test(`${span.attrs.style || ''} ${(span.style && span.style.cssText) || ''}`);

test('C10 probeStaleMin type-checks the knob answer; the fallback is the seed 120', () => {
  assert.equal(PROBE_STALE_KEY, 'connections.probe_stale_min');
  assert.equal(PROBE_STALE_MIN, 120);
  const seed = fs.readdirSync(new URL('../../worker/jobs/schema.d/', import.meta.url))
    .filter((f) => /bh-8674-connection-probe-stale\.sql$/.test(f));
  assert.equal(seed.length, 1, 'one seed fragment');
  const sql = fs.readFileSync(new URL(`../../worker/jobs/schema.d/${seed[0]}`, import.meta.url), 'utf8');
  assert.match(sql, /INSERT OR IGNORE INTO settings[^;]*'connections\.probe_stale_min',\s*'120'/, 'the seed equals the fallback');
  // The worker's GET /api/connections range read is key >= 'connection.' AND
  // key < 'connection/'. The console knob stays outside it, so that read and
  // its pinned row set (worker W5, W8) do not change.
  assert.ok(!(PROBE_STALE_KEY >= 'connection.' && PROBE_STALE_KEY < 'connection/'), 'outside the worker range read');
  const row = (value) => ({ key: PROBE_STALE_KEY, setting: { key: PROBE_STALE_KEY, value }, source: 'db' });
  for (const bad of [null, undefined, {}, { setting: null }, row(''), row('abc'), row('0'), row('-5'), row(null), row('  '), row('Infinity'), 'x']) {
    assert.equal(probeStaleMin(bad), 120, JSON.stringify(bad));
  }
  assert.equal(probeStaleMin(row('45')), 45);
  assert.equal(probeStaleMin(row('120')), 120);
  assert.equal(probeStaleMin(row('1')), 1, 'the edge');
  assert.equal(probeStaleMin(row(30)), 30, 'a number value is read too');
});

test('C10b the LAST PROBE cell is stale by the knob, read in parallel with the list', async (t) => {
  // bravo-jira was probed at 15:00Z; the clock says 16:30Z, so 90 minutes.
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2026-10-27T16:30:00Z') });
  const checked = '2026-10-27T15:00:00Z';
  const view = (staleMin) => {
    const doc = installDom();
    const el = doc.createElement('div');
    mounted.add(el);
    mount(h(ConnectionsView, { data: API, error: null, loading: false, highlight: null, staleMin }), el);
    return ageOf(rowOf(el, 'bravo-jira'), checked);
  };
  assert.equal(hot(view(60)), true, '90 min is stale with the knob at 60');
  assert.equal(hot(view(120)), false, '90 min is fresh with the knob at 120');
  assert.equal(hot(view(undefined)), false, 'no knob prop is the fallback 120');

  for (const r of mounted) mount(null, r);
  mounted.clear();
  const knob60 = await mountScreen('', { setting: [200, { key: PROBE_STALE_KEY, setting: { value: '60' }, source: 'db' }] });
  const knobUrl = `/api/coord/settings/${encodeURIComponent(PROBE_STALE_KEY)}`;
  assert.equal(knob60.calls.filter((c) => c.url === knobUrl).length, 1, 'one knob read');
  const first = knob60.calls.findIndex((c) => c.url === knobUrl || c.url === '/api/coord/connections');
  const both = knob60.calls.slice(first, first + 2).map((c) => c.url).sort();
  assert.deepEqual(both, ['/api/coord/connections', knobUrl].sort(), 'the two reads start together');
  assert.equal(hot(ageOf(rowOf(knob60.el, 'bravo-jira'), checked)), true, 'the screen reads the knob');

  for (const r of mounted) mount(null, r);
  mounted.clear();
  const broken = await mountScreen('', { setting: [500, { error: 'settings down' }] });
  assert.deepEqual(order(broken.el), PROJECTS, 'a failed knob read does not block the table');
  assert.equal(hot(ageOf(rowOf(broken.el, 'bravo-jira'), checked)), false, 'a failed knob read is the fallback 120');
});

// ------------------------------------------------------------------ C11

const NO_GO = /oauth|sign in with|connect with|billing|\bplans?\b|upgrade|\bpay/i;
const controlTexts = (root) => all(root)
  .filter((n) => n.nodeType === 1 && ['button', 'a', 'option', 'label', 'input', 'select'].includes(n.localName))
  .map((n) => [n.textContent, n.attrs['aria-label'], n.attrs.placeholder, n.attrs.name, n.attrs.href]
    .filter(Boolean).join(' '));

test('C11 no OAuth control and no billing surface; the form sends only the coord write row fields', async () => {
  const { el } = await mountScreen();
  for (const s of controlTexts(el)) assert.doesNotMatch(s, NO_GO, `page control: ${s}`);
  assert.doesNotMatch(text(el), NO_GO, 'page text');
  for (const project of ['alpha-linear', 'bravo-jira']) {
    fire(buttonIn(rowOf(el, project), 'EDIT'), 'click');
    await flush();
    const dlg = dialogOf(el);
    assert.ok(dlg);
    for (const s of controlTexts(dlg)) assert.doesNotMatch(s, NO_GO, `${project} modal control: ${s}`);
    assert.doesNotMatch(text(dlg), NO_GO, `${project} modal text`);
    fire(buttonIn(dlg, 'CANCEL') || dlg, 'click');
    await flush();
  }
  const allowed = new Set(FRAGMENT_WRITES.find((r) => r.method === 'PUT' && r.path === 'connections').body);
  for (const row of connectionRows(API)) {
    for (const adapter of ['linear', 'jira', 'board', 'github-issues', '']) {
      const c = checkConnectionForm({ ...draftFor(row), adapter, reason: 'r' }, row.credentialVars);
      if (!c.ok) continue;
      for (const k of Object.keys(c.body)) assert.ok(allowed.has(k), `${row.project}/${adapter} sends ${k}`);
    }
  }
});
