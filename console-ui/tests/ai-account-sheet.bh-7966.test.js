import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { webcrypto } from 'node:crypto';
import { api } from '../src/api.js';
import { sealSecret } from '../src/lib/envelope.js';
import {
  checkAiAccountLabel, loadSheetConfig, resetSheetConfig, saveAccount, pollStatus, chooseAccount, POLL_S_DEFAULT, WAIT_S_DEFAULT
} from '../src/lib/ai-accounts.js';
import { makeAccountSetter } from '../src/lib/project-accounts.js';
import { AiAccountSheetView } from '../src/screens/AiAccountSheet.js';
import { FleetAccountsView } from '../src/screens/FleetAccounts.js';

// BH-7966 (BH-7937.2): the add sheet's save flow, its status poll and the
// per-project choice. The real `api` object runs over a fetch fake that plays
// the worker routes; any URL it does not serve throws (B1), so no test here
// reaches a network or a vendor.
//   V1 the sheet renders open as a dialog   L1 label rule, 0 requests on a refusal
//   K1 one settings read per page load      K2 empty hub key: no-key, 0 requests
//   F1-F5 save flow                          P1-P4 status poll
//   C1-C4 project choice                     B1 0 vendor calls
const subtle = webcrypto.subtle;
const TOKEN = 'tok-fixture-openrouter-bh7966-secret';

async function pem() {
  const kp = await subtle.generateKey(
    { name: 'RSA-OAEP', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['encrypt', 'decrypt']);
  const spki = Buffer.from(await subtle.exportKey('spki', kp.publicKey)).toString('base64');
  return `-----BEGIN PUBLIC KEY-----\n${spki.match(/.{1,64}/g).join('\n')}\n-----END PUBLIC KEY-----\n`;
}
const PEM = await pem();

// A fake of the coord proxy + worker: the routes the sheet calls, in memory.
function fakeWorker({ publicKey = PEM, envelopeFails = false, accountStatus = 200, settingsRows } = {}) {
  const seen = [];
  const accounts = [];
  const envelopes = new Map();
  const real = globalThis.fetch;
  const reply = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
  globalThis.fetch = async (url, init = {}) => {
    const method = init.method || 'GET';
    seen.push({ url, method, body: init.body });
    const body = init.body ? JSON.parse(init.body) : null;
    if (method === 'GET' && url === '/api/coord/settings') {
      return reply(200, { settings: settingsRows || [{ key: 'hub_envelope_public_key', value: publicKey }, { key: 'ai_account_status_poll_s', value: '3' }, { key: 'ai_account_status_wait_s', value: '90' }] });
    }
    if (method === 'POST' && url === '/api/coord/secrets/envelope') {
      if (envelopeFails) return reply(503, { error: 'secret_envelopes unavailable' });
      const id = crypto.randomUUID();
      envelopes.set(id, body.scope);
      return reply(200, { id, expires_at: '2099-01-01T00:00:00Z' });
    }
    if (method === 'POST' && url === '/api/coord/ai-accounts') {
      if (accountStatus !== 200) return reply(accountStatus, { error: 'that label is taken on this vendor (revoked labels too): pick a new label' });
      const id = crypto.randomUUID();
      accounts.push({ id, vendor: body.vendor, label: body.label, plan: body.plan || null, use_kind: body.use_kind, projects: [], today: 0, boxes: null, state: 'pending', revoked_at: null });
      return reply(200, { id, state: 'pending' });
    }
    if (method === 'GET' && url === '/api/coord/ai-accounts') return reply(200, { accounts, limit: 500, truncated: false });
    const rv = /^\/api\/coord\/ai-accounts\/([0-9a-f-]{36})\/revoke$/.exec(url);
    if (method === 'POST' && rv) return reply(200, { revoked_at: '2026-10-23T12:00:00Z' });
    throw new Error(`B1: the fake does not serve ${method} ${url}`);
  };
  return { seen, accounts, envelopes, restore: () => { globalThis.fetch = real; } };
}
const form = (over = {}) => ({ vendor: 'openrouter', label: 'team-a', token: TOKEN, plan: '', use_kind: 'pool', project: null, ...over });
const config = (over = {}) => ({ publicKey: PEM, pollS: 3, waitS: 90, ...over });
const posts = (f) => f.seen.filter((s) => s.method === 'POST');

test('V1 the sheet renders open as a modal dialog; the token field is a password with autocomplete off', () => {
  const out = render(h(AiAccountSheetView, { open: true, mode: 'add', form: form({ token: '' }), config: config(), phase: 'idle' }));
  assert.match(out, /role="dialog"/);
  assert.match(out, /aria-modal="true"/);
  assert.match(out, /class="aisheet aisheet--open"/);
  assert.doesNotMatch(out, /<div[^>]*role="dialog"[^>]*hidden/);
  assert.match(out, /<input[^>]*type="password"[^>]*autocomplete="off"|<input[^>]*autocomplete="off"[^>]*type="password"/);
  assert.match(out, /TEST AND SAVE/);
  for (const v of ['claude', 'codex', 'openrouter', 'fireworks', 'xai']) assert.match(out, new RegExp(`<option[^>]*value="${v}"`));
  assert.equal(render(h(AiAccountSheetView, { open: false, mode: 'add', form: form(), config: config() })), '');
  // Rotate: the note says it adds a new label and revokes the old one after.
  const rot = render(h(AiAccountSheetView, { open: true, mode: 'rotate', old: { label: 'team-a' }, form: form({ label: '' }), config: config(), phase: 'idle' }));
  assert.match(rot, /adds a new label; the old one is revoked after this one saves/);
});

test('L1 the console label rule matches the worker table; a refusal sends 0 requests', async () => {
  const refuse = ['sk-x', 'SK-proj-1', 'sk_live1', 'xai-abc123', 'fw_abc', 'or-abc', 'team..a', 'Team-A', 'team:a', 'a'.repeat(49), 'shared', '', '   '];
  for (const v of refuse) {
    const r = checkAiAccountLabel(v);
    assert.equal(r.ok, false, `accepted ${JSON.stringify(v)}`);
    if (v.trim()) assert.ok(!r.message.includes(v), `the message echoes ${JSON.stringify(v)}`);
  }
  for (const v of ['team-a', 'skate', 'ops.1', 'a@b', 'b'.repeat(48), 'x']) assert.equal(checkAiAccountLabel(v).ok, true, v);
  const f = fakeWorker();
  try {
    const r = await saveAccount({ api, seal: sealSecret, form: form({ label: 'sk-abc' }), config: config() });
    assert.equal(r.status, 'invalid');
    assert.ok(!r.message.includes('sk-abc'));
    assert.equal(f.seen.length, 0, 'a refused label sends nothing');
  } finally { f.restore(); }
});

test('K1 K2 one settings read per page load; an empty hub key answers no-key and sends nothing', async () => {
  const f = fakeWorker();
  try {
    resetSheetConfig();
    const [a, b] = await Promise.all([loadSheetConfig(api), loadSheetConfig(api)]);
    await loadSheetConfig(api);
    assert.equal(f.seen.filter((s) => s.url === '/api/coord/settings').length, 1);
    assert.equal(a.publicKey, PEM.trim());
    assert.deepEqual([b.pollS, b.waitS], [3, 90]);
  } finally { f.restore(); resetSheetConfig(); }
  const g = fakeWorker({ settingsRows: [{ key: 'hub_envelope_public_key', value: '' }, { key: 'ai_account_status_poll_s', value: '0' }, { key: 'ai_account_status_wait_s', value: 'abc' }] });
  try {
    const c = await loadSheetConfig(api);
    assert.equal(c.publicKey, '');
    assert.deepEqual([c.pollS, c.waitS], [POLL_S_DEFAULT, WAIT_S_DEFAULT], 'out-of-range rows fall back to 3 and 90');
    const r = await saveAccount({ api, seal: sealSecret, form: form(), config: c });
    assert.equal(r.status, 'no-key');
    assert.equal(posts(g).length, 0);
    const out = render(h(AiAccountSheetView, { open: true, mode: 'add', form: form(), config: c, phase: 'idle' }));
    assert.match(out, /The hub key is not set yet \(run bin\/envelope-keygen\.sh on the hub\)/);
    assert.match(out, /<button[^>]*type="submit"[^>]*disabled/);
  } finally { g.restore(); resetSheetConfig(); }
});

test('F1 openrouter / team-a: the envelope holds a ciphertext, the account lands, and the fleet table lists it pending', async () => {
  const f = fakeWorker();
  try {
    const r = await saveAccount({ api, seal: sealSecret, form: form(), config: config() });
    assert.equal(r.status, 'saved', r.message);
    const [env, acc] = posts(f);
    assert.equal(env.url, '/api/coord/secrets/envelope');
    const envBody = JSON.parse(env.body);
    assert.equal(envBody.scope, 'ai-account:openrouter:team-a:pool');
    assert.notEqual(envBody.ciphertext, TOKEN);
    assert.ok(!envBody.ciphertext.includes(TOKEN));
    assert.equal(envBody.ciphertext.length, 344);
    assert.equal(acc.url, '/api/coord/ai-accounts');
    assert.deepEqual(JSON.parse(acc.body), { vendor: 'openrouter', label: 'team-a', plan: null, use_kind: 'pool', envelope_id: r.envelope_id });
    const listed = await api.aiAccounts();
    const out = render(h(FleetAccountsView, { data: listed, loading: false, error: null }));
    assert.match(out, /openrouter/);
    assert.match(out, /href="\/settings\?account=team-a"/);
    assert.match(out, /pending/);
    // F2 no request body carries the token.
    for (const s of f.seen) assert.ok(!String(s.body || '').includes(TOKEN), `${s.method} ${s.url} carries the token`);
  } finally { f.restore(); }
});

test('F3 F4 an envelope failure stops before the account POST; a 409 answers failed with the label-taken text', async () => {
  const f = fakeWorker({ envelopeFails: true });
  try {
    const r = await saveAccount({ api, seal: sealSecret, form: form(), config: config() });
    assert.equal(r.status, 'failed');
    assert.match(r.message, /not saved/);
    assert.deepEqual(posts(f).map((s) => s.url), ['/api/coord/secrets/envelope']);
  } finally { f.restore(); }
  const g = fakeWorker({ accountStatus: 409 });
  try {
    const r = await saveAccount({ api, seal: sealSecret, form: form(), config: config() });
    assert.equal(r.status, 'failed');
    assert.match(r.message, /label is taken/);
    assert.ok(!r.message.includes(TOKEN));
  } finally { g.restore(); }
});

test('F5 rotate revokes the old id only after the new account saved, never on a failure', async () => {
  const old = { id: crypto.randomUUID(), label: 'team-a' };
  const f = fakeWorker();
  try {
    const r = await saveAccount({ api, seal: sealSecret, form: form({ label: 'team-b' }), config: config(), rotateFrom: old });
    assert.equal(r.status, 'saved');
    assert.equal(r.revoked, true);
    assert.deepEqual(posts(f).map((s) => s.url), ['/api/coord/secrets/envelope', '/api/coord/ai-accounts', `/api/coord/ai-accounts/${old.id}/revoke`]);
  } finally { f.restore(); }
  const g = fakeWorker({ accountStatus: 409 });
  try {
    const r = await saveAccount({ api, seal: sealSecret, form: form({ label: 'team-b' }), config: config(), rotateFrom: old });
    assert.equal(r.status, 'failed');
    assert.ok(!posts(g).some((s) => s.url.endsWith('/revoke')), 'a failed rotate keeps the old account');
  } finally { g.restore(); }
});

function clock() {
  let t = 0;
  return { now: () => t, sleep: async (ms) => { t += ms; } };
}
const statusApi = (states) => {
  let i = 0;
  const calls = [];
  return { calls, envelopeStatus: async (id) => { calls.push(id); const s = states[Math.min(i++, states.length - 1)]; return { state: s }; } };
};

test('P1-P4 pollStatus: applied = proved, apply_failed / expired = failed, pending until 90 s = waiting after 30 polls', async () => {
  for (const [states, want] of [[['pending', 'consumed', 'applied'], 'proved'], [['pending', 'apply_failed'], 'failed'], [['expired'], 'failed']]) {
    const c = clock();
    const a = statusApi(states);
    assert.equal(await pollStatus({ api: a, envelopeId: 'e1', pollS: 3, waitS: 90, ...c }), want, states.join(','));
  }
  const c = clock();
  const a = statusApi(['pending']);
  assert.equal(await pollStatus({ api: a, envelopeId: 'e1', pollS: 3, waitS: 90, ...c }), 'waiting');
  assert.equal(a.calls.length, 30);
  assert.equal(c.now(), 90e3);
});

test('C1-C4 the project choice: pool writes shared, an account its label, each only after the confirm says yes', async () => {
  const run = async (choice, answer) => {
    const order = [];
    const setter = makeAccountSetter({
      confirm: async (o) => { order.push(['confirm', o.title]); return answer; },
      writeSetting: async (b) => { order.push(['write', b.key, b.value]); return { setting: b }; },
    });
    const r = await chooseAccount({ choice, project: 'demo', setter });
    return { r, order };
  };
  let x = await run({ kind: 'pool' }, true);
  assert.deepEqual(x.order.map((o) => o[0]), ['confirm', 'write']);
  assert.deepEqual(x.order[1].slice(1), ['account.demo', 'shared']);
  assert.equal(x.r.status, 'written');
  x = await run({ kind: 'account', label: 'team-a' }, true);
  assert.deepEqual(x.order.map((o) => o[0]), ['confirm', 'write']);
  assert.deepEqual(x.order[1].slice(1), ['account.demo', 'team-a']);
  x = await run({ kind: 'account', label: 'team-a' }, false);
  assert.deepEqual(x.order.map((o) => o[0]), ['confirm'], 'cancel writes nothing');
  assert.equal(x.r.status, 'cancelled');
  x = await run({ kind: 'own' }, true);
  assert.equal(x.r.status, 'open-add');
  assert.equal(x.order.length, 0);
});

test('B1 the fake throws on any URL it does not serve, so a stray call is red', async () => {
  const f = fakeWorker();
  try {
    await assert.rejects(fetch('https://openrouter.ai/api/v1/models'), /B1/);
  } finally { f.restore(); }
});
