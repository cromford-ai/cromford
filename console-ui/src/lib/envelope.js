// Seal a secret in the browser for the hub (BH-7966, BH-7937.2). The value is
// encrypted with WebCrypto RSA-OAEP SHA-256 to the hub's public key (settings
// row hub_envelope_public_key) and only the base64 ciphertext leaves the page,
// as a BH-7964 envelope. Nothing here keeps the value, and no error repeats it.
//
// The envelope scope has one grammar, written only by accountScope():
//   ai-account:<vendor>:<label>:<use_kind>[:<project>]
// The hub consumer (BH-7937.1, PR #8149 bin/lib/envelope.sh) parses the same.

// The RSA-4096 OAEP-SHA-256 plaintext maximum: 512 - 2*32 - 2 bytes. A
// cryptographic bound, not a policy knob. A smaller key holds less, and
// sealSecret refuses at that key's own bound.
export const SEAL_MAX_BYTES = 446;

const VENDORS = ['claude', 'codex', 'openrouter', 'fireworks', 'xai'];
const USE_KINDS = ['project', 'pool', 'fallback'];
const PART_RE = /^[a-z0-9._@-]{1,64}$/;
// worker/jobs/src/routes/secret-envelopes.js checkEnvelopeScope.
const SCOPE_RE = /^(ai-account|tracker):[a-z0-9._:@-]{1,96}$/;

function spkiFromPem(pem) {
  const body = String(pem || '')
    .replace(/-----BEGIN PUBLIC KEY-----/, '')
    .replace(/-----END PUBLIC KEY-----/, '')
    .replace(/\s+/g, '');
  if (!body || !/^[A-Za-z0-9+/]+={0,2}$/.test(body)) throw new Error('the hub public key is not a PEM public key');
  const bin = atob(body);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function toBase64(buf) {
  const bytes = new Uint8Array(buf);
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
}

// sealSecret(publicKeyPem, value) -> base64 ciphertext. Throws on an empty
// value, a value over the key's bound (446 bytes at RSA-4096) or a bad key.
export async function sealSecret(publicKeyPem, value) {
  const text = typeof value === 'string' ? value : '';
  if (!text) throw new Error('the value is empty');
  const data = new TextEncoder().encode(text);
  if (data.length > SEAL_MAX_BYTES) throw new Error(`value too long: at most ${SEAL_MAX_BYTES} bytes`);
  let key;
  try {
    key = await globalThis.crypto.subtle.importKey('spki', spkiFromPem(publicKeyPem), { name: 'RSA-OAEP', hash: 'SHA-256' }, false, ['encrypt']);
  } catch {
    throw new Error('the hub public key is not a usable RSA-OAEP key');
  }
  const keyMax = key.algorithm && key.algorithm.modulusLength ? key.algorithm.modulusLength / 8 - 66 : SEAL_MAX_BYTES;
  if (data.length > keyMax) throw new Error(`value too long: at most ${keyMax} bytes for this hub key`);
  return toBase64(await globalThis.crypto.subtle.encrypt({ name: 'RSA-OAEP' }, key, data));
}

// accountScope({vendor, label, use_kind, project}) -> {ok, scope} | {ok:false, message}.
// project is required for use kind `project` and refused for the others.
export function accountScope({ vendor, label, use_kind, project } = {}) {
  if (!VENDORS.includes(vendor)) return { ok: false, message: `vendor must be one of ${VENDORS.join(', ')}` };
  if (!USE_KINDS.includes(use_kind)) return { ok: false, message: `use kind must be one of ${USE_KINDS.join(', ')}` };
  if (typeof label !== 'string' || !PART_RE.test(label)) return { ok: false, message: 'the label must be lower-case letters, digits and . _ @ -' };
  const hasProject = project !== undefined && project !== null && project !== '';
  if (use_kind === 'project' && !hasProject) return { ok: false, message: 'a project account needs its project' };
  if (use_kind !== 'project' && hasProject) return { ok: false, message: 'only a project account names a project' };
  if (hasProject && (typeof project !== 'string' || !PART_RE.test(project))) return { ok: false, message: 'the project name must be lower-case letters, digits and . _ @ -' };
  const scope = `ai-account:${vendor}:${label}:${use_kind}${hasProject ? `:${project}` : ''}`;
  if (scope.length - 'ai-account:'.length > 96) return { ok: false, message: 'the envelope name is over 96 chars: pick a shorter label' };
  if (!SCOPE_RE.test(scope) || scope.includes('..')) return { ok: false, message: 'the label cannot hold ..' };
  return { ok: true, scope };
}
