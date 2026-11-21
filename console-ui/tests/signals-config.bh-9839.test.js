// BH-9839 (slice C1 of BH-9800): the project settings page "Signals"
// (/settings/p/<project>/signals), its Set/Replace sheet, the api client, the
// pure half, the coord write rows and the SIGNALS column of the Fleet table.
//
//   W1-W4  the coord rows, through the real proxy onRequest (stub upstream)
//   A1-A6  the client's 403/404 classification (stub fetch)
//   P1-P10 prefixError / fieldError on the plan's decision table
//   C1-C6  cardState / pillState on the plan's decision table
//   S1-S10 the page (real SignalsScreen in the fake DOM; S3 also renders SignalsView)
//   K1-K8  the sheet, opened from the real page
//   E1     the entry point: the settings menu row -> the page, through App
//   F1-F5  the Fleet SIGNALS column, and the real FleetScreen read
//
// Fixtures copy the C0 GET answer shape (worker/jobs/src/routes/signal-keys.js
// GET /api/signal-keys). Every key-shaped value is built at run time from
// parts and carries the word "fixture" (D47, D64). Native dialogs throw in the
// fake DOM (tests/helpers/fake-dom.bh-5750.js). 0 vendor calls: every fetch is
// a stub that throws on an unknown host.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { h, render as mount } from 'preact';
import { render } from 'preact-render-to-string';
import { flush } from './helpers/settle.js';
import { installDom, routedFetch, all, fire, dialogOf, buttonIn, buttonsIn, confirmOf, rowsOf } from './helpers/fake-dom.bh-5750.js';

// A window whose history really moves location (the settings-shell pattern),
// so a Link click lands on the next screen through the real router.
const events = [];
const setUrl = (to) => {
  const u = new URL(to, 'http://console.test');
  Object.assign(window.location, { pathname: u.pathname, search: u.search, hash: u.hash });
};
globalThis.window = globalThis.window || {
  location: { pathname: '/', search: '', hash: '' },
  dispatchEvent(e) { events.push(e && e.type); return true; }, addEventListener() {}, removeEventListener() {},
  history: { pushState(_s, _t, to) { setUrl(to); }, replaceState(_s, _t, to) { setUrl(to); } },
  scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} })
};

const { App, FleetContext } = await import('../src/app.js');
const { AuthError } = await import('../src/api.js');
const {
  trimPaste, prefixError, fieldError, cardState, pillState, sendBody, isTokenShaped, maskTokens, OWNER_LINE
} = await import('../src/lib/signal-keys.js');
const { signalKeysList, signalKeySet, signalKeyClear, signalKeyTest } = await import('../src/lib/signal-keys-api.js');
const { SignalsScreen, SignalsView } = await import('../src/screens/settings/project/Signals.js');
const { SETTINGS_MENU, findItem } = await import('../src/lib/settings-menu.js');
const { SETTINGS_SCREENS } = await import('../src/screens/settings/Shell.js');
const { ProjectsTable, FleetScreen } = await import('../src/screens/Fleet.js');
const { onRequest: coord, ROUTES } = await import('../functions/api/coord/[[path]].js');
const { _resetCertsCache } = await import('../functions/_lib/access-identity.js');

const mounted = new Set();
test.afterEach(() => { for (const r of mounted) mount(null, r); mounted.clear(); events.length = 0; });

// ------------------------------------------------------------------ fixtures

// Built from parts, so no scanner reads a literal key in this file.
const SENTRY_P = ['sntry', 'u_'].join('');
const SENTRY_S = ['sntry', 's_'].join('');
const PH_P = ['ph', 'x_'].join('');
const SENTRY_TOKEN = `${SENTRY_P}fixtureSentry0123456789`;
const PH_KEY = `${PH_P}fixturePosthog0123456789`;
const TOKEN_IN_HTML = /(sntry[a-z]_|ph[a-z]_)[A-Za-z0-9]/;

// The seeded catalog (schema.d/202611172248-bh-9800-signal-keys.sql), as the C0 GET answers it.
const KINDS = [
  {
    kind: 'sentry', label: 'Sentry', scope_note: 'Sentry: read scopes plus event:write, no admin.',
    fields: [
      { name: 'org', label: 'Organization slug', placeholder: 'my-org', re: '^[a-z0-9][a-z0-9_-]{0,63}$', secret: 0 },
      { name: 'project', label: 'Project slug', placeholder: 'my-project', re: '^[a-z0-9][a-z0-9_-]{0,63}$', secret: 0 },
      { name: 'token', label: 'API token', placeholder: 'sntryu_…', re: '^[A-Za-z0-9_=+/.-]+$', secret: 1, prefixes: [SENTRY_P, SENTRY_S] }
    ]
  },
  {
    kind: 'posthog', label: 'PostHog', scope_note: 'PostHog: read scopes plus annotation write, scoped to the one project.',
    fields: [
      { name: 'host', label: 'Host', placeholder: 'https://us.posthog.com', re: '^https://[^\\s]{1,200}$', secret: 0 },
      { name: 'project_id', label: 'Project id', placeholder: '12345', re: '^[0-9]{1,12}$', secret: 0 },
      { name: 'key', label: 'Personal API key', placeholder: 'phx_…', re: '^[A-Za-z0-9_=+/.-]+$', secret: 1, prefixes: [PH_P] }
    ]
  }
];
const SENTRY = KINDS[0];
const POSTHOG = KINDS[1];
const def = (k, name) => k.fields.find((f) => f.name === name);

const row = (project, kind, over = {}) => ({
  project, kind,
  fields: kind === 'sentry' ? { org: 'acme-fixture', project: 'web-fixture' } : { host: 'https://us.posthog.com', project_id: '4242' },
  secret_set: true, updated_at: '2026-11-18T09:00:00Z', updated_by: 'operator@example.com', last_used_at: null,
  last_test_at: '2026-11-18T09:01:00Z', last_test_status: 200, last_test_result: 'ok',
  rotate_by: '2099-02-16T09:00:00Z', rotate_overdue: false, ...over
});
const listOf = (rows, over = {}) => ({ kinds: KINDS, rows, more: false, rotate_days: 90, as_of: '2026-11-20T10:00:00Z', ...over });

const P = 'project-6-os';

// One fake API. `state.rows` is the store; set/clear/test answers can be swapped.
function signalFake(state = {}) {
  const st = { rows: [], set: null, clear: null, test: null, list: null, ...state };
  const calls = routedFetch((u, method, body) => {
    if (u.startsWith('/api/coord/signal-keys/set') && method === 'POST') {
      if (st.set) return st.set(body);
      st.rows = st.rows.filter((r) => !(r.project === body.project && r.kind === body.kind));
      const clear = Object.fromEntries(Object.entries(body.fields).filter(([k]) => !['token', 'key'].includes(k)));
      st.rows.push(row(body.project, body.kind, { fields: clear, last_test_at: null, last_test_status: null, last_test_result: null }));
      return [200, { stored: true, project: body.project, kind: body.kind, fields: clear, updated_at: '2026-11-20T10:00:00Z', updated_by: 'operator@example.com', key_id: 1 }];
    }
    if (u.startsWith('/api/coord/signal-keys/clear') && method === 'POST') {
      if (st.clear) return st.clear(body);
      const had = st.rows.some((r) => r.project === body.project && r.kind === body.kind);
      st.rows = st.rows.filter((r) => !(r.project === body.project && r.kind === body.kind));
      return had ? [200, { cleared: true, project: body.project, kind: body.kind }] : [404, { error: 'no signal key for this project and kind' }];
    }
    if (u.startsWith('/api/coord/signal-keys/test') && method === 'POST') {
      if (st.test) return st.test(body);
      return [200, { ok: true, result: 'ok', status: 200, reason: 'the vendor accepted the key', tested_at: '2026-11-20T10:00:05Z' }];
    }
    if (u.startsWith('/api/coord/signal-keys')) {
      if (st.list) return st.list(u);
      const q = new URL(u, 'http://x').searchParams.get('project');
      return [200, listOf(q ? st.rows.filter((r) => r.project === q) : st.rows)];
    }
    if (u.startsWith('/api/dash/projects')) return [200, { projects: [{ project: P }, { project: 'project-3' }], projects_source: 'fleet_status', snapshot_age_min: 1 }];
    return [200, {}];
  });
  return { calls, st };
}

async function mountPage(state = {}, project = P) {
  const doc = installDom();
  setUrl(`/settings/p/${project}/signals`);
  const fake = signalFake(state);
  const el = doc.createElement('div');
  mounted.add(el);
  mount(h(SignalsScreen, { project }), el);
  await flush();
  return { el, doc, ...fake };
}

const cardOf = (root, kind) => all(root).find((n) => n.attrs && n.attrs['data-kind'] === kind
  && (n.attrs.class || '').split(/\s+/).includes('signals__card'));
const text = (root) => root.textContent.replace(/\s+/g, ' ');
const posts = (calls) => calls.filter((c) => c.method === 'POST');
const inputNamed = (root, name) => all(root).find((n) => n.localName === 'input' && n.attrs.name === name);
const valueOf = (n) => (n.value !== undefined ? n.value : n.attrs.value);
const parentClass = (n) => (n.parentNode && n.parentNode.attrs.class) || '';
const settle = async () => { await flush(); await flush(); };

// ------------------------------------------------------------------ W: coord rows

const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
const TEAM = 'team.example.cloudflareaccess.com';
const CERTS = `https://${TEAM}/cdn-cgi/access/certs`;
const AUD = 'test-aud-9839';
const BOX = 'box-ops-token-fixture-9839';
const ENV_ON = { HARNESS_SECRET: 'test-harness-secret-fixture-9839', CF_ACCESS_TEAM_DOMAIN: TEAM, CF_ACCESS_AUD: AUD, BOX_OPS_TOKEN: BOX };

const b64u = (bytes) => Buffer.from(bytes).toString('base64url');
const enc = (obj) => b64u(Buffer.from(JSON.stringify(obj)));
const KEY = await crypto.subtle.generateKey(
  { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
  true, ['sign', 'verify']);
const KID = 'kid-9839';
const JWK = { ...(await crypto.subtle.exportKey('jwk', KEY.publicKey)), kid: KID, alg: 'RS256', use: 'sig' };
// determinism: ok-file clock-now-js the one clock read is NOW below, captured
// once at load. The Access JWT's exp/iat are OFFSETS from it (the verifier
// checks exp against the real clock); no case asserts a calendar date.
const NOW = Date.now();
const nowS = () => Math.floor(NOW / 1000);
async function jwt() {
  const payload = { aud: [AUD], iss: `https://${TEAM}`, email: 'operator@example.com', exp: nowS() + 600, iat: nowS() - 5, sub: 'u1' };
  const input = `${enc({ alg: 'RS256', kid: KID, typ: 'JWT' })}.${enc(payload)}`;
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', KEY.privateKey, new TextEncoder().encode(input));
  return `${input}.${b64u(new Uint8Array(sig))}`;
}

let seq = 0;
async function forward(rest, { method = 'POST', body } = {}) {
  _resetCertsCache();
  const jobs = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const url = typeof input === 'string' ? input : input.url;
    if (url === CERTS) return new Response(JSON.stringify({ keys: [JWK] }), { status: 200 });
    if (url.startsWith(CONSOLE)) return new Response('{}', { status: 200 });
    if (url.startsWith(JOBS)) {
      jobs.push({ url, method: init.method, headers: { ...init.headers }, body: init.body });
      return new Response('{"ok":true}', { status: 200, headers: { 'content-type': 'application/json' } });
    }
    throw new Error(`unexpected fetch ${url}`);
  };
  try {
    const res = await coord({
      request: new Request(`https://mc.example.com/api/coord/${rest}`, {
        method,
        headers: {
          cookie: `dash=signals${++seq}`, 'content-type': 'application/json',
          'cf-access-authenticated-user-email': 'the operator@example.com', 'cf-access-jwt-assertion': await jwt()
        },
        body: body == null ? null : JSON.stringify(body)
      }),
      env: ENV_ON,
      params: { path: rest.split('?')[0].split('/').filter(Boolean) }
    });
    return { status: res.status, jobs };
  } finally { globalThis.fetch = real; }
}
const lower = (hd) => Object.fromEntries(Object.entries(hd).map(([k, v]) => [k.toLowerCase(), v]));

test('W1 the composed ROUTES hold set, clear and test as POST rows with boxOps', () => {
  for (const path of ['signal-keys/set', 'signal-keys/clear', 'signal-keys/test']) {
    const hits = ROUTES.filter((w) => w.method === 'POST' && w.path === path);
    assert.equal(hits.length, 1, path);
    assert.equal(hits[0].boxOps, true, `${path} carries the owner proof`);
  }
  const set = ROUTES.find((w) => w.path === 'signal-keys/set');
  assert.deepEqual(set.body, ['project', 'kind', 'fields']);
  for (const path of ['signal-keys/clear', 'signal-keys/test']) {
    assert.deepEqual(ROUTES.find((w) => w.path === path).body, ['project', 'kind']);
  }
  assert.equal(ROUTES.some((w) => typeof w.path === 'string' && /signal-keys\/(read|hub-read)/.test(w.path)), false, 'no browser row for the lane or hub read');
});

test('W2 a set through the real proxy forwards project, kind, fields and the stamped actor, plus the owner proof', async () => {
  const sent = sendBody(P, 'posthog', POSTHOG.fields, { host: 'https://us.posthog.com', project_id: '4242', key: `${PH_KEY}\r\n` });
  const r = await forward('signal-keys/set', { body: { ...sent, value: 'x', ciphertext: 'y', actor: 'mallory' } });
  assert.equal(r.status, 200);
  assert.equal(r.jobs.length, 1);
  assert.equal(r.jobs[0].url, `${JOBS}/api/signal-keys/set`);
  const fwd = JSON.parse(r.jobs[0].body);
  assert.deepEqual(Object.keys(fwd).sort(), ['actor', 'fields', 'kind', 'project']);
  assert.equal(fwd.actor, 'operator@example.com', 'the proxy stamps the actor, the browser value is dropped');
  assert.equal(fwd.fields.key, PH_KEY, 'sendBody output reaches the worker trimmed');
  const hd = lower(r.jobs[0].headers);
  assert.equal(hd['x-box-ops-token'], BOX);
  assert.equal(hd['x-box-ops-identity'], 'operator@example.com');
  for (const rest of ['signal-keys/clear', 'signal-keys/test']) {
    const c = await forward(rest, { body: { project: P, kind: 'sentry', fields: { a: 'b' } } });
    assert.equal(c.jobs.length, 1, rest);
    assert.deepEqual(Object.keys(JSON.parse(c.jobs[0].body)).sort(), ['actor', 'kind', 'project'], rest);
    assert.equal(lower(c.jobs[0].headers)['x-box-ops-token'], BOX, rest);
  }
});

test('W3 a set drops a fields value that is an array, holds a number, or a non-string project', async () => {
  for (const fields of [['a'], { host: 'https://us.posthog.com', project_id: 4242 }, 'k=v', null]) {
    const r = await forward('signal-keys/set', { body: { project: P, kind: 'posthog', fields } });
    assert.equal(r.jobs.length, 1);
    assert.equal(Object.prototype.hasOwnProperty.call(JSON.parse(r.jobs[0].body), 'fields'), false, JSON.stringify(fields));
  }
  const r = await forward('signal-keys/test', { body: { project: 7, kind: 'sentry' } });
  assert.equal(Object.prototype.hasOwnProperty.call(JSON.parse(r.jobs[0].body), 'project'), false);
});

test('W4 a PUT or DELETE to a signal-keys write is 405; the read, hub-read and the GET list behave', async () => {
  for (const [method, rest] of [['PUT', 'signal-keys/set'], ['DELETE', 'signal-keys/clear'], ['POST', 'signal-keys/read'], ['POST', 'signal-keys/hub-read']]) {
    const r = await forward(rest, { method, body: { project: P, kind: 'sentry' } });
    assert.equal(r.status, 405, `${method} ${rest}`);
    assert.equal(r.jobs.length, 0, `${method} ${rest} forwards nothing`);
  }
  const g = await forward('signal-keys?project=project-6-os', { method: 'GET' });
  assert.equal(g.status, 200);
  assert.equal(g.jobs[0].url, `${JOBS}/api/signal-keys?project=project-6-os`);
  assert.equal(lower(g.jobs[0].headers)['x-box-ops-token'], undefined, 'a GET carries no owner proof');
});

// ------------------------------------------------------------------ A: the client

function stubOnce(status, body) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET', body: init.body ? JSON.parse(init.body) : undefined });
    return { ok: status >= 200 && status < 300, status, text: async () => (body === undefined ? '' : JSON.stringify(body)) };
  };
  return calls;
}
const caught = async (p) => { try { await p; } catch (e) { return e; } return null; };

test('A1 a 403 with the signal-keys owner text is a refused Error, not an AuthError', async () => {
  stubOnce(403, { error: 'signal-keys needs the operator token or the owner proof' });
  const e = await caught(signalKeyTest({ project: P, kind: 'sentry' }));
  assert.ok(e instanceof Error);
  assert.equal(e instanceof AuthError, false);
  assert.equal(e.refused, true);
  assert.equal(e.status, 403);
});

test('A2 a 403 unauthorized, a 403 with no body and a 404 unauthorized are AuthError', async () => {
  for (const [status, body] of [[403, { error: 'unauthorized' }], [403, undefined], [404, { error: 'unauthorized' }]]) {
    stubOnce(status, body);
    assert.ok((await caught(signalKeysList(P))) instanceof AuthError, `${status} ${JSON.stringify(body)}`);
  }
});

test('A3 a 404 refused/no_entry is an Error with status 404 and the body', async () => {
  stubOnce(404, { error: 'refused', why: 'no_entry' });
  const e = await caught(signalKeyTest({ project: P, kind: 'sentry' }));
  assert.equal(e instanceof AuthError, false);
  assert.equal(e.status, 404);
  assert.equal(e.body.why, 'no_entry');
  assert.notEqual(e.refused, true);
});

test('A4 a 403 owner_only from another route is an AuthError', async () => {
  stubOnce(403, { error: 'owner_only' });
  assert.ok((await caught(signalKeyClear({ project: P, kind: 'sentry' }))) instanceof AuthError);
});

test('A5 a 400 with field and a 503 are plain Errors with status and body', async () => {
  stubOnce(400, { error: 'API token must start with x', field: 'token' });
  const e = await caught(signalKeySet({ project: P, kind: 'sentry', fields: {} }));
  assert.equal(e.status, 400);
  assert.equal(e.body.field, 'token');
  assert.equal(e.message, 'API token must start with x');
  stubOnce(503, { error: 'signal key encryption key missing' });
  const e2 = await caught(signalKeySet({ project: P, kind: 'sentry', fields: {} }));
  assert.equal(e2.status, 503);
  assert.equal(e2 instanceof AuthError, false);
});

test('A6 the calls: GET list with and without project, POST set/clear/test with a JSON body', async () => {
  const calls = stubOnce(200, { ok: true });
  await signalKeysList();
  await signalKeysList('a b');
  await signalKeySet({ project: P, kind: 'sentry', fields: { org: 'o' } });
  await signalKeyClear({ project: P, kind: 'sentry' });
  await signalKeyTest({ project: P, kind: 'posthog' });
  assert.deepEqual(calls.map((c) => [c.method, c.url]), [
    ['GET', '/api/coord/signal-keys'],
    ['GET', '/api/coord/signal-keys?project=a%20b'],
    ['POST', '/api/coord/signal-keys/set'],
    ['POST', '/api/coord/signal-keys/clear'],
    ['POST', '/api/coord/signal-keys/test']
  ]);
  assert.deepEqual(calls[2].body, { project: P, kind: 'sentry', fields: { org: 'o' } });
});

// ------------------------------------------------------------------ P: prefix and format

const TOK = def(SENTRY, 'token');
const PHK = def(POSTHOG, 'key');

test('P1 a Sentry user token passes', () => {
  assert.equal(prefixError(TOK, SENTRY_TOKEN), null);
  assert.equal(fieldError(TOK, SENTRY_TOKEN), null);
});
test('P2 a Sentry org token passes', () => {
  assert.equal(fieldError(TOK, `${SENTRY_S}fixtureOrg0123`), null);
});
test('P3 leading spaces and a trailing CRLF are trimmed first, never refused', () => {
  assert.equal(trimPaste(`  ${PH_KEY}\r\n`), PH_KEY);
  assert.equal(trimPaste(`\t${PH_KEY}\n`), PH_KEY);
  assert.equal(fieldError(PHK, `  ${PH_KEY}\r\n`), null);
  assert.equal(prefixError(PHK, `  ${PH_KEY}\r\n`), null);
});
test('P4 an upper-case prefix is a prefix error with the server text', () => {
  assert.equal(prefixError(TOK, `sntryU_fixture0123`), `API token must start with ${SENTRY_P} or ${SENTRY_S}`);
});
test('P5 sntry_ (no letter) is a prefix error', () => {
  assert.match(fieldError(TOK, 'sntry_fixture0123'), /must start with/);
});
test('P6 phx with no underscore is a prefix error', () => {
  assert.equal(fieldError(PHK, 'phxfixture0123'), `Personal API key must start with ${PH_P}`);
});
test('P7 a PostHog project API key (phc_) is a prefix error', () => {
  assert.match(fieldError(PHK, ['ph', 'c_fixture0123'].join('')), /must start with/);
});
test('P8 a pasted header (Bearer phx_…) is a prefix error', () => {
  assert.match(fieldError(PHK, `Bearer ${PH_KEY}`), /must start with/);
});
test('P9 empty after the trim is "is required"', () => {
  assert.equal(fieldError(PHK, ' \r\n'), 'Personal API key is required');
  assert.equal(fieldError(def(POSTHOG, 'host'), undefined), 'Host is required');
});
test('P10 a non-secret field runs the format check and never the prefix check', () => {
  const org = def(SENTRY, 'org');
  assert.equal(prefixError(org, 'My Org'), null);
  assert.equal(fieldError(org, 'My Org'), 'Organization slug does not match the format (my-org)');
  assert.equal(fieldError(org, ' acme-fixture '), null);
  assert.equal(fieldError(def(POSTHOG, 'project_id'), '12a'), 'Project id does not match the format (12345)');
  assert.equal(fieldError(def(POSTHOG, 'host'), 'https://eu.posthog.com'), null);
});

// ------------------------------------------------------------------ C: card and pill states

test('C1 no row is missing', () => {
  assert.equal(cardState(SENTRY, null).state, 'missing');
});
test('C2 a row never tested is set', () => {
  assert.equal(cardState(SENTRY, row(P, 'sentry', { last_test_at: null, last_test_status: null, last_test_result: null })).state, 'set');
});
test('C3 a row tested ok is set', () => {
  assert.equal(cardState(SENTRY, row(P, 'sentry')).state, 'set');
});
test('C4 http_401, timeout, network and decrypt_failed are failing', () => {
  for (const r of ['http_401', 'timeout', 'network', 'decrypt_failed']) {
    assert.equal(cardState(POSTHOG, row(P, 'posthog', { last_test_result: r })).state, 'failing', r);
  }
});
test('C5 pillState: catalog kinds only, in catalog order; another project\'s row is a near miss', () => {
  const rows = [row('other', 'sentry'), row(P, 'posthog', { last_test_result: 'timeout' }), row(P, 'datadog')];
  assert.deepEqual(pillState(KINDS, rows, P).map((p) => [p.kind, p.state]), [['sentry', 'missing'], ['posthog', 'failing']]);
  assert.deepEqual(pillState(KINDS, [], P).map((p) => p.state), ['missing', 'missing']);
  assert.deepEqual(pillState(null, rows, P), []);
});
test('C6 a row past its rotate-by date keeps its state and flags rotate', () => {
  const [s] = pillState([SENTRY], [row(P, 'sentry', { rotate_overdue: true })], P);
  assert.equal(s.state, 'set');
  assert.equal(s.rotate, true);
  assert.equal(pillState([SENTRY], [row(P, 'sentry')], P)[0].rotate, false);
});

// ------------------------------------------------------------------ S: the page

test('S1 a project with no row: each kind card says "Not set", one line and a visible Set button, no table', async () => {
  const { el, calls } = await mountPage();
  assert.equal(calls.filter((c) => c.method === 'GET' && c.url === `/api/coord/signal-keys?project=${P}`).length, 1, 'ONE list read');
  for (const k of KINDS) {
    const card = cardOf(el, k.kind);
    assert.ok(card, `${k.kind} card`);
    assert.match(text(card), /Not set/);
    const set = buttonIn(card, 'Set');
    assert.ok(set, `${k.kind} Set button`);
    assert.ok(!buttonIn(card, 'Clear'), 'no Clear without a row');
    assert.ok(!buttonIn(card, 'Test'), 'no Test without a row');
  }
  assert.equal(all(el).some((n) => n.localName === 'table'), false);
});

test('S2 a set card shows each non-secret field, who set it, the test result and its time', async () => {
  const { el } = await mountPage({ rows: [row(P, 'sentry')] });
  const t = text(cardOf(el, 'sentry'));
  for (const s of ['Organization slug', 'acme-fixture', 'Project slug', 'web-fixture', 'operator@example.com', '2026-11-18 09:00Z', 'ok', '2026-11-18 09:01Z']) {
    assert.ok(t.includes(s), `card shows ${s}: ${t}`);
  }
  assert.ok(buttonIn(cardOf(el, 'sentry'), 'Replace'));
  assert.match(text(cardOf(el, 'posthog')), /Not set/);
});

test('S3 no token-shaped string in the rendered page, also when a server error text carries one', async () => {
  const html = render(h(SignalsView, { project: P, list: { data: listOf([row(P, 'sentry'), row(P, 'posthog')]), loading: false, error: null } }));
  assert.ok(html.includes('acme-fixture'), 'the view rendered the row');
  assert.doesNotMatch(html, TOKEN_IN_HTML);
  const { el } = await mountPage({
    rows: [row(P, 'posthog')],
    test: () => [503, { error: `vendor said ${PH_KEY} was bad` }]
  });
  fire(buttonIn(cardOf(el, 'posthog'), 'Test'), 'click');
  await settle();
  assert.match(text(cardOf(el, 'posthog')), /vendor said/);
  assert.doesNotMatch(text(el), TOKEN_IN_HTML);
  assert.equal(isTokenShaped(`x ${PH_KEY}`), true);
  assert.equal(isTokenShaped('phx'), false);
  assert.equal(maskTokens(`a ${SENTRY_TOKEN} b`), `a ${SENTRY_P}*** b`);
});

test('S4 the warning pill follows rotate_overdue from the server; the date is the server rotate_by', async () => {
  const { el } = await mountPage({ rows: [row(P, 'sentry', { rotate_overdue: true, rotate_by: '2024-11-01T00:00:00Z' }), row(P, 'posthog')] });
  const s = cardOf(el, 'sentry');
  const pill = all(s).find((n) => n.attrs && (n.attrs.class || '').includes('signals__rotate'));
  assert.ok(pill, 'the overdue card has the warning pill');
  assert.match(pill.attrs.class, /tag--warn/);
  assert.match(text(s), /Rotate by 2024-11-01/);
  const p = cardOf(el, 'posthog');
  assert.equal(all(p).some((n) => n.attrs && (n.attrs.class || '').includes('signals__rotate')), false, 'no pill when not overdue');
  assert.match(text(p), /Rotate by 2099-02-16/);
});

test('S5 Clear: an in-app dialog titled "Clear the PostHog key of project-6-os"; Cancel sends nothing; Confirm sends one clear', async () => {
  const { el, calls } = await mountPage({ rows: [row(P, 'posthog')] });
  const card = cardOf(el, 'posthog');
  const clear = buttonIn(card, 'Clear');
  assert.notEqual(parentClass(clear), parentClass(buttonIn(card, 'Replace')), 'Clear is not in the Replace/Test group');
  assert.match(parentClass(clear), /signals__danger/);
  assert.match(clear.attrs.class, /\bbtn\b/);
  assert.doesNotMatch(clear.attrs.class, /btn--primary/);
  fire(clear, 'click');
  await settle();
  let dlg = dialogOf(el);
  assert.ok(dlg, 'a role=dialog opens (a native confirm would throw)');
  assert.equal(dlg.attrs['aria-label'], 'Clear the PostHog key of project-6-os');
  fire(buttonIn(dlg, 'CANCEL'), 'click');
  await settle();
  assert.ok(!dialogOf(el));
  assert.equal(posts(calls).length, 0, 'Cancel sends nothing');
  fire(buttonIn(cardOf(el, 'posthog'), 'Clear'), 'click');
  await settle();
  dlg = dialogOf(el);
  fire(confirmOf(dlg), 'click');
  await settle();
  assert.deepEqual(posts(calls).map((c) => [c.url, c.body]), [['/api/coord/signal-keys/clear', { project: P, kind: 'posthog' }]]);
  assert.match(text(cardOf(el, 'posthog')), /Not set/, 'the reloaded list says Not set');
});

test('S6 Test sends one test POST and shows the result and the reason', async () => {
  const { el, calls } = await mountPage({
    rows: [row(P, 'sentry')],
    test: () => [200, { ok: false, result: 'http_401', status: 401, reason: 'the key was refused', tested_at: '2026-11-20T10:00:05Z' }]
  });
  fire(buttonIn(cardOf(el, 'sentry'), 'Test'), 'click');
  await settle();
  assert.deepEqual(posts(calls).map((c) => [c.url, c.body]), [['/api/coord/signal-keys/test', { project: P, kind: 'sentry' }]]);
  assert.match(text(cardOf(el, 'sentry')), /Test: http_401 — the key was refused/);
});

test('S7 a refused write shows the owner line in the card and does not sign the user out', async () => {
  const refuse = () => [403, { error: 'signal-keys needs the operator token or the owner proof' }];
  const { el } = await mountPage({ rows: [row(P, 'sentry')], test: refuse });
  fire(buttonIn(cardOf(el, 'sentry'), 'Test'), 'click');
  await settle();
  assert.ok(text(cardOf(el, 'sentry')).includes(OWNER_LINE));
  assert.equal(OWNER_LINE, 'Only a fleet owner can change these keys.');
  assert.equal(events.includes('dash:unauthorized'), false);
  assert.ok(cardOf(el, 'sentry'), 'the page stays');
});

test('S8 one scope line per kind, from scope_note', async () => {
  const { el } = await mountPage();
  const lines = all(el).filter((n) => n.attrs && (n.attrs.class || '').split(/\s+/).includes('signals__scope')).map((n) => n.textContent.trim());
  assert.deepEqual(lines, KINDS.map((k) => k.scope_note));
});

test('S9 a 500 list read shows the ErrorBox with Retry and no "Not set"', async () => {
  let fail = true;
  const { el, calls } = await mountPage({ list: () => (fail ? [500, { error: 'd1 overloaded' }] : [200, listOf([])]) });
  assert.match(text(el), /could not load/);
  assert.doesNotMatch(text(el), /Not set/);
  fail = false;
  fire(buttonIn(el, 'RETRY'), 'click');
  await settle();
  assert.equal(calls.filter((c) => c.method === 'GET').length, 2);
  assert.match(text(el), /Not set/);
});

test('S10 the stylesheet is imported once, uses tokens only, and wraps at a phone width', () => {
  const css = readFileSync(new URL('../src/signals.css', import.meta.url), 'utf8');
  const main = readFileSync(new URL('../src/main.js', import.meta.url), 'utf8');
  assert.equal(main.split('\n').filter((l) => l.trim() === "import './signals.css';").length, 1);
  assert.doesNotMatch(css, /#[0-9a-fA-F]{3,8}\b/, 'no hex colour');
  assert.match(css, /\.signals__cards\s*\{[^}]*grid-template-columns:[^}]*minmax\(0/);
  assert.match(css, /overflow-wrap:\s*anywhere/);
  assert.match(css, /\.signals__actions\s*\{[^}]*flex-wrap:\s*wrap/);
  assert.doesNotMatch(css, /(^|[;{\s])(min-)?width:\s*\d{3,}px/m, 'no fixed or minimum page width (max-width is fine)');
});

// ------------------------------------------------------------------ K: the sheet

async function openSheet(kind, state = {}) {
  const page = await mountPage(state);
  const card = cardOf(page.el, kind);
  const opener = buttonIn(card, 'Replace') || buttonIn(card, 'Set');
  fire(opener, 'click');
  await settle();
  const dlg = dialogOf(page.el);
  assert.ok(dlg, 'the sheet opens as a role=dialog');
  return { ...page, dlg, opener };
}

test('K1 each input has a visible label above it and the format placeholder', async () => {
  const { dlg } = await openSheet('posthog');
  for (const f of POSTHOG.fields) {
    const input = inputNamed(dlg, f.name);
    assert.ok(input, f.name);
    const label = all(dlg).find((n) => n.localName === 'label' && n.attrs.for === input.attrs.id);
    assert.ok(label, `a <label for> for ${f.name}`);
    assert.equal(label.textContent.trim(), f.label);
    const kids = input.parentNode.childNodes.filter((c) => c.nodeType === 1);
    assert.ok(kids.indexOf(label) >= 0 && kids.indexOf(label) < kids.indexOf(input), `the label sits above ${f.name}`);
    assert.equal(input.attrs.placeholder, f.placeholder);
  }
  assert.match(text(dlg), /Set the PostHog key of project-6-os/);
});

test('K2 Replace fills the non-secret fields from the row; the secret is an empty password input', async () => {
  const { dlg } = await openSheet('sentry', { rows: [row(P, 'sentry')] });
  assert.equal(valueOf(inputNamed(dlg, 'org')), 'acme-fixture');
  assert.equal(valueOf(inputNamed(dlg, 'project')), 'web-fixture');
  const secret = inputNamed(dlg, 'token');
  assert.equal(valueOf(secret), '');
  assert.equal(secret.attrs.type, 'password');
  assert.equal(secret.attrs.autocomplete, 'off');
  assert.equal(inputNamed(dlg, 'org').attrs.type, 'text');
});

const typeIn = (input, v) => { input.value = v; fire(input, 'input', { currentTarget: input, target: input }); };

test('K3 a pasted key with a trailing CRLF is sent trimmed', async () => {
  const { el, dlg, calls } = await openSheet('posthog');
  typeIn(inputNamed(dlg, 'host'), 'https://us.posthog.com');
  typeIn(inputNamed(dlg, 'project_id'), ' 4242 ');
  const key = inputNamed(dlg, 'key');
  fire(key, 'paste', { clipboardData: { getData: () => `  ${PH_KEY}\r\n` }, currentTarget: key, target: key });
  await settle();
  assert.equal(valueOf(key), PH_KEY, 'the paste lands trimmed in the field');
  fire(buttonIn(dialogOf(el), 'Save'), 'click');
  await settle();
  const set = posts(calls).find((c) => c.url === '/api/coord/signal-keys/set');
  assert.ok(set, 'a set POST');
  assert.equal(set.body.fields.key, PH_KEY);
  assert.equal(set.body.fields.project_id, '4242');
});

test('K4 a blur on a wrong-prefix key shows the error under the field, keeps the value, and Save sends nothing', async () => {
  const { el, dlg, calls } = await openSheet('posthog');
  const bad = ['ph', 'c_fixture0123'].join('');
  const key = inputNamed(dlg, 'key');
  typeIn(key, bad);
  fire(key, 'blur', { currentTarget: key, target: key });
  await settle();
  const err = all(dialogOf(el)).find((n) => n.attrs && n.attrs.id === `${key.attrs.id}-err`);
  assert.ok(err, 'an error node under the field');
  assert.equal(err.textContent.trim(), `Personal API key must start with ${PH_P}`);
  assert.equal(key.attrs['aria-invalid'], 'true');
  assert.equal(valueOf(inputNamed(dialogOf(el), 'key')), bad, 'the typed value stays');
  fire(buttonIn(dialogOf(el), 'Save'), 'click');
  await settle();
  assert.equal(posts(calls).length, 0, 'Save sends 0 POSTs');
  assert.match(text(dialogOf(el)), /Host is required/);
});

async function fillPosthog(dlg) {
  typeIn(inputNamed(dlg, 'host'), 'https://us.posthog.com');
  typeIn(inputNamed(dlg, 'project_id'), '4242');
  typeIn(inputNamed(dlg, 'key'), PH_KEY);
}

test('K5 a good save sends set then test, in that order, and shows the test result', async () => {
  const ok = await openSheet('posthog');
  await fillPosthog(ok.dlg);
  fire(buttonIn(dialogOf(ok.el), 'Save'), 'click');
  await settle();
  assert.deepEqual(posts(ok.calls).map((c) => c.url), ['/api/coord/signal-keys/set', '/api/coord/signal-keys/test']);
  assert.deepEqual(posts(ok.calls)[1].body, { project: P, kind: 'posthog' });
  assert.match(text(dialogOf(ok.el)), /Saved\. Test: ok/);
  for (const r of mounted) mount(null, r);
  mounted.clear();

  const bad = await openSheet('posthog', { test: () => [200, { ok: false, result: 'http_401', status: 401, reason: 'the key was refused', tested_at: 'x' }] });
  await fillPosthog(bad.dlg);
  fire(buttonIn(dialogOf(bad.el), 'Save'), 'click');
  await settle();
  const t = text(dialogOf(bad.el));
  assert.match(t, /Saved\. Test: http_401 — the key was refused/);
  assert.doesNotMatch(t, /Test: ok/);
});

test('K6 a server 400 with field shows under that field and keeps every value; a refused set shows the owner line', async () => {
  const { el, dlg, calls } = await openSheet('posthog', { set: () => [400, { error: 'Host must be one of https://us.posthog.com', field: 'host' }] });
  await fillPosthog(dlg);
  fire(buttonIn(dialogOf(el), 'Save'), 'click');
  await settle();
  const d = dialogOf(el);
  const host = inputNamed(d, 'host');
  const err = all(d).find((n) => n.attrs && n.attrs.id === `${host.attrs.id}-err`);
  assert.equal(err && err.textContent.trim(), 'Host must be one of https://us.posthog.com');
  assert.equal(valueOf(inputNamed(d, 'key')), PH_KEY, 'the typed key stays for a retry');
  assert.equal(valueOf(host), 'https://us.posthog.com');
  assert.equal(posts(calls).length, 1, 'no test after a failed set');
  for (const r of mounted) mount(null, r);
  mounted.clear();

  const ref = await openSheet('posthog', { set: () => [403, { error: 'signal-keys needs the operator token or the owner proof' }] });
  await fillPosthog(ref.dlg);
  fire(buttonIn(dialogOf(ref.el), 'Save'), 'click');
  await settle();
  assert.ok(text(dialogOf(ref.el)).includes(OWNER_LINE));
  assert.equal(events.includes('dash:unauthorized'), false);
});

const holdsKey = (root) => all(root).some((n) => [n.data, n.value, ...Object.values(n.attrs || {})]
  .some((v) => typeof v === 'string' && v.includes(PH_KEY)));

test('K7 after a save the secret leaves the field, and after close no node holds the typed key', async () => {
  const { el, dlg } = await openSheet('posthog');
  await fillPosthog(dlg);
  assert.ok(holdsKey(el), 'control: the typed key is in the field before Save');
  fire(buttonIn(dialogOf(el), 'Save'), 'click');
  await settle();
  assert.equal(valueOf(inputNamed(dialogOf(el), 'key')), '', 'the secret field is empty after the save');
  assert.equal(holdsKey(el), false);
  fire(buttonIn(dialogOf(el), 'Done'), 'click');
  await settle();
  assert.ok(!dialogOf(el), 'the sheet closed');
  assert.equal(holdsKey(el), false);
  assert.match(text(cardOf(el, 'posthog')), /Replace/, 'the page reloaded its list on close');
});

test('K8 Escape closes the sheet and focus returns to the opener; the scrim closes it too', async () => {
  const { el, doc, opener } = await openSheet('sentry', { rows: [row(P, 'sentry')] });
  assert.equal(doc.activeElement && doc.activeElement.localName, 'input', 'focus starts in the first field');
  fire(doc, 'keydown', { key: 'Escape' });
  await settle();
  assert.ok(!dialogOf(el));
  assert.ok(doc.activeElement === opener, 'focus is back on Replace');
  fire(buttonIn(cardOf(el, 'sentry'), 'Replace'), 'click');
  await settle();
  const scrim = dialogOf(el).parentNode;
  fire(scrim, 'click', { target: scrim, currentTarget: scrim });
  await settle();
  assert.ok(!dialogOf(el));
});

// ------------------------------------------------------------------ E: entry point

test('E1 the settings menu row "Signals" opens the page through the real router, and it reads the list', async () => {
  const item = findItem(SETTINGS_MENU, 'project', 'signals');
  assert.ok(item && !item.tag, 'a built project row');
  assert.equal(item.label, 'Signals');
  assert.equal(SETTINGS_SCREENS.signals, SignalsScreen);
  const doc = installDom();
  setUrl(`/settings/p/${P}`);
  const { calls } = signalFake({ rows: [row(P, 'sentry')] });
  const el = doc.createElement('div');
  mounted.add(el);
  mount(h(App), el);
  await settle();
  const link = all(el).find((n) => n.localName === 'a' && n.attrs.href === `/settings/p/${P}/signals`);
  assert.ok(link, 'the menu row links to the page');
  assert.equal(link.textContent.trim(), 'Signals');
  fire(link, 'click');
  await settle();
  assert.equal(window.location.pathname, `/settings/p/${P}/signals`);
  assert.ok(calls.some((c) => c.method === 'GET' && c.url === `/api/coord/signal-keys?project=${P}`), 'the page made the list read');
  assert.ok(cardOf(el, 'sentry'), 'the Signals page is mounted in the shell');
  assert.ok(buttonIn(cardOf(el, 'sentry'), 'Replace'));
});

// ------------------------------------------------------------------ F: the Fleet column

const fleetRow = (project) => ({ project, last_run_age_min: 1, last_summary: 'ok', last_rc: 0, open_alerts: 0, open_prs: 0 });
const FLEET_LIST = listOf([
  row('a', 'sentry'), row('a', 'posthog', { last_test_result: 'http_401' }),
  row('c', 'sentry', { last_test_at: null, last_test_status: null, last_test_result: null })
]);

function fleetDom(props) {
  const doc = installDom();
  const el = doc.createElement('div');
  mounted.add(el);
  mount(h(ProjectsTable, { rows: ['a', 'b', 'c'].map(fleetRow), recentRuns: {}, ...props }), el);
  return el;
}
const thIndex = (el, label) => all(el).filter((n) => n.localName === 'th').findIndex((n) => n.textContent.replace(/[↑↓]/g, '').trim().startsWith(label));
const bodyRows = (el) => rowsOf(el).filter((tr) => tr.parentNode && tr.parentNode.localName === 'tbody');
const cellIn = (tr, i) => tr.childNodes.filter((c) => c.localName === 'td')[i];
const projectOfRow = (tr) => cellIn(tr, 0).textContent.trim();
const signalCell = (el, project) => {
  const i = thIndex(el, 'SIGNALS');
  assert.ok(i >= 0, 'a SIGNALS header');
  return cellIn(bodyRows(el).find((tr) => projectOfRow(tr) === project), i);
};
const pillsOf = (cell) => all(cell).filter((n) => n.localName === 'a').map((a) => [a.textContent.trim(), a.attrs.href]);

test('F1 the pills say set, missing or failing per project and kind', async () => {
  const el = fleetDom({ signals: FLEET_LIST });
  await flush();
  assert.deepEqual(pillsOf(signalCell(el, 'a')).map((p) => p[0]), ['sentry set', 'posthog failing']);
  assert.deepEqual(pillsOf(signalCell(el, 'b')).map((p) => p[0]), ['sentry missing', 'posthog missing']);
  assert.deepEqual(pillsOf(signalCell(el, 'c')).map((p) => p[0]), ['sentry set', 'posthog missing']);
  const failing = all(signalCell(el, 'a')).find((n) => n.localName === 'a' && n.textContent.trim() === 'posthog failing');
  assert.match(failing.attrs.class, /tag--bad/);
});

test('F2 each pill links to the project Signals page', async () => {
  const el = fleetDom({ signals: FLEET_LIST });
  await flush();
  for (const p of ['a', 'b', 'c']) {
    for (const [, href] of pillsOf(signalCell(el, p))) assert.equal(href, `/settings/p/${p}/signals`);
  }
});

test('F3 the SIGNALS header has aria-sort and sorts asc then desc by the count of kinds not set', async () => {
  const el = fleetDom({ signals: FLEET_LIST });
  await flush();
  const th = () => all(el).filter((n) => n.localName === 'th')[thIndex(el, 'SIGNALS')];
  assert.equal(th().attrs['aria-sort'], 'none');
  fire(all(th()).find((n) => n.localName === 'button'), 'click');
  await flush();
  assert.equal(th().attrs['aria-sort'], 'ascending');
  const asc = bodyRows(el).map(projectOfRow);
  assert.equal(asc[asc.length - 1], 'b', 'b has two kinds not set: last ascending');
  assert.deepEqual(asc.slice(0, 2).sort(), ['a', 'c']);
  fire(all(th()).find((n) => n.localName === 'button'), 'click');
  await flush();
  assert.equal(th().attrs['aria-sort'], 'descending');
  assert.equal(bodyRows(el).map(projectOfRow)[0], 'b');
});

test('F4 without the prop the cell is "—" with a title; while loading it is "…"', async () => {
  const el = fleetDom({});
  await flush();
  const c = signalCell(el, 'a');
  assert.equal(c.textContent.trim(), '—');
  assert.ok(all(c).some((n) => n.attrs && n.attrs.title === 'signal keys not readable'));
  const el2 = fleetDom({ signalsLoading: true });
  await flush();
  assert.equal(signalCell(el2, 'a').textContent.trim(), '…');
  const el3 = fleetDom({ signals: {} });
  await flush();
  assert.equal(signalCell(el3, 'a').textContent.trim(), '—', 'an answer with no kinds list is not readable');
});

test('F5 the real FleetScreen reads the list once, with no project, and renders the pills from it', async () => {
  const doc = installDom();
  const calls = routedFetch((u) => {
    if (u === '/api/dash/projects') return [200, { projects: ['a', 'b'].map(fleetRow), projects_source: 'fleet_status', snapshot_age_min: 1 }];
    if (u === '/api/coord/signal-keys') return [200, FLEET_LIST];
    return [200, {}];
  });
  const el = doc.createElement('div');
  mounted.add(el);
  mount(h(FleetContext.Provider, { value: { data: null } }, h(FleetScreen)), el);
  await settle();
  assert.equal(calls.filter((c) => c.url.startsWith('/api/coord/signal-keys')).length, 1, 'one read per mount');
  assert.equal(calls.find((c) => c.url.startsWith('/api/coord/signal-keys')).url, '/api/coord/signal-keys');
  assert.deepEqual(pillsOf(signalCell(el, 'a')).map((p) => p[0]), ['sentry set', 'posthog failing']);
});
