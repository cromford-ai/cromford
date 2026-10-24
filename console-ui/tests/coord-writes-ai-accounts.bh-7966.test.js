import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-7966 (BH-7937.2): the three console writes of the AI account sheet go
// through the coord proxy as fragment rows (coord-writes.d/7966-ai-accounts.js):
// POST secrets/envelope, POST ai-accounts (created_by stamped as
// console:<actor>, a browser created_by dropped) and POST ai-accounts/<uuid>/revoke.
// No row forwards the hub token header. The real onRequest; fetch stubbed.
const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
const SECRET = 'fixture-harness-secret';

function stubFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    const headers = new Headers(init.headers || {});
    seen.push({ url: target, method: init.method, body: init.body, headers });
    return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}
let cookieSeq = 0;
const call = (rest, method, body, extra = {}) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
      method,
      headers: { cookie: `dash=bh7966-${++cookieSeq}`, 'content-type': 'application/json', ...extra },
      body
    }),
    env: { HARNESS_SECRET: SECRET, ENVELOPE_HUB_TOKEN: 'tok-fixture-hub' },
    params: { path: rest.split('/') }
  });

test('W1 POST secrets/envelope forwards scope and ciphertext only, and never a hub token header', async () => {
  const f = stubFetch();
  try {
    const res = await call('secrets/envelope', 'POST', JSON.stringify({ scope: 'ai-account:openrouter:team-a:pool', ciphertext: 'QUJD', extra: 1 }),
      { 'x-envelope-hub-token': 'tok-fixture-hub' });
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/secrets/envelope`);
    const fwd = JSON.parse(f.seen[0].body);
    assert.equal(fwd.scope, 'ai-account:openrouter:team-a:pool');
    assert.equal(fwd.ciphertext, 'QUJD');
    assert.equal('extra' in fwd, false);
    assert.equal(f.seen[0].headers.get('x-envelope-hub-token'), null);
  } finally { f.restore(); }
});

test('W2 POST ai-accounts forwards the five fields and stamps created_by; a browser created_by is dropped', async () => {
  const f = stubFetch();
  try {
    const sent = { vendor: 'openrouter', label: 'team-a', plan: 'pro', use_kind: 'pool', envelope_id: 'e-1', created_by: 'console:evil', revoked_at: 'x' };
    const res = await call('ai-accounts', 'POST', JSON.stringify(sent));
    assert.equal(res.status, 200);
    assert.equal(f.seen[0].url, `${JOBS}/api/ai-accounts`);
    const fwd = JSON.parse(f.seen[0].body);
    for (const k of ['vendor', 'label', 'plan', 'use_kind', 'envelope_id']) assert.equal(fwd[k], sent[k], k);
    assert.match(fwd.created_by, /^console:/);
    assert.notEqual(fwd.created_by, 'console:evil');
    assert.equal('revoked_at' in fwd, false);
    assert.equal(f.seen[0].headers.get('x-envelope-hub-token'), null);
  } finally { f.restore(); }
});

test('W3 POST ai-accounts/<uuid>/revoke is admitted; a dot segment, a sub-path and other verbs are 405', async () => {
  const f = stubFetch();
  try {
    const id = crypto.randomUUID();
    const res = await call(`ai-accounts/${id}/revoke`, 'POST', '{}');
    assert.equal(res.status, 200);
    assert.equal(f.seen[0].url, `${JOBS}/api/ai-accounts/${id}/revoke`);
    for (const [rest, method] of [['ai-accounts/../x/revoke', 'POST'], ['ai-accounts/./revoke', 'POST'], [`ai-accounts/${id}/delete`, 'POST'],
      ['ai-accounts', 'DELETE'], ['ai-accounts', 'PUT'], ['secrets/envelope', 'PUT']]) {
      const r = await call(rest, method, '{}');
      assert.equal(r.status, 405, `${method} ${rest}`);
    }
    assert.equal(f.seen.length, 1);
  } finally { f.restore(); }
});
