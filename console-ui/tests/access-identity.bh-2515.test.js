import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { onRequest as coord } from '../functions/api/coord/[[path]].js';
import { onRequest as dash } from '../functions/api/[[path]].js';
import { resolveIdentity, _resetCertsCache } from '../functions/_lib/access-identity.js';
import { identityPill } from '../src/lib/identity.js';
import { TopBar } from '../src/app.js';

// BH-2515: a console write names the human who made it. The Pages functions
// read Cf-Access-Authenticated-User-Email, but only trust it when the request
// also carries a Cf-Access-Jwt-Assertion that verifies against the team's
// certs, for this AUD and issuer, with the same email in its claim. Otherwise
// the actor is 'console', and the top bar says why.
//
// Everything below goes through the real onRequest of both functions. The RSA
// key is generated here and its public half is served from a stubbed certs URL.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
const TEAM = 'team.example.cloudflareaccess.com';
const CERTS = `https://${TEAM}/cdn-cgi/access/certs`;
const AUD = 'test-aud';
const SECRET = 'test-harness-secret';
const ENV_ON = { HARNESS_SECRET: SECRET, CF_ACCESS_TEAM_DOMAIN: TEAM, CF_ACCESS_AUD: AUD };
const ENV_OFF = { HARNESS_SECRET: SECRET };

const b64u = (bytes) => Buffer.from(bytes).toString('base64url');
const enc = (obj) => b64u(Buffer.from(JSON.stringify(obj)));

async function rsaKey() {
  return crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true, ['sign', 'verify']);
}
const KEY = await rsaKey();
const OTHER = await rsaKey();
const KID = 'kid-1';
const JWK = { ...(await crypto.subtle.exportKey('jwk', KEY.publicKey)), kid: KID, alg: 'RS256', use: 'sig' };

// determinism: ok-file clock-now-js the one clock read is NOW below, captured
// once at load. Every exp/iat and every resolveIdentity time is an OFFSET from
// it (the verifier checks exp against the real clock, so the anchor must be
// real); no case asserts a calendar date.
const NOW = Date.now();
const nowS = () => Math.floor(NOW / 1000);
function claims(over = {}) {
  return { aud: [AUD], iss: `https://${TEAM}`, email: 'operator@example.com', exp: nowS() + 600, iat: nowS() - 5, sub: 'u1', ...over };
}
async function jwt(payload = claims(), { key = KEY.privateKey, header = { alg: 'RS256', kid: KID, typ: 'JWT' } } = {}) {
  const input = `${enc(header)}.${enc(payload)}`;
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(input));
  return `${input}.${b64u(new Uint8Array(sig))}`;
}
// alg:HS256 with the RSA public key's JSON as the HMAC secret: the classic
// algorithm-confusion forgery. It must never verify.
async function hsJwt(payload = claims()) {
  const header = { alg: 'HS256', kid: KID, typ: 'JWT' };
  const input = `${enc(header)}.${enc(payload)}`;
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(JSON.stringify(JWK)),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(input));
  return `${input}.${b64u(new Uint8Array(sig))}`;
}

// One stub for every upstream: the console session probe, the certs document,
// the jobs worker (a routing GET answers a row), and the console worker.
function stub({ certsStatus = 200 } = {}) {
  const jobs = []; const consoleCalls = []; const certs = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const url = typeof input === 'string' ? input : input.url;
    if (url === CERTS) {
      certs.push(url);
      if (certsStatus !== 200) return new Response('nope', { status: certsStatus });
      return new Response(JSON.stringify({ keys: [JWK] }), { status: 200, headers: { 'content-type': 'application/json' } });
    }
    if (url === `${CONSOLE}/api/dash/fleet` && !init.method) return new Response('{}', { status: 200 });
    if (url.startsWith(CONSOLE)) {
      const body = init.body == null ? null : Buffer.from(init.body).toString('utf8');
      consoleCalls.push({ url, method: init.method, headers: init.headers, body });
      return new Response('{"ok":true}', { status: 200, headers: { 'content-type': 'application/json' } });
    }
    if (url.startsWith(JOBS)) {
      jobs.push({ url, method: init.method, body: init.body });
      if (init.method === 'GET' && url.startsWith(`${JOBS}/api/routing/`)) {
        return new Response(JSON.stringify({ routing: { project: 'project-3', builder: 'box', pool_app: null, halted: 0, updated_at: '2026-09-25 10:00:00' } }), { status: 200 });
      }
      return new Response('{"ok":true}', { status: 200, headers: { 'content-type': 'application/json' } });
    }
    throw new Error(`unexpected fetch ${url}`);
  };
  return { jobs, consoleCalls, certs, restore: () => { globalThis.fetch = real; } };
}

let seq = 0;
function coordCall(rest, { method = 'GET', body = null, search = '', env = ENV_ON, headers = {} } = {}) {
  return coord({
    request: new Request(`https://mc.example.com/api/coord/${rest}${search}`, {
      method,
      headers: { cookie: `dash=ident${++seq}`, 'content-type': 'application/json', ...headers },
      body: body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body))
    }),
    env,
    params: { path: rest.split('/').filter(Boolean) }
  });
}
function dashCall(path, { method = 'GET', body = null, env = ENV_ON, headers = {} } = {}) {
  return dash({
    request: new Request(`https://mc.example.com${path}`, {
      method, headers: { cookie: 'dash=x', 'content-type': 'application/json', ...headers },
      body: body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body))
    }),
    env, params: {}
  });
}
async function accessHeaders(email = 'OPERATOR@example.com ', token) {
  return { 'cf-access-authenticated-user-email': email, 'cf-access-jwt-assertion': token ?? await jwt() };
}
async function whoami(opts) {
  const s = stub(opts?.stub);
  try {
    const res = await coordCall('whoami', opts);
    return { status: res.status, body: await res.json(), jobs: s.jobs.length };
  } finally { s.restore(); }
}

test.beforeEach(() => _resetCertsCache());

// --- A: identity -------------------------------------------------------------

test('A1 a verified assertion whose claim matches the header (case-insensitively) names the email', async () => {
  const r = await whoami({ headers: await accessHeaders() });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { actor: 'operator@example.com', access: 'on', email: 'operator@example.com' });
});

test('A2 Access env unset: the header alone is ignored, actor console, access off', async () => {
  const r = await whoami({ env: ENV_OFF, headers: await accessHeaders() });
  assert.deepEqual(r.body, { actor: 'console', access: 'off', email: null });
  // only one of the two vars is still off
  const one = await whoami({ env: { HARNESS_SECRET: SECRET, CF_ACCESS_TEAM_DOMAIN: TEAM }, headers: await accessHeaders() });
  assert.equal(one.body.access, 'off');
  assert.equal(one.body.actor, 'console');
});

test('A3 A4 A5 A7 A8 A9 a missing, foreign-signed, expired, wrong-aud, wrong-iss, alg none or HS256 assertion is unverified', async () => {
  const cases = {
    'no assertion': { 'cf-access-authenticated-user-email': 'operator@example.com' },
    'other key': await accessHeaders('operator@example.com', await jwt(claims(), { key: OTHER.privateKey })),
    expired: await accessHeaders('operator@example.com', await jwt(claims({ exp: nowS() - 120 }))),
    'wrong aud': await accessHeaders('operator@example.com', await jwt(claims({ aud: ['someone-else'] }))),
    'wrong iss': await accessHeaders('operator@example.com', await jwt(claims({ iss: 'https://attacker.cloudflareaccess.com' }))),
    'alg none': await accessHeaders('operator@example.com',
      `${enc({ alg: 'none', kid: KID })}.${enc(claims())}.`),
    'alg HS256': await accessHeaders('operator@example.com', await hsJwt()),
    // a genuine RS256 signature under a header that names another alg: only
    // the explicit RS256 check refuses this one
    'alg none, RS-signed': await accessHeaders('operator@example.com', await jwt(claims(), { header: { alg: 'none', kid: KID } })),
    garbage: await accessHeaders('operator@example.com', 'not.a.jwt')
  };
  for (const [name, headers] of Object.entries(cases)) {
    const r = await whoami({ headers });
    assert.deepEqual(r.body, { actor: 'console', access: 'unverified', email: null }, name);
  }
});

test('A6 a claim that names someone other than the header is unverified', async () => {
  const r = await whoami({ headers: await accessHeaders('operator@example.com', await jwt(claims({ email: 'mallory@x.com' }))) });
  assert.deepEqual(r.body, { actor: 'console', access: 'unverified', email: null });
  const noHeader = await whoami({ headers: { 'cf-access-jwt-assertion': await jwt() } });
  assert.equal(noHeader.body.access, 'unverified');
});

test('A10 certs unreachable is unverified; after the backoff a good fetch verifies', async () => {
  const token = await jwt();
  const req = () => new Request('https://mc.example.com/x', { headers: {
    'cf-access-authenticated-user-email': 'operator@example.com', 'cf-access-jwt-assertion': token } });
  const t0 = NOW;
  let s = stub({ stub: undefined, certsStatus: 500 });
  try {
    assert.deepEqual(await resolveIdentity(req(), ENV_ON, t0), { actor: 'console', access: 'unverified', email: null });
  } finally { s.restore(); }
  s = stub();
  try {
    // inside the backoff: no refetch, still unverified
    assert.equal((await resolveIdentity(req(), ENV_ON, t0 + 10000)).access, 'unverified');
    assert.equal(s.certs.length, 0, 'no refetch inside the 60 s backoff');
    const later = await resolveIdentity(req(), ENV_ON, t0 + 61000);
    assert.deepEqual(later, { actor: 'operator@example.com', access: 'on', email: 'operator@example.com' });
    assert.equal(s.certs.length, 1);
    // cached: a second verify does not refetch
    await resolveIdentity(req(), ENV_ON, t0 + 62000);
    assert.equal(s.certs.length, 1, 'certs are cached');
  } finally { s.restore(); }
});

test('A11 a verified email outside the worker actor charset records console and says unrecordable', async () => {
  const token = await jwt(claims({ email: 'a+b@example.com' }));
  const r = await whoami({ headers: await accessHeaders('a+b@example.com', token) });
  assert.deepEqual(r.body, { actor: 'console', access: 'unrecordable', email: 'a+b@example.com' });
});

// --- C: coord writes ---------------------------------------------------------

const WRITES = [
  ['PUT', 'flags', { name: 'paused-project-3', active: 1, actor: 'mallory' }],
  ['PUT', 'settings', { key: 'lane.x.y', value: 1, actor: 'mallory' }],
  ['PUT', 'model-routes', { role: 'plan', actor: 'mallory' }],
  ['PUT', 'routing', { project: 'project-3', halted: 1, reason: 'r', actor: 'mallory' }],
  ['POST', 'lanes/all-off', { actor: 'mallory' }],
  ['POST', 'lanes/all-on', { actor: 'mallory' }],
  ['POST', 'model-routes/reset', { role: 'plan', actor: 'mallory' }],
  ['POST', 'hub/promote', { confirm: true, actor: 'mallory' }],
  ['POST', 'hub/restore-lab', { confirm: true, actor: 'mallory' }],
  ['POST', 'alerts/actions', { id: 1, action: 'ack', actor: 'mallory' }],
  ['POST', 'jobs/j1/retry', { detail: 'd', actor: 'mallory' }],
  ['POST', 'jobs/j1/requeue', { detail: 'd', actor: 'mallory' }],
  ['POST', 'main-red/clear', { name: 'n', reason: 'r', sha: 's', actor: 'mallory' }]
];

test('C1 every admitted PUT and POST forwards the verified email as actor, over the browser value', async () => {
  for (const [method, rest, body] of WRITES) {
    const s = stub();
    try {
      const res = await coordCall(rest, { method, body, headers: await accessHeaders() });
      assert.equal(res.status, 200, `${method} ${rest}`);
      const w = s.jobs.filter((c) => c.method === method);
      assert.equal(w.length, 1, `${method} ${rest}`);
      assert.equal(JSON.parse(w[0].body).actor, 'operator@example.com', `${method} ${rest}`);
    } finally { s.restore(); }
  }
});

test('C2 the call-guard DELETE stamps the verified email in the query, over ?actor=', async () => {
  const s = stub();
  try {
    const res = await coordCall('call-guard', { method: 'DELETE', search: '?project=p&reason=r&actor=mallory', headers: await accessHeaders() });
    assert.equal(res.status, 200);
    assert.deepEqual(new URL(s.jobs[0].url).searchParams.getAll('actor'), ['operator@example.com']);
  } finally { s.restore(); }
});

test('C3 with Access off every write records console, even when the browser sends an email', async () => {
  for (const [method, rest, body] of WRITES) {
    const s = stub();
    try {
      const res = await coordCall(rest, { method, env: ENV_OFF, body: { ...body, actor: 'operator@example.com' }, headers: await accessHeaders() });
      assert.equal(res.status, 200, `${method} ${rest}`);
      const w = s.jobs.filter((c) => c.method === method);
      assert.equal(JSON.parse(w[0].body).actor, 'console', `${method} ${rest}`);
    } finally { s.restore(); }
  }
  const s = stub();
  try {
    await coordCall('call-guard', { method: 'DELETE', env: ENV_OFF, search: '?project=p&reason=r&actor=operator@example.com', headers: await accessHeaders() });
    assert.deepEqual(new URL(s.jobs[0].url).searchParams.getAll('actor'), ['console']);
  } finally { s.restore(); }
});

test('C7 with a verified identity every narrowed row forwards exactly its main shape; only the actor differs', async () => {
  const extra = { actor: 'mallory', max_attempts: 99, builder: 'evil', expected_updated_at: 'forged' };
  const cases = [
    ['POST', 'jobs/j1/retry', { detail: 'd', ...extra }, { detail: 'd', actor: 'operator@example.com' }],
    ['POST', 'jobs/j1/requeue', { detail: 7, ...extra }, { actor: 'operator@example.com' }],
    ['POST', 'jobs/j1/abandon', { reason: 'r', detail: 'd', ...extra }, { reason: 'r', actor: 'operator@example.com' }],
    ['POST', 'main-red/clear', { sha: 's', name: 'n', reason: 'r', ...extra }, { name: 'n', reason: 'r', sha: 's', actor: 'operator@example.com' }],
    ['POST', 'alerts/actions', { id: 3, action: 'ack', ...extra }, { id: 3, action: 'ack', actor: 'operator@example.com' }],
    ['PUT', 'routing', { project: 'project-3', halted: 1, reason: 'r', ...extra },
      { project: 'project-3', builder: 'box', pool_app: null, halted: 1, reason: 'r', expected_updated_at: '2026-09-25 10:00:00', actor: 'operator@example.com' }]
  ];
  for (const [method, rest, body, want] of cases) {
    const s = stub();
    try {
      const res = await coordCall(rest, { method, body, headers: await accessHeaders() });
      assert.equal(res.status, 200, `${method} ${rest}`);
      const w = s.jobs.filter((c) => c.method === method);
      assert.equal(w.length, 1, `${method} ${rest}`);
      assert.deepEqual(JSON.parse(w[0].body), want, `${method} ${rest}`);
    } finally { s.restore(); }
  }
  // The call-guard DELETE keeps its query allowlist; a blank reason is still a 400.
  const s = stub();
  try {
    const res = await coordCall('call-guard', { method: 'DELETE', search: '?project=p&stage=x&reason=r&junk=1', headers: await accessHeaders() });
    assert.equal(res.status, 200);
    assert.equal(new URL(s.jobs[0].url).search, '?project=p&stage=x&reason=r&actor=operator%40example.com');
    const bad = await coordCall('call-guard', { method: 'DELETE', search: '?project=p&reason=%20', headers: await accessHeaders() });
    assert.equal(bad.status, 400);
    assert.equal(s.jobs.length, 1);
  } finally { s.restore(); }
});

test('C4 a GET is forwarded unchanged and pays no certs fetch', async () => {
  const s = stub();
  try {
    const res = await coordCall('jobs', { search: '?limit=5', headers: await accessHeaders() });
    assert.equal(res.status, 200);
    assert.equal(s.jobs.length, 1);
    assert.equal(s.jobs[0].url, `${JOBS}/api/jobs?limit=5`);
    assert.equal(s.jobs[0].body, undefined);
    assert.equal(s.certs.length, 0);
  } finally { s.restore(); }
});

test('C5 whoami is answered locally, never forwarded to the jobs worker', async () => {
  const r = await whoami({ headers: await accessHeaders() });
  assert.equal(r.jobs, 0);
  // and it is still behind the session check
  const real = globalThis.fetch;
  globalThis.fetch = async () => new Response('', { status: 403 });
  try {
    const res = await coordCall('whoami');
    assert.equal(res.status, 403);
  } finally { globalThis.fetch = real; }
});

test('C6 a PUT settings with an array body is a 400 and sends nothing upstream', async () => {
  const s = stub();
  try {
    const res = await coordCall('settings', { method: 'PUT', body: [{ key: 'k', actor: 'x' }], headers: await accessHeaders() });
    assert.equal(res.status, 400);
    assert.equal(s.jobs.length, 0);
  } finally { s.restore(); }
});

// --- D: commands -------------------------------------------------------------

test('D1 POST /api/dash/action carries the verified email as actor, over the browser value', async () => {
  const s = stub();
  try {
    const sent = { type: 'pause_set', project: 'project-3', what: 'merges', reason: 'x', actor: 'mallory' };
    const res = await dashCall('/api/dash/action', { method: 'POST', body: sent, headers: await accessHeaders() });
    assert.equal(res.status, 200);
    assert.equal(s.consoleCalls.length, 1);
    assert.equal(s.consoleCalls[0].url, `${CONSOLE}/api/dash/action`);
    assert.deepEqual(JSON.parse(s.consoleCalls[0].body), { ...sent, actor: 'operator@example.com' });
  } finally { s.restore(); }
});

test('D2 with Access off a command records console', async () => {
  const s = stub();
  try {
    await dashCall('/api/dash/action', { method: 'POST', env: {}, body: { type: 'pause_board', project: 'p', reason: 'r', actor: 'operator@example.com' }, headers: await accessHeaders() });
    assert.equal(JSON.parse(s.consoleCalls[0].body).actor, 'console');
  } finally { s.restore(); }
});

test('D3 chat and GET fleet pass through unchanged', async () => {
  const s = stub();
  try {
    const raw = '{"text":"hi","actor":"mallory"}';
    await dashCall('/api/dash/chat', { method: 'POST', body: raw, headers: await accessHeaders() });
    assert.equal(s.consoleCalls[0].body, raw);
    await dashCall('/api/dash/fleet?x=1', { method: 'GET', headers: { 'x-probe': '1' } });
    assert.equal(s.consoleCalls[1].url, `${CONSOLE}/api/dash/fleet?x=1`);
    assert.equal(s.consoleCalls[1].body, null);
    assert.equal(s.certs.length, 0);
  } finally { s.restore(); }
});

test('D4 an array or non-JSON body to /api/dash/action is a 400 and sends nothing', async () => {
  for (const body of ['[{"type":"pause_board"}]', 'not json']) {
    const s = stub();
    try {
      const res = await dashCall('/api/dash/action', { method: 'POST', body, headers: await accessHeaders() });
      assert.equal(res.status, 400);
      assert.equal(s.consoleCalls.length, 0);
    } finally { s.restore(); }
  }
});

// --- U: the top bar says who writes -----------------------------------------

test('U1 on: the pill is the email, ok tone', () => {
  assert.deepEqual(identityPill({ actor: 'operator@example.com', access: 'on', email: 'operator@example.com' }, null),
    { text: 'operator@example.com', tone: 'ok', title: 'Settings, routing, job, alert and hub writes you make here are recorded as operator@example.com. Pause and resume commands are the exception: they are recorded as console' });
});
test('U2 off: says Access is off and writes as console', () => {
  const p = identityPill({ actor: 'console', access: 'off', email: null }, null);
  assert.equal(p.text, 'ACCESS OFF · writes as console');
  assert.equal(p.tone, 'warn');
  assert.match(p.title, /not configured/);
});
test('U3 unverified', () => {
  const p = identityPill({ actor: 'console', access: 'unverified', email: null }, null);
  assert.equal(p.text, 'IDENTITY UNVERIFIED · writes as console');
  assert.equal(p.tone, 'warn');
});
test('U4 unrecordable', () => {
  const p = identityPill({ actor: 'console', access: 'unrecordable', email: 'a+b@example.com' }, null);
  assert.equal(p.text, 'a+b@example.com · recorded as console');
  assert.equal(p.tone, 'warn');
});
test('U5 a failed read is unknown, never off; loading is not off either', () => {
  const p = identityPill(null, new Error('http_500'));
  assert.equal(p.text, 'identity unknown');
  assert.equal(p.tone, 'warn');
  assert.doesNotMatch(identityPill(null, null).text, /OFF|console/);
  assert.equal(identityPill({ access: 'weird' }, null).text, 'identity unknown');
});
test('U6 the real TopBar renders the identity pill', () => {
  const base = { path: '/', snap: { snapshot_age_min: 1 }, openAlerts: 0, loading: false, secondsLeft: 5, watchdogDown: false };
  const off = render(h(TopBar, { ...base, identity: { data: { actor: 'console', access: 'off', email: null }, error: null } }));
  assert.match(off, /ACCESS OFF · writes as console/);
  assert.match(off, /<span class="pill pill--warn"[^>]*title="Cloudflare Access is not configured[^"]*"[^>]*>ACCESS OFF · writes as console<\/span>/);
  const on = render(h(TopBar, { ...base, identity: { data: { actor: 'operator@example.com', access: 'on', email: 'operator@example.com' }, error: null } }));
  assert.match(on, /<span class="pill"[^>]*>operator@example\.com<\/span>/);
  assert.doesNotMatch(on, /ACCESS OFF/);
});
