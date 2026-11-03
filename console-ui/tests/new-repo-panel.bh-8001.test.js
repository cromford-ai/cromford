// BH-8001 (BH-7935.4): the New repo panel of /projects/new.
//   N1  Create repo opens the in-app [role=dialog]; window.confirm is never called
//   N2  Cancel sends no POST and closes the dialog
//   N3  the selected template's row is false -> Create disabled + "no template repo set";
//       a true row enables it; a bad owner/name disables it; loading shows a .skel line;
//       an unreadable templates answer shows "could not read the templates" + Retry
//   N4  Confirm -> one keyed POST {owner,name,template}; a second Create while in flight
//       sends nothing; the poll goes pending -> ok -> onCreated('o/n') once
//   N5  state error -> role=alert with the error, the next Create uses a new key;
//       a failed POST shows role=alert and a retry of the same form reuses the key;
//       an answer with no probe_id is an error
//   N6  pending past max -> "Check again" polls the same id; absent knob rows use
//       5000 ms / 900 s; unmount stops the poll
//   N7  the coord row: POST onboarding/repo-create, idempotencyKey, body fields exactly
//       owner, name, template; the proxy refuses a missing key with 400, 0 upstream fetches
//   N8  the schema fragment seeds the five keys with INSERT OR IGNORE
//   N9  the real OnboardScreen: New repo -> owner + name -> Create repo -> confirm -> ok ->
//       #onboard-slug holds o/n and Existing repo is selected
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';
import { waitFor } from './helpers/wait-for.js';
import { installDom, all, fire, isDisabled, dialogOf, confirmOf, buttonIn, type } from './helpers/fake-dom.bh-5750.js';

installDom();
const { NewRepoPanel } = await import('../src/screens/onboard/NewRepoPanel.js');
const { OnboardScreen } = await import('../src/screens/Onboard.js');
const { onRequest, ROUTES: COORD_ROUTES } = await import('../functions/api/coord/[[path]].js');

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const PROBE = 'a1b2c3d4e5f60718';
const PROBE_2 = '0f1e2d3c4b5a6978';
const tick = () => new Promise((r) => setTimeout(r, 0));
const FAST = { 'onboarding.create_poll_ms': '1', 'onboarding.create_poll_max_s': '900' };
const ALL_ON = { nextjs: true, worker: true, empty: true };

// A fetch that answers by path and keeps every call. Each answer is
// [status, body]; `templates` may return a promise to hold the read open.
function panelFetch({ settings = FAST, templates = () => [200, { templates: ALL_ON }], create, state, detect } = {}) {
  const calls = [];
  let nCreate = 0;
  let nState = 0;
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    const method = init.method || 'GET';
    calls.push({ url: u, method, headers: init.headers || {}, body: init.body });
    let status = 200;
    let body = {};
    const set = /^\/api\/coord\/settings\/(.+)$/.exec(u);
    if (set) {
      const key = decodeURIComponent(set[1]);
      body = { setting: key in settings ? { key, value: settings[key] } : null };
    } else if (u === '/api/coord/onboarding/repo-create/templates') [status, body] = await templates();
    else if (u === '/api/coord/onboarding/repo-create' && method === 'POST') {
      await tick();
      nCreate += 1;
      [status, body] = create ? create(nCreate) : [202, { probe_id: PROBE }];
    } else if (u.startsWith('/api/coord/onboarding/repo-create/')) {
      nState += 1;
      [status, body] = await (state ? state(nState, u) : [200, { state: 'ok', slug: 'o/n', error: null }]);
    } else if (u === '/api/coord/onboarding/repos') body = { state: 'ok', repos: [] };
    else if (u.startsWith('/api/coord/onboarding/repo?')) body = detect ? detect(u) : { state: 'pending' };
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) };
  };
  return calls;
}

const mounted = new Set();
test.afterEach(() => { for (const root of mounted) mount(null, root); mounted.clear(); });
async function mountNode(node) {
  const doc = installDom();
  const root = doc.createElement('div');
  doc.appendChild(root);
  mount(node, root);
  mounted.add(root);
  await flush();
  return root;
}
const panel = (props = {}) => h(NewRepoPanel, { owner: 'o', name: 'n', template: 'nextjs', onCreated: () => {}, ...props });

// toBeVisible for the fake DOM: in the tree under root, and neither the node
// nor an ancestor is hidden.
function visible(root, n) {
  if (!n) return false;
  for (let p = n; p; p = p.parentNode) {
    if (p.attrs && ('hidden' in p.attrs || p.attrs['aria-hidden'] === 'true')) return false;
    if (p.style && p.style.display === 'none') return false;
    if (p === root) return true;
  }
  return false;
}
const createBtn = (root) => buttonIn(root, 'Create repo');
const byRole = (root, role) => all(root).find((n) => n.attrs && n.attrs.role === role);
const withText = (root, re) => all(root).filter((n) => n.nodeType === 1 && re.test(n.textContent))
  .find((n) => !n.childNodes.some((c) => c.nodeType === 1 && re.test(c.textContent)));
const posts = (calls) => calls.filter((c) => c.method === 'POST');
const stateGets = (calls) => calls.filter((c) => c.method === 'GET' && /^\/api\/coord\/onboarding\/repo-create\/[0-9a-f]{16}$/.test(c.url));
const keyOf = (c) => c.headers['Idempotency-Key'];

async function confirmCreate(root) {
  fire(createBtn(root), 'click');
  await flush();
  const dialog = dialogOf(root);
  assert.ok(visible(root, dialog), 'the confirm dialog is visible');
  fire(confirmOf(dialog), 'click');
  await flush();
}

// ── N1 ────────────────────────────────────────────────────────────────────
test('N1 Create repo opens the in-app dialog; window.confirm is never called', async () => {
  panelFetch();
  const root = await mountNode(panel());
  let nativeCalls = 0;
  globalThis.window.confirm = () => { nativeCalls += 1; throw new Error('native confirm'); };
  globalThis.confirm = globalThis.window.confirm;
  assert.equal(dialogOf(root), undefined, 'no dialog before the click');
  assert.ok(visible(root, createBtn(root)), 'the Create repo button is visible');
  assert.equal(isDisabled(createBtn(root)), false);
  fire(createBtn(root), 'click');
  await flush();
  const dialog = dialogOf(root);
  assert.ok(visible(root, dialog), 'a [role=dialog] is visible');
  assert.match(dialog.textContent, /Create o\/n\?/);
  assert.match(dialog.textContent, /This makes a new private GitHub repo from the nextjs template\. The console cannot delete it\./);
  assert.equal(confirmOf(dialog).textContent.trim(), 'CREATE REPO');
  assert.equal(nativeCalls, 0, 'window.confirm is never called');
});

// ── N2 ────────────────────────────────────────────────────────────────────
test('N2 Cancel sends no POST and closes the dialog', async () => {
  const calls = panelFetch();
  const root = await mountNode(panel());
  fire(createBtn(root), 'click');
  await flush();
  fire(buttonIn(dialogOf(root), 'CANCEL'), 'click');
  await waitFor(() => dialogOf(root) === undefined, 'the dialog closes');
  await flush();
  assert.equal(dialogOf(root), undefined, 'the dialog is closed');
  assert.equal(posts(calls).length, 0, 'Cancel sends nothing');
  assert.equal(stateGets(calls).length, 0, 'and polls nothing');
  assert.equal(isDisabled(createBtn(root)), false, 'Create repo is enabled again');
});

// ── N3 ────────────────────────────────────────────────────────────────────
test('N3 a false template row disables Create with "no template repo set"; loading, unreadable and bad input', async () => {
  let calls = panelFetch({ templates: () => [200, { templates: { nextjs: true, worker: false, empty: false } }] });
  let root = await mountNode(panel({ template: 'worker' }));
  assert.equal(isDisabled(createBtn(root)), true, 'worker has no row: disabled');
  assert.ok(visible(root, withText(root, /no template repo set/)), '"no template repo set" is visible');
  mount(panel({ template: 'nextjs' }), root);
  await flush();
  assert.equal(isDisabled(createBtn(root)), false, 'nextjs has a row: enabled');
  assert.equal(withText(root, /no template repo set/), undefined, 'the note is gone');
  for (const [owner, name] of [['o', 'bad name'], ['', 'n'], ['o', '..'], ['o', 'n.git'], ['https://github.com', 'n']]) {
    mount(panel({ owner, name }), root);
    await flush();
    assert.equal(isDisabled(createBtn(root)), true, `disabled for ${owner}/${name}`);
  }
  fire(createBtn(root), 'click');
  await flush();
  assert.equal(dialogOf(root), undefined, 'a click on a disabled form opens nothing');
  assert.equal(posts(calls).length, 0);
  mount(null, root);

  // Loading: the read is held open -> a .skel line and Create disabled.
  let release;
  panelFetch({ templates: () => new Promise((r) => { release = r; }) });
  root = await mountNode(panel());
  const skel = all(root).find((n) => (n.attrs?.class || '').split(/\s+/).includes('skel'));
  assert.ok(visible(root, skel), 'a .skel line while the templates load');
  assert.equal(isDisabled(createBtn(root)), true, 'disabled while loading');
  release([200, { templates: ALL_ON }]);
  await flush();
  assert.equal(isDisabled(createBtn(root)), false, 'enabled once the read answers');
  mount(null, root);

  // Unreadable: a 500 -> the text and a Retry that reads again.
  let n = 0;
  calls = panelFetch({ templates: () => { n += 1; return n === 1 ? [500, { error: 'boom' }] : [200, { templates: ALL_ON }]; } });
  root = await mountNode(panel());
  assert.ok(visible(root, withText(root, /could not read the templates/)), '"could not read the templates" is visible');
  assert.equal(isDisabled(createBtn(root)), true, 'disabled when unreadable');
  assert.equal(withText(root, /no template repo set/), undefined, 'unreadable is not "no row"');
  fire(buttonIn(root, 'Retry'), 'click');
  await flush();
  assert.equal(calls.filter((c) => c.url === '/api/coord/onboarding/repo-create/templates').length, 2, 'Retry reads again');
  assert.equal(isDisabled(createBtn(root)), false, 'enabled after a good Retry');
});

// ── N4 ────────────────────────────────────────────────────────────────────
test('N4 Confirm sends one keyed POST; a Create while in flight sends nothing; pending -> ok -> onCreated once', async () => {
  const created = [];
  let gate;
  const calls = panelFetch({
    state: (i) => (i === 1 ? [200, { state: 'pending', slug: null, error: null, note: 'claimed by the hub' }]
      : i === 2 ? new Promise((r) => { gate = r; }).then(() => [200, { state: 'ok', slug: 'o/n', error: null }])
        : [200, { state: 'ok', slug: 'o/n', error: null }])
  });
  const root = await mountNode(panel({ onCreated: (s) => created.push(s) }));
  fire(createBtn(root), 'click');
  await flush();
  const dialog = dialogOf(root);
  fire(confirmOf(dialog), 'click');
  fire(confirmOf(dialog), 'click');
  await tick();
  // A second Create while the POST is in flight: the click is ignored.
  fire(createBtn(root), 'click');
  await flush();
  if (dialogOf(root)) fire(confirmOf(dialogOf(root)), 'click');
  await waitFor(() => stateGets(calls).length >= 2, 'the second state poll');
  await flush();
  const p = posts(calls);
  assert.equal(p.length, 1, 'exactly one POST');
  assert.equal(p[0].url, '/api/coord/onboarding/repo-create');
  assert.match(keyOf(p[0]), UUID_RE, 'an Idempotency-Key header');
  const sent = JSON.parse(p[0].body);
  assert.deepEqual(Object.keys(sent).sort(), ['name', 'owner', 'template']);
  assert.equal(sent.owner, 'o');
  assert.equal(sent.name, 'n');
  assert.equal(sent.template, 'nextjs');
  assert.equal(stateGets(calls)[0].url, `/api/coord/onboarding/repo-create/${PROBE}`, 'the poll reads the probe id');
  const status = byRole(root, 'status');
  assert.equal(status.attrs['aria-live'], 'polite');
  assert.match(status.textContent, /claimed by the hub/, 'the pending note shows');
  assert.equal(isDisabled(createBtn(root)), true, 'Create is disabled while pending');
  assert.deepEqual(created, [], 'no onCreated while pending');
  gate();
  await waitFor(() => created.length > 0, 'onCreated');
  await flush(5); // fixed-wait: ok an observation window for "no second onCreated and no poll after ok", not a render barrier
  assert.deepEqual(created, ['o/n'], 'onCreated once with the slug');
  assert.equal(stateGets(calls).length, 2, 'the poll stops at ok');
  assert.ok(visible(root, byRole(root, 'status')));
  assert.equal(byRole(root, 'status').textContent.trim(), 'Created o/n.');
  assert.equal(byRole(root, 'alert'), undefined);
});

// ── N5 ────────────────────────────────────────────────────────────────────
test('N5 a state error shows role=alert and the next Create uses a new key', async () => {
  const calls = panelFetch({
    create: (i) => [202, { probe_id: i === 1 ? PROBE : PROBE_2 }],
    state: (i) => (i === 1 ? [200, { state: 'error', slug: null, error: 'name already exists' }] : [200, { state: 'pending', slug: null, error: null }])
  });
  const created = [];
  const root = await mountNode(panel({ onCreated: (s) => created.push(s) }));
  await confirmCreate(root);
  await waitFor(() => Boolean(byRole(root, 'alert')), 'the error alert');
  await flush();
  const alert = byRole(root, 'alert');
  assert.ok(visible(root, alert), 'role=alert is visible');
  assert.match(alert.textContent, /name already exists/);
  assert.equal(isDisabled(createBtn(root)), false, 'Create is enabled again');
  assert.deepEqual(created, []);
  await confirmCreate(root);
  await waitFor(() => stateGets(calls).length >= 2, 'the second poll');
  const p = posts(calls);
  assert.equal(p.length, 2);
  assert.match(keyOf(p[1]), UUID_RE);
  assert.notEqual(keyOf(p[1]), keyOf(p[0]), 'a terminal error drops the key');
  assert.equal(stateGets(calls)[1].url, `/api/coord/onboarding/repo-create/${PROBE_2}`);
});

test('N5b a failed POST shows role=alert and a retry of the same form reuses the key; no probe_id is an error', async () => {
  let calls = panelFetch({ create: (i) => (i === 1 ? [503, { error: 'jobs_unavailable' }] : [202, { probe_id: PROBE }]) });
  let root = await mountNode(panel());
  await confirmCreate(root);
  await waitFor(() => Boolean(byRole(root, 'alert')), 'the POST error');
  assert.match(byRole(root, 'alert').textContent, /jobs_unavailable/);
  assert.equal(isDisabled(createBtn(root)), false);
  await confirmCreate(root);
  await waitFor(() => stateGets(calls).length >= 1, 'the poll after the retry');
  let p = posts(calls);
  assert.equal(p.length, 2);
  assert.equal(keyOf(p[1]), keyOf(p[0]), 'the same form state sends the same key');
  mount(null, root);

  calls = panelFetch({ create: (i) => (i === 1 ? [503, { error: 'jobs_unavailable' }] : [202, { probe_id: PROBE }]) });
  root = await mountNode(panel());
  await confirmCreate(root);
  await waitFor(() => Boolean(byRole(root, 'alert')), 'the POST error');
  mount(panel({ name: 'n2' }), root);
  await flush();
  await confirmCreate(root);
  await waitFor(() => posts(calls).length === 2, 'the second POST');
  p = posts(calls);
  assert.notEqual(keyOf(p[1]), keyOf(p[0]), 'another form state gets another key');
  assert.equal(JSON.parse(p[1].body).name, 'n2');
  mount(null, root);

  calls = panelFetch({ create: () => [202, {}] });
  root = await mountNode(panel());
  await confirmCreate(root);
  await waitFor(() => Boolean(byRole(root, 'alert')), 'the no-id error');
  assert.match(byRole(root, 'alert').textContent, /no probe id/);
  assert.equal(stateGets(calls).length, 0, 'nothing to poll');
  assert.equal(isDisabled(createBtn(root)), false);
});

// ── N6 ────────────────────────────────────────────────────────────────────
test('N6 pending past max shows Check again, which polls the same id; unmount stops the poll', async () => {
  const calls = panelFetch({
    settings: { 'onboarding.create_poll_ms': '1', 'onboarding.create_poll_max_s': '1' },
    state: () => [200, { state: 'pending', slug: null, error: null }]
  });
  const root = await mountNode(panel());
  await confirmCreate(root);
  await waitFor(() => Boolean(buttonIn(root, 'Check again')), 'Check again', () => '', 1000);
  await flush();
  assert.ok(visible(root, buttonIn(root, 'Check again')), 'Check again is visible');
  assert.match(byRole(root, 'status').textContent, /The hub has not answered yet\. It checks every 10 minutes\./);
  const before = stateGets(calls).length;
  await flush(20); // fixed-wait: ok an observation window for "no poll after the max" at poll_ms 1, not a render barrier
  assert.equal(stateGets(calls).length, before, 'no poll after the max');
  fire(buttonIn(root, 'Check again'), 'click');
  await waitFor(() => stateGets(calls).length > before, 'a poll after Check again');
  assert.equal(stateGets(calls).at(-1).url, `/api/coord/onboarding/repo-create/${PROBE}`, 'the same id');
  assert.equal(posts(calls).length, 1, 'Check again files no new POST');
  mount(null, root);
  mounted.delete(root);
  const atUnmount = stateGets(calls).length;
  await flush(30); // fixed-wait: ok an observation window for "unmount stops the poll" at poll_ms 1, not a render barrier
  assert.equal(stateGets(calls).length, atUnmount, 'unmount stops the poll');
});

test('N6b absent knob rows: the poll waits 5000 ms and gives up at 900 s', async () => {
  const calls = panelFetch({ settings: {}, state: () => [200, { state: 'pending', slug: null, error: null }] });
  const realTimeout = globalThis.setTimeout;
  const realNow = Date.now;
  const delays = [];
  let offset = 0;
  // A 5000 ms timer runs at once and moves the clock 300 s; every other timer is real.
  globalThis.setTimeout = (fn, ms, ...a) => {
    if (ms === 5000) { delays.push(ms); return realTimeout(() => { offset += 300000; fn(...a); }, 0); }
    return realTimeout(fn, ms, ...a);
  };
  Date.now = () => realNow() + offset;
  try {
    const root = await mountNode(panel());
    await confirmCreate(root);
    await waitFor(() => Boolean(buttonIn(root, 'Check again')), 'Check again');
    await flush();
    assert.ok(delays.length >= 1, 'the fallback interval is 5000 ms');
    // 300 s per poll: pending at 300 and 600, the max reached at 900.
    assert.equal(stateGets(calls).length, 3, 'the fallback max is 900 s');
  } finally {
    globalThis.setTimeout = realTimeout;
    Date.now = realNow;
  }
});

// ── N7 ────────────────────────────────────────────────────────────────────
const CONSOLE = 'https://harness-console.operator.workers.dev';
function proxyFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, headers: init.headers || {}, body: init.body });
    return new Response(JSON.stringify({ probe_id: PROBE }), { status: 202, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}
let cookieSeq = 0;
const proxy = (body, key) => onRequest({
  request: new Request('https://console.example.test/api/coord/onboarding/repo-create', {
    method: 'POST',
    headers: { cookie: `dash=bh8001-${++cookieSeq}`, 'content-type': 'application/json', ...(key === undefined ? {} : { 'Idempotency-Key': key }) },
    body: JSON.stringify(body)
  }),
  env: { HARNESS_SECRET: 'harness-secret-fixture' },
  params: { path: ['onboarding', 'repo-create'] }
});

test('N7 the coord row for POST onboarding/repo-create forwards the key; a missing key is 400 with 0 upstream fetches', async () => {
  const frag = (await import('../functions/_lib/coord-writes.d/8001-onboarding-repo-create.js')).default;
  const rows = COORD_ROUTES.filter((r) => r.method === 'POST' && r.path === 'onboarding/repo-create');
  assert.equal(rows.length, 1, 'one row');
  assert.equal(rows[0], frag[0], 'from this fragment');
  assert.equal(rows[0].idempotencyKey, true);
  assert.deepEqual([...rows[0].body].sort(), ['name', 'owner', 'template']);
  const f = proxyFetch();
  try {
    const key = crypto.randomUUID();
    const res = await proxy({ owner: 'o', name: 'n', template: 'nextjs', token: 'tok-fixture-1' }, key);
    assert.equal(res.status, 202);
    assert.equal(f.seen.length, 1);
    assert.match(f.seen[0].url, /\/api\/onboarding\/repo-create$/);
    assert.equal(f.seen[0].headers['idempotency-key'], key);
    const sent = JSON.parse(f.seen[0].body);
    assert.equal(sent.owner, 'o');
    assert.equal(sent.name, 'n');
    assert.equal(sent.template, 'nextjs');
    assert.equal('token' in sent, false, 'a field off the row is dropped');
    for (const k of [undefined, '', 'abc']) {
      const r = await proxy({ owner: 'o', name: 'n', template: 'nextjs' }, k);
      assert.equal(r.status, 400, `refuses ${JSON.stringify(k)}`);
      assert.equal((await r.json()).error, 'idempotency_key_required');
    }
    assert.equal(f.seen.length, 1, '0 upstream fetches for a refused key');
  } finally { f.restore(); }
});

// ── N8 ────────────────────────────────────────────────────────────────────
test('N8 the schema fragment seeds the five keys with INSERT OR IGNORE', () => {
  const dir = new URL('../../worker/jobs/schema.d/', import.meta.url);
  const files = readdirSync(dir).filter((f) => f.endsWith('-bh-8001-onboarding-templates.sql'));
  assert.equal(files.length, 1, 'one BH-8001 settings fragment');
  const sql = readFileSync(new URL(files[0], dir), 'utf8');
  const stmts = sql.split('\n').filter((l) => !l.startsWith('--')).join('\n').split(/;\s*$/m).map((s) => s.trim()).filter(Boolean);
  const rows = {};
  for (const s of stmts) {
    assert.match(s, /^INSERT OR IGNORE INTO settings/, 'every statement is INSERT OR IGNORE');
    for (const m of s.matchAll(/\('([a-z_.]+)','([^']*)'/g)) rows[m[1]] = m[2];
  }
  for (const t of ['nextjs', 'worker', 'empty']) assert.ok(['', '-'].includes(rows[`onboarding.template.${t}`]), `template ${t} seeds off`);
  assert.equal(rows['onboarding.create_poll_ms'], '5000');
  assert.equal(rows['onboarding.create_poll_max_s'], '900');
  assert.doesNotMatch(sql, /CREATE TABLE/i);
});

// ── N9 ────────────────────────────────────────────────────────────────────
test('N9 the real OnboardScreen: New repo -> owner + name -> Create repo -> confirm -> ok fills #onboard-slug', async () => {
  globalThis.window.history.pushState = () => {};
  const calls = panelFetch({ settings: { ...FAST, 'onboarding.detect_poll_ms': '1', 'onboarding.detect_poll_max_s': '120' } });
  const root = await mountNode(h(OnboardScreen));
  const radio = (v) => all(root).find((n) => n.attrs && n.attrs.role === 'radio' && n.attrs['data-value'] === v);
  const byId = (id) => all(root).find((n) => n.attrs && n.attrs.id === id);
  fire(radio('new'), 'click');
  await flush();
  type(byId('onboard-new-owner'), 'o');
  await flush();
  type(byId('onboard-new-name'), 'n');
  await flush();
  assert.ok(visible(root, createBtn(root)), 'Create repo is visible on the New repo segment');
  await confirmCreate(root);
  await waitFor(() => Boolean(byId('onboard-slug')), 'the Existing repo segment');
  await flush();
  assert.equal(posts(calls).length, 1);
  assert.equal(JSON.parse(posts(calls)[0].body).template, 'nextjs');
  assert.equal(byId('onboard-slug').attrs.value, 'o/n', '#onboard-slug holds the created slug');
  assert.equal(radio('existing').attrs['aria-checked'], 'true', 'Existing repo is selected');
});
