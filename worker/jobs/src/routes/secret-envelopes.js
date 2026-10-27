// secret envelopes — a one-time ciphertext the hub reads once (BH-7964,
// BH-7937.0). A caller seals a secret to the hub's public key and stores the
// ciphertext here; the hub reads it once, and the read deletes the row. This
// worker holds no key and decrypts nothing: it only ever holds ciphertext.
// Note: docs/notes/2026-10-22-BH-7964-secret-envelopes.md.
//
// POST /api/secrets/envelope {scope, ciphertext}   (main bearer)
//   400 on a bad scope or a ciphertext that is not base64 of 344..1024 chars.
//   A scope is ai-account:<name>, tracker:<name>, or one of the fleet scopes
//   (BH-7976): fleet:fly:<org>, fleet:tailscale, fleet:tailscale:<project>,
//   fleet:telegram. bin/lib/envelope-fleet.sh parses the same fleet grammar,
//   and tests/fixtures/fleet-scopes.bh-7939.tsv is the one table both obey.
//   expires_at = now + settings secret_envelope_ttl_s (60..86400, else 900).
//   ONE batch: the row and its `stored` event. 200 {id, expires_at}, no-store.
// GET /api/secrets/envelope/:id   (main bearer AND x-envelope-hub-token)
//   503 when ENVELOPE_HUB_TOKEN is unset or blank (fail closed), 403 on a
//   wrong hub token, 404 on a bad id or no row. ONE DELETE … RETURNING reads
//   and deletes. An expired row is deleted, writes an `expired` event and
//   answers 404. Else a `consumed` event and 200 {id, scope, ciphertext}.
//   Exactly one path segment: /:id/status and /:id/confirm never match.
//
// No line here logs a ciphertext or a header value.
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";

// ?1 now, ?2 limit. ix_secret_envelopes_expires. The BH-7937.2 sweep reads it.
export const ENVELOPE_EXPIRED_SQL = "SELECT id FROM secret_envelopes WHERE expires_at < ?1 ORDER BY expires_at LIMIT ?2";

const TTL_DEFAULT_S = 900;
const SCOPE_RE = /^(ai-account|tracker):[a-z0-9._:@-]{1,96}$/;
// org: a Fly org slug. project: the harness project-name charset.
export const FLEET_SCOPE_RE = /^fleet:(fly:[a-z0-9][a-z0-9-]{0,62}|tailscale(:[a-z0-9_-][a-z0-9._-]{0,63})?|telegram)$/;
const B64_RE = /^[A-Za-z0-9+/]+={0,2}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const noStore = (status, body) => new Response(JSON.stringify(body), {
  status,
  headers: { "content-type": "application/json", "cache-control": "no-store" },
});
const isoAt = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

// True only when the x-envelope-hub-token header equals ENVELOPE_HUB_TOKEN,
// both trimmed. An unset or blank env token is false. Every byte is compared,
// and a length difference is folded in, so the time says nothing about where
// the first wrong byte is.
export function hubTokenOk(req, env) {
  const want = String(env?.ENVELOPE_HUB_TOKEN ?? "").trim();
  if (!want) return false;
  const got = String(req.headers.get("x-envelope-hub-token") ?? "").trim();
  const a = new TextEncoder().encode(want);
  const b = new TextEncoder().encode(got);
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}

export function checkEnvelopeScope(scope) {
  return typeof scope === "string" && (SCOPE_RE.test(scope) || FLEET_SCOPE_RE.test(scope)) && !scope.includes("..");
}

const ciphertextOk = (ct) =>
  typeof ct === "string" && ct.length >= 344 && ct.length <= 1024 && ct.length % 4 === 0 && B64_RE.test(ct);

// The audit row's INSERT, bound and not run, so POST can batch it with its row.
function eventStmt(db, envelopeId, scope, event, detail) {
  return db.prepare("INSERT INTO secret_envelope_events (envelope_id, scope, event, detail, at) VALUES (?1,?2,?3,?4,?5)")
    .bind(envelopeId ?? null, scope ?? null, event, detail == null ? null : String(detail).slice(0, 200), isoAt(Date.now()));
}

// One audit row. detail is a fixed reason word, capped at 200 chars; a caller
// never passes a ciphertext or a token.
export function envelopeEvent(db, envelopeId, scope, event, detail) {
  return eventStmt(db, envelopeId, scope, event, detail).run();
}

async function ensureTables(env) {
  await ensureTable(env, "secret_envelopes");
  await ensureTable(env, "secret_envelope_events");
}

// The settings row, or 900 when it is not an integer in 60..86400 (an
// operator typo of `9` must not kill envelopes before the hub tick).
async function ttlSeconds(db) {
  const v = String((await db.prepare("SELECT value FROM settings WHERE key='secret_envelope_ttl_s'").first("value")) ?? "").trim();
  if (!/^\d+$/.test(v)) return TTL_DEFAULT_S;
  const n = Number(v);
  return n >= 60 && n <= 86400 ? n : TTL_DEFAULT_S;
}

export const routes = [
  [
    "POST", "/api/secrets/envelope",
    ({ env, t, body }) => d1Guarded("secret_envelopes", async () => {
      const { scope, ciphertext } = body || {};
      if (!checkEnvelopeScope(scope)) return noStore(400, { error: "scope must be ai-account:<name>, tracker:<name> or a fleet: scope" });
      if (!ciphertextOk(ciphertext)) return noStore(400, { error: "ciphertext must be base64, 344..1024 chars" });
      await ensureTables(env);
      const ttl = await ttlSeconds(env.DB);
      const id = crypto.randomUUID();
      const expiresAt = isoAt(Date.parse(t) + ttl * 1000);
      await env.DB.batch([
        env.DB.prepare("INSERT INTO secret_envelopes (id, scope, ciphertext, created_at, expires_at) VALUES (?1,?2,?3,?4,?5)")
          .bind(id, scope, ciphertext, t, expiresAt),
        eventStmt(env.DB, id, scope, "stored", null),
      ]);
      return noStore(200, { id, expires_at: expiresAt });
    }),
  ],
  [
    "GET", /^\/api\/secrets\/envelope\/([^/]+)$/,
    ({ req, env, t, m }) => d1Guarded("secret_envelopes", async () => {
      if (!String(env.ENVELOPE_HUB_TOKEN ?? "").trim()) return noStore(503, { error: "envelope read not configured" });
      if (!hubTokenOk(req, env)) return noStore(403, { error: "forbidden" });
      const id = m[1];
      if (!UUID_RE.test(id)) return noStore(404, { error: "no envelope" });
      await ensureTables(env);
      const row = await env.DB.prepare("DELETE FROM secret_envelopes WHERE id=?1 RETURNING scope, ciphertext, expires_at").bind(id).first();
      if (!row) return noStore(404, { error: "no envelope" });
      if (row.expires_at <= t) {
        await envelopeEvent(env.DB, id, row.scope, "expired", null);
        return noStore(404, { error: "no envelope" });
      }
      await envelopeEvent(env.DB, id, row.scope, "consumed", null);
      return noStore(200, { id, scope: row.scope, ciphertext: row.ciphertext });
    }),
  ],
];
