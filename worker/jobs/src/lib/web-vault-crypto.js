// web_vault crypto (BH-7595): AES-GCM 256 in the worker, so D1 never holds a
// plain value. Contract: docs/notes/2026-10-19-BH-7595-web-vault.md.
//
// THE KEY is the Worker secret WEB_VAULT_KEY_<key_id>: base64 of 32 bytes. A
// secret that is absent or does not decode to exactly 32 bytes is "key
// missing". Each row keeps the key_id it was written with, so a rotation adds
// WEB_VAULT_KEY_<n+1>, moves the web_vault.key_id setting, and re-sets each
// entry; an old row reads with its own key until then.
//
// THE IV is 12 random bytes per write. THE AAD binds the ciphertext to its
// (project, site, field): a ciphertext copied into another row fails to decrypt.
//
// Neither function throws, and no answer or error text ever holds the value.

const KEY_BYTES = 32;
const IV_BYTES = 12;
const B64_RE = /^[A-Za-z0-9+/]+={0,2}$/;

function fromB64(s) {
  if (typeof s !== "string" || !B64_RE.test(s) || s.length % 4 !== 0) return null;
  try {
    const bin = atob(s);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

function toB64(bytes) {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

// The AAD text for one entry. One place, so the writer and the reader agree.
export function vaultAad(project, site, field) {
  return `web_vault\n${project}\n${site}\n${field}`;
}

async function keyOf(env, keyId) {
  const raw = fromB64(String((env && env[`WEB_VAULT_KEY_${keyId}`]) || "").trim());
  if (!raw || raw.length !== KEY_BYTES) return null;
  try {
    return await crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
  } catch {
    return null;
  }
}

// -> {ok:true, ciphertext, iv} (both base64) | {ok:false, why:"key missing"|"encrypt failed"}
export async function encryptValue(env, keyId, aad, value) {
  const key = await keyOf(env, keyId);
  if (!key) return { ok: false, why: "key missing" };
  try {
    const iv = crypto.getRandomValues(new Uint8Array(IV_BYTES));
    const ct = await crypto.subtle.encrypt(
      { name: "AES-GCM", iv, additionalData: new TextEncoder().encode(aad) }, key, new TextEncoder().encode(value));
    return { ok: true, ciphertext: toB64(new Uint8Array(ct)), iv: toB64(iv) };
  } catch {
    return { ok: false, why: "encrypt failed" };
  }
}

// -> {ok:true, value} | {ok:false, why:"key missing"|"decrypt failed"}
export async function decryptValue(env, keyId, aad, ivB64, ctB64) {
  const key = await keyOf(env, keyId);
  if (!key) return { ok: false, why: "key missing" };
  const iv = fromB64(ivB64), ct = fromB64(ctB64);
  if (!iv || iv.length !== IV_BYTES || !ct) return { ok: false, why: "decrypt failed" };
  try {
    const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv, additionalData: new TextEncoder().encode(aad) }, key, ct);
    return { ok: true, value: new TextDecoder("utf-8", { fatal: true }).decode(pt) };
  } catch {
    return { ok: false, why: "decrypt failed" };
  }
}
