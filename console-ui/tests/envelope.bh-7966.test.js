import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { sealSecret, accountScope, SEAL_MAX_BYTES } from '../src/lib/envelope.js';

// BH-7966 (BH-7937.2): the console seals an AI account token in the browser
// to the hub's public key (WebCrypto RSA-OAEP SHA-256) and names the envelope
// with one scope grammar, ai-account:<vendor>:<label>:<use_kind>[:<project>].
// The worker's checkEnvelopeScope pattern is copied here on purpose: R1 proves
// every scope this function writes is one that pattern admits.
//   R1 accountScope accept / refuse     R2 seal round-trips (4096 and 2048)
//   R3 the 446-byte cap; no error repeats the value
const SCOPE_RE = /^(ai-account|tracker):[a-z0-9._:@-]{1,96}$/;
const subtle = webcrypto.subtle;

async function keyPair(bits) {
  const kp = await subtle.generateKey(
    { name: 'RSA-OAEP', modulusLength: bits, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true, ['encrypt', 'decrypt']);
  const spki = Buffer.from(await subtle.exportKey('spki', kp.publicKey)).toString('base64');
  const pem = `-----BEGIN PUBLIC KEY-----\n${spki.match(/.{1,64}/g).join('\n')}\n-----END PUBLIC KEY-----\n`;
  return { pem, privateKey: kp.privateKey };
}
const decrypt = async (privateKey, b64) =>
  new TextDecoder().decode(await subtle.decrypt({ name: 'RSA-OAEP' }, privateKey, Buffer.from(b64, 'base64')));

test('R1 accountScope: pool, fallback and project+demo accept; a missing or extra project and a long scope refuse', () => {
  const ok = [
    [{ vendor: 'openrouter', label: 'team-a', use_kind: 'pool' }, 'ai-account:openrouter:team-a:pool'],
    [{ vendor: 'xai', label: 'ops.1', use_kind: 'fallback' }, 'ai-account:xai:ops.1:fallback'],
    [{ vendor: 'claude', label: 'team-a', use_kind: 'project', project: 'demo' }, 'ai-account:claude:team-a:project:demo'],
  ];
  for (const [input, want] of ok) {
    const r = accountScope(input);
    assert.equal(r.ok, true, JSON.stringify(input));
    assert.equal(r.scope, want);
    assert.match(r.scope, SCOPE_RE);
    assert.ok(!r.scope.includes('..'));
  }
  const refuse = [
    { vendor: 'claude', label: 'team-a', use_kind: 'project' },
    { vendor: 'claude', label: 'team-a', use_kind: 'pool', project: 'demo' },
    { vendor: 'openai', label: 'team-a', use_kind: 'pool' },
    { vendor: 'claude', label: 'team-a', use_kind: 'spare' },
    { vendor: 'claude', label: 'Team:A', use_kind: 'pool' },
    { vendor: 'claude', label: 'team-a', use_kind: 'project', project: 'De:mo' },
    { vendor: 'openrouter', label: 'a'.repeat(48), use_kind: 'project', project: 'p'.repeat(40) },
  ];
  for (const input of refuse) {
    const r = accountScope(input);
    assert.equal(r.ok, false, `accepted ${JSON.stringify(input)}`);
    assert.equal(typeof r.message, 'string');
  }
  assert.match(accountScope(refuse[6]).message, /shorter/);
});

test('R2 sealSecret round-trips through the private key: 684 base64 chars at 4096, 344 at 2048', async () => {
  const token = 'tok-fixture-openrouter-bh7966';
  for (const [bits, len] of [[4096, 684], [2048, 344]]) {
    const { pem, privateKey } = await keyPair(bits);
    const ct = await sealSecret(pem, token);
    assert.equal(ct.length, len, `${bits}-bit ciphertext length`);
    assert.match(ct, /^[A-Za-z0-9+/]+={0,2}$/);
    assert.ok(!ct.includes(token));
    assert.equal(await decrypt(privateKey, ct), token);
    const again = await sealSecret(pem, token);
    assert.notEqual(again, ct, 'OAEP is randomized: two seals differ');
  }
});

test('R3 a 446-byte value seals at 4096; 447 bytes, an empty value and a bad PEM throw without the value', async () => {
  assert.equal(SEAL_MAX_BYTES, 446);
  const { pem, privateKey } = await keyPair(4096);
  const max = 'f'.repeat(446);
  assert.equal(await decrypt(privateKey, await sealSecret(pem, max)), max);
  const over = 'fixture-' + 'g'.repeat(439);
  assert.equal(Buffer.byteLength(over), 447);
  await assert.rejects(sealSecret(pem, over), (e) => /too long/.test(e.message) && !e.message.includes(over.slice(0, 12)));
  await assert.rejects(sealSecret(pem, ''), /empty/);
  await assert.rejects(sealSecret('not a pem', 'tok-fixture-x'), (e) => !e.message.includes('tok-fixture-x'));
  // A 2048-bit key holds less: its own cap, 190 bytes, refuses before encrypt fails.
  const small = await keyPair(2048);
  await assert.rejects(sealSecret(small.pem, 'h'.repeat(191)), /too long/);
});
