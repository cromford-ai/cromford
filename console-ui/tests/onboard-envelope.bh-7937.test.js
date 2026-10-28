// BH-7968 (BH-7937.4): the tracker sheets seal their fields to the hub key and
// send them only as a secret envelope. The REAL TrackerSheet is mounted on a
// small fake DOM; the test types into its inputs and clicks Test and connect.
// Every request goes through a recording fetch that plays the coord proxy:
// settings, the envelope store, the test start and the poll. The hub key pair
// is made here with WebCrypto (RSA-4096), so the test can open what was sent.
//   S1 Linear: exactly one POST to /secrets/envelope, scope tracker:linear:newproj
//   S2 its ciphertext is 684 base64 chars, holds no key text, and opens to {"fields":{...}}
//   S3 the same for Jira and the app board
//   S4 no request to a KV route; the test start body is {project, kind, envelope_id}; no body holds the key
//   S5 a blank hub key: a visible error, no envelope POST and no test POST
//   S6 an envelope POST that answers 400: the worker's error shows, no test POST
//   S7 a plaintext over 446 bytes: the "too long" error, nothing posted
//   S8 a field the hub refuses (a private board host) shows at once; nothing posted
//   T1 checkTrackerFields: the BH-7936 refusal table, moved from the worker
// And the onboarding form's Step 2 "AI account" line (the REAL OnboardScreen,
// entered as an operator does: slug, Continue, the review):
//   O1 the line holds a visible Change button; a click opens the visible dialog
//      "AI account for <project>"
//   O2 USE THE FLEET POOL + confirm: one PUT account.<project> = shared; the
//      sheet closes; the line reads fleet pool
//   O3 an existing account + confirm: the line reads its label; the run POST has no ai_envelope
//   O4 cancel in the confirm, or CLOSE: no PUT; the line still reads fleet pool
//   O5 the project's own account (the real add sheet seals and saves): the
//      line reads the new label; the run POST carries ai_envelope = its envelope id
//   O6 after O5, Back, a new project name, Continue: the line reads fleet pool
//      and the POST has no ai_envelope; Change is disabled for a bad name
import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';
import { waitFor } from './helpers/wait-for.js';
import { installDom, all, fire, isDisabled, type } from './helpers/fake-dom.bh-5750.js';

installDom();

const { TrackerSheet } = await import('../src/ui/TrackerSheets.js');
const lib = await import('../src/lib/tracker-sheets.js');
const { resetSheetConfig } = await import('../src/lib/ai-accounts.js');

const subtle = webcrypto.subtle;
const KP = await subtle.generateKey(
  { name: 'RSA-OAEP', modulusLength: 4096, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['encrypt', 'decrypt']);
const SPKI = Buffer.from(await subtle.exportKey('spki', KP.publicKey)).toString('base64');
const PEM = `-----BEGIN PUBLIC KEY-----\n${SPKI.match(/.{1,64}/g).join('\n')}\n-----END PUBLIC KEY-----\n`;
const open = async (b64) => new TextDecoder().decode(await subtle.decrypt({ name: 'RSA-OAEP' }, KP.privateKey, Buffer.from(b64, 'base64')));

const KEY = {
  linear: 'lin-api-fixture-SENTINEL7968',
  jira: 'tok-fixture-jira-SENTINEL7968',
  board: 'tok-fixture-board-SENTINEL7968'
};
const FILL = {
  linear: { api_key: KEY.linear, team: 'CRO', label: 'ai-build' },
  jira: { site: 'sandbox-example.atlassian.net', email: 'bot@example.com', api_token: KEY.jira, project_key: 'CROM' },
  board: { api_base: 'https://board.example.com/api/board', token: KEY.board }
};
const ENV_ID = crypto.randomUUID();
const TEST_ID = 'c'.repeat(32);

// The coord proxy, recorded. Any URL it does not serve is a 599 and a failure.
function proxy({ publicKey = PEM, envelope = [200, { id: ENV_ID, expires_at: '2099-01-01T00:00:00Z' }] } = {}) {
  const seen = [];
  const reply = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    const method = init.method || 'GET';
    seen.push({ url: u, method, body: init.body === undefined ? null : String(init.body) });
    if (method === 'GET' && u === '/api/coord/settings') return reply(200, { settings: [{ key: 'hub_envelope_public_key', value: publicKey }] });
    if (method === 'POST' && u === '/api/coord/secrets/envelope') return reply(...envelope);
    if (method === 'POST' && u === '/api/coord/onboarding/tracker-test') return reply(202, { test_id: TEST_ID });
    if (method === 'GET' && u.startsWith(`/api/coord/onboarding/tracker-test/${TEST_ID}?`)) return reply(200, { state: 'ok', detail: 'ok list=2 dry-write=ok' });
    return reply(599, { error: `the fake proxy does not serve ${method} ${u}` });
  };
  return seen;
}

const inputNamed = (root, name) => all(root).find((n) => n.localName === 'input' && n.attrs.name === name);
const buttonText = (root, label) => all(root).find((n) => n.localName === 'button' && n.textContent.trim() === label);
const alertOf = (root) => all(root).find((n) => n.attrs && n.attrs.role === 'alert');

// Mount the sheet, type every field, click Test and connect, wait for the answer.
async function drive(kind, fill, { onConnected } = {}) {
  resetSheetConfig();
  const root = document.createElement('div');
  const connected = [];
  mount(h(TrackerSheet, { kind, project: 'newproj', onConnected: onConnected || ((x) => connected.push(x)), onLater() {} }), root);
  await flush();
  for (const [name, v] of Object.entries(fill)) {
    const el = inputNamed(root, name);
    assert.ok(el, `${kind}: input ${name}`);
    el.value = v;
    fire(el, 'input');
    await flush();
  }
  const btn = buttonText(root, 'Test and connect');
  assert.ok(btn, 'the Test and connect button');
  assert.equal(isDisabled(btn), false, 'every field is filled');
  fire(btn, 'click');
  for (let i = 0; i < 40 && !connected.length && !alertOf(root); i++) await flush();
  return { root, connected };
}
const envelopePosts = (seen) => seen.filter((s) => s.method === 'POST' && s.url.endsWith('/secrets/envelope'));
const testPosts = (seen) => seen.filter((s) => s.method === 'POST' && s.url.endsWith('/onboarding/tracker-test'));

for (const kind of ['linear', 'jira', 'board']) {
  test(`S1-S4 ${kind}: one envelope POST with scope tracker:${kind}:newproj; the ciphertext opens to the fields; no KV route; no key in any body`, async () => {
    const seen = proxy();
    const { root, connected } = await drive(kind, FILL[kind]);
    try {
      assert.equal(alertOf(root), undefined, `no error: ${alertOf(root) && alertOf(root).textContent}`);
      const env = envelopePosts(seen);
      assert.equal(env.length, 1, 'exactly one envelope POST');
      const body = JSON.parse(env[0].body);
      assert.equal(body.scope, `tracker:${kind}:newproj`);
      assert.deepEqual(Object.keys(body).sort(), ['ciphertext', 'scope']);
      // S2: base64 of 512 bytes (RSA-4096), not the credential, and the hub can open it.
      assert.equal(body.ciphertext.length, 684);
      assert.match(body.ciphertext, /^[A-Za-z0-9+/]+={0,2}$/);
      assert.equal(body.ciphertext.includes(KEY[kind]), false);
      const plain = JSON.parse(await open(body.ciphertext));
      assert.deepEqual(Object.keys(plain), ['fields']);
      assert.equal(plain.fields[kind === 'linear' ? 'api_key' : kind === 'jira' ? 'api_token' : 'token'], KEY[kind]);
      for (const [k, v] of Object.entries(FILL[kind])) assert.equal(plain.fields[k], v, `${kind}.${k} sealed`);
      if (kind === 'jira') assert.equal(plain.fields.status_map, 'todo=To Do;in_progress=In Progress;review=In Review;closed=Done');
      // S4: the KV path is gone, and only the envelope id goes to the test start.
      for (const s of seen) {
        assert.equal(/tracker-secret|onb-tracker/.test(s.url), false, `no KV route: ${s.url}`);
        assert.equal((s.body || '').includes(KEY[kind]), false, `no key text in ${s.method} ${s.url}`);
      }
      const starts = testPosts(seen);
      assert.equal(starts.length, 1);
      const sb = JSON.parse(starts[0].body);
      assert.deepEqual(Object.keys(sb).sort(), ['envelope_id', 'kind', 'project'], 'the start body has no field');
      assert.deepEqual([sb.project, sb.kind, sb.envelope_id], ['newproj', kind, ENV_ID]);
      const envAt = seen.indexOf(env[0]);
      assert.ok(seen.indexOf(starts[0]) > envAt, 'the test starts after the envelope is stored');
      assert.equal(connected.length, 1, 'the hub answer reached onConnected');
      assert.equal(connected[0].test_id, TEST_ID);
      assert.equal(JSON.stringify(connected[0]).includes(KEY[kind]), false, 'onConnected gets no credential');
    } finally { mount(null, root); }
  });
}

test('S5 a blank hub key: a visible error, no envelope POST and no test POST', async () => {
  const seen = proxy({ publicKey: '' });
  const { root } = await drive('linear', FILL.linear);
  try {
    const a = alertOf(root);
    assert.ok(a, 'a role=alert node is rendered');
    assert.match(a.textContent, /hub key is not set/);
    assert.equal(envelopePosts(seen).length, 0);
    assert.equal(testPosts(seen).length, 0);
  } finally { mount(null, root); }
});

test('S6 an envelope POST that answers 400 shows the worker error and files no test', async () => {
  const seen = proxy({ envelope: [400, { error: 'ciphertext must be base64, 344..1024 chars' }] });
  const { root } = await drive('board', FILL.board);
  try {
    assert.match(alertOf(root).textContent, /ciphertext must be base64, 344\.\.1024 chars/);
    assert.equal(envelopePosts(seen).length, 1);
    assert.equal(testPosts(seen).length, 0);
  } finally { mount(null, root); }
});

test('S7 a plaintext over 446 bytes shows "too long" and posts nothing', async () => {
  const seen = proxy();
  const { root } = await drive('jira', { ...FILL.jira, api_token: `tok-fixture-${'x'.repeat(400)}` });
  try {
    assert.match(alertOf(root).textContent, /too long/);
    assert.equal(seen.filter((s) => s.method === 'POST').length, 0);
  } finally { mount(null, root); }
});

test('S8 a board base on a private host is refused at once; nothing is posted', async () => {
  const seen = proxy();
  const { root } = await drive('board', { ...FILL.board, api_base: 'https://10.0.0.5/api' });
  try {
    assert.match(alertOf(root).textContent, /api_base must be a public host/);
    assert.equal(seen.filter((s) => s.method === 'POST').length, 0);
  } finally { mount(null, root); }
});

test('T1 checkTrackerFields: the BH-7936 refusal table (moved from the worker); a valid set comes back trimmed', () => {
  const J = { ...FILL.jira, status_map: 'todo=To Do;in_progress=In Progress;review=In Review;closed=Done' };
  const refused = [
    ['github-issues', {}],
    ['Linear', FILL.linear],
    ['jira', { ...J, site: 'acme.atlassian.net.evil.example' }],
    ['jira', { ...J, site: 'https://acme.atlassian.net' }],
    ['jira', { ...J, site: 'localhost' }],
    ['jira', { ...J, project_key: 'crom' }],
    ['jira', { ...J, status_map: 'todo=To Do;oops' }],
    ['jira', { ...J, email: 'not-an-email' }],
    ['board', { ...FILL.board, api_base: 'http://board.example.com/api/board' }],
    ['board', { ...FILL.board, api_base: 'https://169.254.169.254/latest' }],
    ['board', { ...FILL.board, api_base: 'https://127.0.0.1/api' }],
    ['board', { ...FILL.board, api_base: 'https://localhost/api' }],
    ['board', { ...FILL.board, api_base: 'https://[::1]/api' }],
    ['board', { ...FILL.board, api_base: 'https://u:p@board.example.com/api' }],
    ['board', { ...FILL.board, token: 'short' }],
    ['linear', { ...FILL.linear, team: 'C R O' }],
    ['linear', { ...FILL.linear, extra: 'x' }],
    ['linear', { ...FILL.linear, team: 7 }],
    ['linear', { ...FILL.linear, api_key: '   ' }]
  ];
  for (const [kind, f] of refused) assert.ok(lib.checkTrackerFields(kind, f).error, `${kind} ${JSON.stringify(f)}`);
  assert.deepEqual(lib.checkTrackerFields('linear', { ...FILL.linear, team: '  CRO ' }).fields, FILL.linear);
  assert.equal(lib.checkTrackerFields('jira', { ...J, site: 'Sandbox-Example.Atlassian.NET' }).fields.site, 'sandbox-example.atlassian.net');
  assert.equal(lib.trackerScope('linear', 'newproj'), 'tracker:linear:newproj');
});

// ── O: Onboard Step 2, the "AI account" line ────────────────────────────────
const { OnboardScreen } = await import('../src/screens/Onboard.js');
const RUN_ID = `ob_${'0'.repeat(20)}`;
const OWN_TOKEN = 'tok-fixture-own-account-bh7968';

// The coord proxy for the onboarding screen and the two AI-account sheets.
function onboardProxy({ accounts = [] } = {}) {
  const seen = [];
  const envelopes = new Map();
  const reply = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    const method = init.method || 'GET';
    seen.push({ url: u, method, body: init.body === undefined ? null : String(init.body) });
    const body = init.body ? JSON.parse(init.body) : null;
    const one = /^\/api\/coord\/settings\/(.+)$/.exec(u);
    if (method === 'GET' && one) return reply(200, { setting: { key: decodeURIComponent(one[1]), value: decodeURIComponent(one[1]) === 'onboarding.detect_poll_ms' ? '1' : '0' } });
    if (method === 'GET' && u === '/api/coord/settings') return reply(200, { settings: [{ key: 'hub_envelope_public_key', value: PEM }, { key: 'ai_account_status_poll_s', value: '1' }] });
    if (method === 'PUT' && u === '/api/coord/settings') return reply(200, { ok: true });
    if (method === 'GET' && u === '/api/coord/onboarding/repos') return reply(200, { state: 'ok', repos: [] });
    if (method === 'GET' && u.startsWith('/api/coord/onboarding/repo?')) return reply(200, { state: 'ok', visible: true, facts: { default_branch: 'main', has_issues: true, open_issues: 0 } });
    if (method === 'POST' && u === '/api/coord/onboarding/runs') return reply(201, { id: RUN_ID, state: 'queued', created: true });
    if (method === 'GET' && u === '/api/coord/ai-accounts') return reply(200, { accounts, limit: 500, truncated: false });
    if (method === 'POST' && u === '/api/coord/secrets/envelope') {
      const id = crypto.randomUUID();
      envelopes.set(id, body.scope);
      return reply(200, { id, expires_at: '2099-01-01T00:00:00Z' });
    }
    if (method === 'POST' && u === '/api/coord/ai-accounts') return reply(200, { id: crypto.randomUUID(), state: 'pending' });
    if (method === 'GET' && /^\/api\/coord\/secrets\/envelope\/[0-9a-f-]{36}\/status$/.test(u)) return reply(200, { state: 'applied' });
    return reply(599, { error: `the fake proxy does not serve ${method} ${u}` });
  };
  return { seen, envelopes };
}

// The fake DOM has no layout: visible = attached under the root, and no node
// on the way up is hidden or display:none (the toBeVisible() stand-in).
const visible = (root, n) => {
  if (!n) return false;
  for (let p = n; p; p = p.parentNode) {
    if (p.attrs && 'hidden' in p.attrs) return false;
    if (p.style && p.style.display === 'none') return false;
    if (p === root) return true;
  }
  return false;
};
const byId = (root, id) => all(root).find((n) => n.attrs && n.attrs.id === id);
const dialogNamed = (root, name) => all(root).find((n) => n.attrs && n.attrs.role === 'dialog' && n.attrs['aria-label'] === name);
const reviewLine = (root, label) => {
  const dts = all(root).filter((n) => n.localName === 'dt');
  const dt = dts.find((n) => n.textContent.trim() === label);
  return dt ? dt.nextSibling : null;
};
const aiValue = (root) => {
  const dd = reviewLine(root, 'AI account');
  return dd ? all(dd).filter((n) => n.nodeType === 3 && n.parentNode.localName !== 'button').map((n) => n.textContent).join('').trim() : null;
};
const changeBtn = (root) => {
  const dd = reviewLine(root, 'AI account');
  return dd ? all(dd).find((n) => n.localName === 'button' && n.textContent.trim() === 'Change') : null;
};
const puts = (seen) => seen.filter((s) => s.method === 'PUT' && s.url === '/api/coord/settings');
const runPosts = (seen) => seen.filter((s) => s.method === 'POST' && s.url === '/api/coord/onboarding/runs');
const confirmButton = (root, label) => {
  const m = all(root).find((n) => n.attrs && n.attrs.role === 'dialog' && (n.attrs.class || '').split(/\s+/).includes('modal'));
  return m ? all(m).find((n) => n.localName === 'button' && n.textContent.trim() === label) : null;
};

const mountedO = new Set();
test.afterEach(() => { for (const r of mountedO) mount(null, r); mountedO.clear(); });
async function onboardStep2(slug) {
  const doc = installDom();
  // useSheetFocus gives focus back on close, if the opener is still in the document.
  doc.contains = (n) => all(doc).includes(n);
  const root = doc.createElement('div');
  doc.appendChild(root);
  mount(h(OnboardScreen), root);
  mountedO.add(root);
  await flush();
  type(byId(root, 'onboard-slug'), slug);
  await waitFor(() => all(root).some((n) => n.attrs && n.attrs.class === 'onboard-facts'), 'the detect facts');
  await flush();
  fire(buttonText(root, 'Continue'), 'click');
  await flush();
  return root;
}
async function openSheet(root, project) {
  const c = changeBtn(root);
  assert.ok(visible(root, c), 'the AI account line has a visible Change button');
  assert.equal(isDisabled(c), false, 'Change is enabled for a valid project');
  fire(c, 'click');
  await flush();
  const d = dialogNamed(root, `AI account for ${project}`);
  assert.ok(visible(root, d), `the dialog "AI account for ${project}" is visible`);
  return d;
}
async function start(root, seen) {
  fire(buttonText(root, 'Start setup'), 'click');
  await waitFor(() => runPosts(seen).length === 1, 'the run POST');
  return JSON.parse(runPosts(seen)[0].body);
}

test('O1 O2 Step 2: Change opens the AI account sheet; the fleet pool writes account.<project> = shared and the line reads fleet pool', async () => {
  const { seen } = onboardProxy();
  const root = await onboardStep2('example-org/acme-os');
  assert.equal(aiValue(root), 'fleet pool');
  assert.equal(changeBtn(root).attrs['aria-label'], 'change the AI account');
  const d = await openSheet(root, 'acme-os');
  fire(all(d).find((n) => n.localName === 'button' && n.textContent.trim() === 'USE THE FLEET POOL'), 'click');
  await flush();
  const yes = confirmButton(root, 'UNPIN');
  assert.ok(visible(root, yes), 'the in-app confirm is visible');
  fire(yes, 'click');
  await waitFor(() => !dialogNamed(root, 'AI account for acme-os'), 'the sheet closes');
  const p = puts(seen);
  assert.equal(p.length, 1, 'one PUT');
  assert.deepEqual([JSON.parse(p[0].body).key, JSON.parse(p[0].body).value], ['account.acme-os', 'shared']);
  assert.equal(aiValue(root), 'fleet pool');
  const sent = await start(root, seen);
  assert.equal('ai_envelope' in sent, false, 'a pool choice sends no envelope');
});

test('O3 an existing account: the line reads its label; Start setup sends no ai_envelope', async () => {
  const { seen } = onboardProxy({ accounts: [{ id: crypto.randomUUID(), vendor: 'anthropic', label: 'team-a', state: 'active', revoked_at: null }] });
  const root = await onboardStep2('example-org/acme-os');
  const d = await openSheet(root, 'acme-os');
  await waitFor(() => all(d).some((n) => n.localName === 'select'), 'the account list');
  const sel = all(d).find((n) => n.localName === 'select');
  sel.value = 'team-a';
  fire(sel, 'change');
  await flush();
  fire(all(dialogNamed(root, 'AI account for acme-os')).find((n) => n.localName === 'button' && n.textContent.trim() === 'USE THIS ACCOUNT'), 'click');
  await flush();
  fire(confirmButton(root, 'PIN'), 'click');
  await waitFor(() => !dialogNamed(root, 'AI account for acme-os'), 'the sheet closes');
  assert.equal(aiValue(root), 'team-a');
  assert.equal(JSON.parse(puts(seen)[0].body).value, 'team-a');
  const sent = await start(root, seen);
  assert.equal('ai_envelope' in sent, false, 'an existing account sends no envelope');
});

test('O4 cancel in the confirm, then CLOSE: no PUT; the line still reads fleet pool', async () => {
  const { seen } = onboardProxy();
  const root = await onboardStep2('example-org/acme-os');
  let d = await openSheet(root, 'acme-os');
  fire(all(d).find((n) => n.localName === 'button' && n.textContent.trim() === 'USE THE FLEET POOL'), 'click');
  await flush();
  fire(confirmButton(root, 'CANCEL'), 'click');
  await flush();
  d = dialogNamed(root, 'AI account for acme-os');
  assert.ok(visible(root, d), 'a cancel keeps the sheet open');
  fire(all(d).find((n) => n.localName === 'button' && n.textContent.trim() === 'CLOSE'), 'click');
  await flush();
  assert.equal(dialogNamed(root, 'AI account for acme-os'), undefined, 'CLOSE closes the sheet');
  assert.equal(puts(seen).length, 0, 'no PUT');
  assert.equal(aiValue(root), 'fleet pool');
});

test('O5 O6 the own account: its envelope id rides the run as ai_envelope, and only for the project it was added for', async () => {
  resetSheetConfig();
  const { seen, envelopes } = onboardProxy();
  const root = await onboardStep2('example-org/acme-os');
  const d = await openSheet(root, 'acme-os');
  fire(all(d).find((n) => n.localName === 'button' && n.textContent.trim() === "ADD THIS PROJECT'S OWN ACCOUNT"), 'click');
  await flush();
  const add = dialogNamed(root, 'ADD AI ACCOUNT');
  assert.ok(visible(root, add), 'the add sheet is visible');
  await waitFor(() => !isDisabled(all(add).find((n) => n.localName === 'button' && n.textContent.trim() === 'TEST AND SAVE')), 'the hub key loads');
  const inputs = all(add).filter((n) => n.localName === 'input');
  type(inputs.find((n) => n.attrs.placeholder === 'team-a'), 'acme-own');
  type(inputs.find((n) => n.attrs.type === 'password'), OWN_TOKEN);
  await flush();
  fire(all(add).find((n) => n.localName === 'form'), 'submit');
  await waitFor(() => Boolean(confirmButton(root, 'PIN')), 'the pin confirm', () => JSON.stringify([seen.map((s) => s.method + ' ' + s.url), all(root).filter((n) => n.attrs && /status|alert/.test(n.attrs.role || '')).map((n) => n.textContent)]));
  fire(confirmButton(root, 'PIN'), 'click');
  await waitFor(() => aiValue(root) === 'acme-own', 'the line reads the new label', () => `line: ${aiValue(root)}`);
  assert.equal(envelopes.size, 1, 'one envelope stored');
  const [envId, scope] = [...envelopes][0];
  assert.match(scope, /^ai-account:.*:project:acme-os$/);
  assert.equal(JSON.parse(puts(seen)[0].body).key, 'account.acme-os');
  // O6: Back, a new project name, Continue: the choice was for acme-os only.
  fire(buttonText(root, 'Back'), 'click');
  await flush();
  type(byId(root, 'onboard-project'), 'Bad Name');
  await flush();
  fire(buttonText(root, 'Continue'), 'click');
  await flush();
  assert.equal(isDisabled(changeBtn(root)), true, 'Change is disabled for an invalid project name');
  fire(buttonText(root, 'Back'), 'click');
  await flush();
  type(byId(root, 'onboard-project'), 'acme-two');
  await flush();
  fire(buttonText(root, 'Continue'), 'click');
  await flush();
  assert.equal(aiValue(root), 'fleet pool', 'a renamed project falls back to the fleet pool');
  const other = await start(root, seen);
  assert.equal(other.project, 'acme-two');
  assert.equal('ai_envelope' in other, false, 'no stale envelope for another project');
  // O5: back to acme-os: the envelope id rides the run.
  fire(buttonText(root, 'Back'), 'click');
  await flush();
  type(byId(root, 'onboard-project'), 'acme-os');
  await flush();
  fire(buttonText(root, 'Continue'), 'click');
  await flush();
  assert.equal(aiValue(root), 'acme-own');
  fire(buttonText(root, 'Start setup'), 'click');
  await waitFor(() => runPosts(seen).length === 2, 'the second run POST');
  const sent = JSON.parse(runPosts(seen)[1].body);
  assert.equal(sent.project, 'acme-os');
  assert.equal(sent.ai_envelope, envId, 'the run carries the own account envelope id');
  assert.equal(seen.some((s) => (s.body || '').includes(OWN_TOKEN)), false, 'no request body holds the token');
});

test('O7 aiChoiceOf: only a written own-account result keeps an envelope id; other results change nothing', async () => {
  const { aiChoiceOf, aiChoiceFor, runInputs } = await import('../src/lib/onboard.js');
  const id = crypto.randomUUID();
  assert.deepEqual(aiChoiceOf('p', { status: 'written', choice: { kind: 'account', label: 'own-a', own: true }, envelope_id: id }),
    { project: 'p', value: 'own-a', envelopeId: id });
  assert.equal(aiChoiceOf('p', { status: 'written', choice: { kind: 'account', label: 'team-a' }, envelope_id: id }).envelopeId, null,
    'an existing account never carries an envelope');
  assert.equal(aiChoiceOf('p', { status: 'written', choice: { kind: 'account', label: 'own-a', own: true }, envelope_id: id.toUpperCase() }).envelopeId, null);
  assert.equal(aiChoiceOf('p', { status: 'written', choice: { kind: 'pool' } }).value, 'fleet pool');
  for (const status of ['cancelled', 'failed', 'closed', 'invalid']) {
    assert.equal(aiChoiceOf('p', { status, choice: { kind: 'account', label: 'own-a', own: true }, envelope_id: id }), null, status);
  }
  assert.equal(aiChoiceFor({ project: 'a', value: 'x', envelopeId: id }, 'b'), null);
  const base = { slug: 'example-org/p', project: 'p', tracker: 'github-issues' };
  assert.equal(runInputs({ ...base, aiEnvelope: id }).ai_envelope, id);
  for (const bad of [null, '', id.toUpperCase(), id.replace(/-/g, ''), '../x']) {
    assert.equal('ai_envelope' in runInputs({ ...base, aiEnvelope: bad }), false, String(bad));
  }
});
