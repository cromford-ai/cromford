import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';
import { boxCommandFor } from '../src/lib/box-commands.js';

// BH-5750 T1.6: the console's half of the Orgo / Fly pool controls. The proxy
// forwards their args and the price token as sent and stamps the actor; the
// body builder refuses a blank required field and never computes a price.

const SECRET = 'test-harness-secret-fixture';
const OPS = 'fixture-owner-token';
const OWNER = 'operator@example.com';
const TEAM = 'fixture.cloudflareaccess.com';
const AUD = 'fixture-aud';
const key = await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048,
  publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify']);
const jwk = { ...await crypto.subtle.exportKey('jwk', key.publicKey), kid: 'fixture-key' };
const enc = (v) => Buffer.from(JSON.stringify(v)).toString('base64url');
const data = `${enc({ alg: 'RS256', kid: jwk.kid })}.${enc({ email: OWNER, aud: [AUD], iss: `https://${TEAM}`, exp: 9999999999 })}`;
const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key.privateKey, new TextEncoder().encode(data));
const assertion = `${data}.${Buffer.from(signature).toString('base64url')}`;

function stubFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.includes('/cdn-cgi/access/certs')) return Response.json({ keys: [jwk] });
    if (target.startsWith('https://harness-console.operator.workers.dev')) return new Response('', { status: 200 });
    seen.push({ url: target, body: init.body });
    return new Response(JSON.stringify({ id: 7, status: 'requested' }), { status: 201, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}
let seq = 0;
const call = (body) => onRequest({
  request: new Request('https://console.example.pages.dev/api/coord/box-commands', {
    method: 'POST', headers: { cookie: `dash=orgo${++seq}`, 'content-type': 'application/json',
      'cf-access-authenticated-user-email': OWNER, 'cf-access-jwt-assertion': assertion }, body: JSON.stringify(body),
  }),
  env: { HARNESS_SECRET: SECRET, BOX_OPS_TOKEN: OPS, CF_ACCESS_TEAM_DOMAIN: TEAM, CF_ACCESS_AUD: AUD },
  params: { path: ['box-commands'] },
});

test('P1: the proxy forwards the Orgo args and the price token, and drops a browser actor', async () => {
  const f = stubFetch();
  try {
    const sent = {
      box: 'hub', type: 'orgo_resize', target: 'project-3', account: 'acct-a', vcpus: 8, mem_gb: 32, disk_gb: 200,
      quote_id: 41, confirm_monthly_usd: '12', reason: 'grow', confirm: true, actor: 'owner@example.com', status: 'ok',
    };
    const res = await call(sent);
    assert.equal(res.status, 201);
    const fwd = JSON.parse(f.seen[0].body);
    assert.equal(fwd.confirm_monthly_usd, '12');
    assert.equal(fwd.quote_id, 41);
    assert.equal(fwd.vcpus, 8);
    assert.equal(fwd.mem_gb, 32);
    assert.equal(fwd.disk_gb, 200);
    assert.equal(fwd.account, 'acct-a');
    assert.equal(fwd.actor, OWNER, 'the stamped verified actor, never the browser one');
    assert.equal('status' in fwd, false);
    const ret = JSON.parse((await (async () => { f.seen.length = 0; await call({ box: 'hub', type: 'orgo_retire', target: 'project-3', to: 'project-4', ip: '192.0.2.10', delete: true, reason: 'r', confirm: true }); return f.seen; })())[0].body);
    assert.equal(ret.to, 'project-4');
    assert.equal(ret.ip, '192.0.2.10');
    assert.equal(ret.delete, true);
    f.seen.length = 0;
    await call({ box: 'hub', type: 'fly_pool_cap', target: 'proj-x', cap: 5, reason: 'r', confirm: true });
    assert.equal(JSON.parse(f.seen[0].body).cap, 5);
  } finally { f.restore(); }
});

test('P2: a blank required field is refused, never filled in', () => {
  const base = { box: 'project-3', account: 'acct-a', vcpus: 8, reason: 'grow', quote_id: 41, confirm_monthly_usd: '12' };
  assert.deepEqual(boxCommandFor('orgo_resize', { ...base, account: '' }), { error: 'account required' });
  assert.deepEqual(boxCommandFor('orgo_resize', { ...base, confirm_monthly_usd: undefined }), { error: 'confirm_monthly_usd required' });
  assert.deepEqual(boxCommandFor('orgo_resize', { ...base, quote_id: null }), { error: 'quote_id required' });
  assert.deepEqual(boxCommandFor('orgo_resize', { ...base, vcpus: undefined }), { error: 'vcpus, mem_gb or disk_gb required' });
  assert.deepEqual(boxCommandFor('orgo_restart', { box: ' ', reason: 'r' }), { error: 'box required' });
  assert.deepEqual(boxCommandFor('orgo_launch_quote', { box: 'newbox', account: 'acct-a', project: 'proj-x', vcpus: 4, mem_gb: 16, reason: 'r' }), { error: 'disk_gb required' });
  assert.deepEqual(boxCommandFor('fly_pool_cap', { project: 'proj-x', reason: 'r' }), { error: 'cap required' });
  assert.deepEqual(boxCommandFor('fly_onboard', { project: '', reason: 'r' }), { error: 'project required' });
  assert.deepEqual(boxCommandFor('orgo_stop', { box: 'project-3', reason: '' }), { error: 'reason required' });
});

test('P3: a full body is exact: addressed to hub, the box as target, the token as received', () => {
  assert.deepEqual(boxCommandFor('orgo_resize', {
    box: ' project-3 ', account: 'acct-a', vcpus: 8, disk_gb: 200, quote_id: 41, confirm_monthly_usd: '12', reason: ' grow ',
  }), {
    box: 'hub', type: 'orgo_resize', target: 'project-3', account: 'acct-a', quote_id: 41, confirm_monthly_usd: '12',
    vcpus: 8, disk_gb: 200, reason: 'grow', confirm: true,
  });
  assert.deepEqual(boxCommandFor('orgo_stop', { box: 'project-3', reason: 'r' }), { box: 'hub', type: 'orgo_stop', target: 'project-3', reason: 'r', confirm: true });
  assert.deepEqual(boxCommandFor('orgo_retire', { box: 'project-3', to: 'project-4', delete: false, reason: 'r' }),
    { box: 'hub', type: 'orgo_retire', target: 'project-3', to: 'project-4', delete: false, reason: 'r', confirm: true });
  assert.deepEqual(boxCommandFor('fly_onboard', { project: 'proj-x', cap: 3, reason: 'r' }),
    { box: 'hub', type: 'fly_onboard', target: 'proj-x', cap: 3, reason: 'r', confirm: true });
});
