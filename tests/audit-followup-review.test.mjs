import test from 'node:test';
import assert from 'node:assert/strict';
import { extractCode } from '../worker/otp-inbox/src/code.js';
import { onRequest as coord } from '../console-ui/functions/api/coord/[[path]].js';
import { onRequest as middleware } from '../console-ui/functions/_middleware.js';
import { _resetCertsCache } from '../console-ui/functions/_lib/access-identity.js';

test('email addresses with trailing punctuation never become OTP candidates', () => {
  for (const suffix of ['.', '!', '?', '/', '...']) {
    assert.deepEqual(extractCode(`Code sent to 482913@example.com${suffix}`, ''),
      { code: null, status: 'no_code' }, suffix);
  }
  assert.equal(extractCode('Code sent to 482913@example.com.', 'Your verification code is 654321').code, '654321');
});

test('Pages human forwarding requires same origin, verified Access, and independent credentials', async (t) => {
  const original = globalThis.fetch;
  t.after(() => { globalThis.fetch = original; _resetCertsCache(); });
  const team = 'fixture.cloudflareaccess.com';
  const key = await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify']);
  const jwk = { ...await crypto.subtle.exportKey('jwk', key.publicKey), kid: 'fixture-key', alg: 'RS256', use: 'sig' };
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
  // determinism: ok clock-now-js the verifier reads real time; this single
  // anchor gives the fixture JWT a future expiry without asserting a date.
  const now = Date.now();
  const input = `${encode({ alg: 'RS256', kid: 'fixture-key' })}.${encode({ aud: ['fixture-aud'],
    iss: `https://${team}`, email: 'operator@example.com', exp: Math.floor(now / 1000) + 600 })}`;
  const token = `${input}.${Buffer.from(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key.privateKey,
    new TextEncoder().encode(input))).toString('base64url')}`;
  const seen = [];
  globalThis.fetch = async (value, init = {}) => {
    const url = String(value);
    if (url === `https://${team}/cdn-cgi/access/certs`) return Response.json({ keys: [jwk] });
    if (url.startsWith('https://harness-console.')) return Response.json({});
    seen.push(init);
    return Response.json({ ok: true });
  };
  const base = { HARNESS_SECRET: 'fixture-fleet-token', HUMAN_VERDICT_TOKEN: 'fixture-human-token',
    LEAD_VERDICT_TOKEN: 'fixture-lead-token', CF_ACCESS_TEAM_DOMAIN: team, CF_ACCESS_AUD: 'fixture-aud' };
  for (const scenario of [{ verified: true, origin: 'https://console.fixture.test', forwarded: true },
    { verified: true, origin: 'https://preview.fixture.test', denied: true },
    { verified: false, origin: 'https://console.fixture.test' },
    { verified: true, origin: 'https://console.fixture.test', extra: { LEAD_VERDICT_TOKEN: 'fixture-human-token' } }]) {
    _resetCertsCache();
    seen.length = 0;
    const request = new Request('https://console.fixture.test/api/coord/staff/agents/autonomy', {
      method: 'POST', headers: { cookie: 'dash=fixture-review-session', origin: scenario.origin,
        'content-type': 'application/json', 'cf-access-authenticated-user-email': 'operator@example.com',
        ...(scenario.verified ? { 'cf-access-jwt-assertion': token } : {}) },
      body: JSON.stringify({ agent: 'watchman', autonomy: 'augmentation', reason: 'fixture reason' }),
    });
    const res = await middleware({ request, next: () => coord({ request, env: { ...base, ...scenario.extra },
      params: { path: ['staff', 'agents', 'autonomy'] } }) });
    assert.equal(res.status, scenario.denied ? 403 : 200);
    assert.equal(seen.length, scenario.denied ? 0 : 1);
    if (!scenario.denied) {
      assert.equal(seen[0].headers['x-human-verdict-token'], scenario.forwarded ? base.HUMAN_VERDICT_TOKEN : undefined);
      if (scenario.forwarded) assert.equal(JSON.parse(seen[0].body).actor, 'operator@example.com');
    }
  }
});
