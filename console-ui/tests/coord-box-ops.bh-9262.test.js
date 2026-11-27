import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { onRequest as coord } from '../functions/api/coord/[[path]].js';
import { _resetCertsCache } from '../functions/_lib/access-identity.js';
import { boxOpsHeaders } from '../functions/_lib/box-ops-proof.js';

// BH-9262 (C0): Pages forwards the box-ops proof (x-box-ops-token and
// x-box-ops-identity) only on rows flagged `boxOps: true`, and only when
// Cloudflare Access verified the operator's identity. HUMAN_VERDICT_TOKEN never
// goes to Pages: no file under console-ui/functions reads it.
//
// The cases drive the REAL onRequest. The Access JWT is signed here with a
// generated RSA key whose public half a stubbed certs URL serves (the
// access-identity.bh-2515 pattern): 0 network calls.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
const TEAM = 'team.example.cloudflareaccess.com';
const CERTS = `https://${TEAM}/cdn-cgi/access/certs`;
const AUD = 'test-aud-9262';
const SECRET = 'test-harness-secret-9262';
const BOX = 'box-ops-token-fixture-9262';
const ENV_ON = { HARNESS_SECRET: SECRET, CF_ACCESS_TEAM_DOMAIN: TEAM, CF_ACCESS_AUD: AUD, BOX_OPS_TOKEN: BOX };
const ENV_OFF = { HARNESS_SECRET: SECRET, BOX_OPS_TOKEN: BOX };

const b64u = (bytes) => Buffer.from(bytes).toString('base64url');
const enc = (obj) => b64u(Buffer.from(JSON.stringify(obj)));
const KEY = await crypto.subtle.generateKey(
  { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
  true, ['sign', 'verify']);
const KID = 'kid-9262';
const JWK = { ...(await crypto.subtle.exportKey('jwk', KEY.publicKey)), kid: KID, alg: 'RS256', use: 'sig' };

// determinism: ok-file clock-now-js the one clock read is NOW below, captured
// once at load. exp/iat are OFFSETS from it (the verifier checks exp against
// the real clock); no case asserts a calendar date.
const NOW = Date.now();
const nowS = () => Math.floor(NOW / 1000);
const claims = (over = {}) => ({ aud: [AUD], iss: `https://${TEAM}`, email: 'operator@example.com', exp: nowS() + 600, iat: nowS() - 5, sub: 'u1', ...over });
async function jwt(payload = claims()) {
  const input = `${enc({ alg: 'RS256', kid: KID, typ: 'JWT' })}.${enc(payload)}`;
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', KEY.privateKey, new TextEncoder().encode(input));
  return `${input}.${b64u(new Uint8Array(sig))}`;
}
const accessHeaders = async (token) => ({ 'cf-access-authenticated-user-email': 'Operator@example.com', 'cf-access-jwt-assertion': token ?? await jwt() });

function stub() {
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
  return { jobs, restore: () => { globalThis.fetch = real; } };
}

let seq = 0;
async function forward(rest, { method = 'POST', body, env = ENV_ON, headers = {} } = {}) {
  const s = stub();
  try {
    const res = await coord({
      request: new Request(`https://mc.example.com/api/coord/${rest}`, {
        method,
        headers: { cookie: `dash=boxops${++seq}`, 'content-type': 'application/json', ...headers },
        body: body == null ? null : JSON.stringify(body),
      }),
      env,
      params: { path: rest.split('/').filter(Boolean) },
    });
    return { status: res.status, jobs: s.jobs };
  } finally { s.restore(); }
}
const AUTONOMY = { agent: 'watchman', autonomy: 'augmentation', reason: 'earned' };
const lower = (h) => Object.fromEntries(Object.entries(h).map(([k, v]) => [k.toLowerCase(), v]));

test.beforeEach(() => _resetCertsCache());

test('B1 a verified Access identity on a boxOps row: the upstream carries the token and the identity', async () => {
  for (const [rest, body] of [
    ['staff/agents/autonomy', AUTONOMY],
    ['staff/classes/delegation', { agent: 'watchman', class: 'lint-fixes', decision: 'delegate', reason: 'r' }],
    ['staff/promotions/decide', { id: 7, decision: 'approve', reason: 'r' }],
    ['box-commands', { box: 'hub', type: 'orgo_restart', target: 'project3', reason: 'hung', confirm: true }],
  ]) {
    const r = await forward(rest, { body, headers: await accessHeaders() });
    assert.equal(r.status, 200, rest);
    assert.equal(r.jobs.length, 1, rest);
    const h = lower(r.jobs[0].headers);
    assert.equal(h['x-box-ops-token'], BOX, rest);
    assert.equal(h['x-box-ops-identity'], 'operator@example.com', rest);
    assert.equal(JSON.parse(r.jobs[0].body).actor, 'operator@example.com', rest);
  }
});

test('B2 no Access env: neither header, and the write is still forwarded', async () => {
  const r = await forward('staff/agents/autonomy', { body: AUTONOMY, env: ENV_OFF, headers: await accessHeaders() });
  assert.equal(r.jobs.length, 1);
  const h = lower(r.jobs[0].headers);
  assert.equal(h['x-box-ops-token'], undefined);
  assert.equal(h['x-box-ops-identity'], undefined);
});

test('B3 an Access header with a bad assertion: neither header', async () => {
  for (const token of ['', 'not.a.jwt', await jwt(claims({ aud: ['other'] })), await jwt(claims({ email: 'mallory@x.com' }))]) {
    const r = await forward('staff/agents/autonomy', { body: AUTONOMY, headers: await accessHeaders(token) });
    assert.equal(r.jobs.length, 1);
    const h = lower(r.jobs[0].headers);
    assert.equal(h['x-box-ops-token'], undefined, `token ${token.slice(0, 12)}`);
    assert.equal(h['x-box-ops-identity'], undefined);
  }
});

test('B4 BOX_OPS_TOKEN unset or blank: neither header, and the write is still forwarded', async () => {
  for (const env of [{ ...ENV_ON, BOX_OPS_TOKEN: undefined }, { ...ENV_ON, BOX_OPS_TOKEN: '  ' }]) {
    const r = await forward('staff/agents/autonomy', { body: AUTONOMY, env, headers: await accessHeaders() });
    assert.equal(r.status, 200);
    assert.equal(r.jobs.length, 1);
    const h = lower(r.jobs[0].headers);
    assert.equal(h['x-box-ops-token'], undefined);
    assert.equal(h['x-box-ops-identity'], undefined);
  }
});

test('B5 a row without boxOps (PUT flags) carries neither header, even with Access on', async () => {
  const r = await forward('flags', { method: 'PUT', body: { name: 'pause', active: true, reason: 'x' }, headers: await accessHeaders() });
  assert.equal(r.jobs.length, 1, `status ${r.status}`);
  const h = lower(r.jobs[0].headers);
  assert.equal(h['x-box-ops-token'], undefined);
  assert.equal(h['x-box-ops-identity'], undefined);
});

test('B6 no upstream request ever carries x-human-verdict-token, even when the env has one', async () => {
  const env = { ...ENV_ON, HUMAN_VERDICT_TOKEN: 'must-never-forward' };
  const r = await forward('staff/agents/autonomy', { body: AUTONOMY, env, headers: await accessHeaders() });
  assert.equal(r.jobs.length, 1);
  const h = lower(r.jobs[0].headers);
  assert.equal(h['x-human-verdict-token'], undefined);
  assert.ok(!JSON.stringify(r.jobs[0]).includes('must-never-forward'));
});

test('B7 boxOpsHeaders: only access on, a non-blank token and an email', () => {
  assert.deepEqual(boxOpsHeaders({ access: 'on', email: 'operator@example.com' }, { BOX_OPS_TOKEN: BOX }),
    { 'x-box-ops-token': BOX, 'x-box-ops-identity': 'operator@example.com' });
  assert.deepEqual(boxOpsHeaders({ access: 'on', email: 'operator@example.com' }, { BOX_OPS_TOKEN: ` ${BOX} ` }),
    { 'x-box-ops-token': BOX, 'x-box-ops-identity': 'operator@example.com' });
  for (const access of ['off', 'unverified', 'unrecordable', undefined]) {
    assert.deepEqual(boxOpsHeaders({ access, email: 'operator@example.com' }, { BOX_OPS_TOKEN: BOX }), {}, access);
  }
  assert.deepEqual(boxOpsHeaders({ access: 'on', email: null }, { BOX_OPS_TOKEN: BOX }), {});
  assert.deepEqual(boxOpsHeaders({ access: 'on', email: 'operator@example.com' }, {}), {});
  assert.deepEqual(boxOpsHeaders(null, { BOX_OPS_TOKEN: BOX }), {});
});

// --- T5: the grep test ----------------------------------------------------------

const FUNCTIONS = fileURLToPath(new URL('../functions/', import.meta.url));
function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (/\.(js|mjs|ts)$/.test(name)) out.push(p);
  }
  return out;
}

test('G1 HUMAN_VERDICT_TOKEN is not read anywhere under console-ui/functions', () => {
  const files = walk(FUNCTIONS);
  const rel = files.map((f) => relative(FUNCTIONS, f).split('\\').join('/'));
  assert.ok(files.length > 10, `the walk read only ${files.length} files`);
  assert.ok(rel.includes('api/coord/[[path]].js'), 'the walk found the coord proxy');
  assert.ok(rel.includes('_lib/box-ops-proof.js'), 'the walk found the box-ops proof');
  const hits = files.filter((f) => readFileSync(f, 'utf8').includes('HUMAN_VERDICT_TOKEN')).map((f) => relative(FUNCTIONS, f));
  assert.deepEqual(hits, []);
});
