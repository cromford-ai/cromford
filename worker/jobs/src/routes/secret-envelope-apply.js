// secret envelope apply — the hub half of the one-time secret envelope
// (BH-7965, BH-7937.2). The hub lists the envelopes it has to read, reads each
// one through the BH-7964 GET (secret-envelopes.js), applies the secret to its
// boxes and confirms the outcome here. An hourly sweep removes what nobody read
// and archives old audit rows. Doc: docs/SECRETS-ENVELOPE.md.
//
// GET /api/secrets/envelope?state=pending[&limit=n]   (main bearer AND hub token)
//   503 when ENVELOPE_HUB_TOKEN is unset or blank, 403 on a wrong hub token.
//   400 unless state=pending and limit is an integer 1..100 (absent = 20).
//   200 {envelopes:[{id, scope}], truncated}: live rows, soonest expiry first.
//   Never the ciphertext.
// POST /api/secrets/envelope/:id/confirm {ok, detail}   (main bearer AND hub token)
//   404 on a bad id or an envelope with no `consumed` event. 400 unless ok is a
//   boolean and detail a string of [A-Za-z0-9 =/:._,@-], 200 chars max.
//   409 when the envelope already has an applied or apply_failed event.
//   Else ONE `applied` / `apply_failed` event and 200 {id, event}. No other table.
// POST /api/secrets/envelope/sweep {dry_run}   (main bearer)
//   400 when dry_run is there and not a boolean; absent = a dry run.
//   Deletes expired envelopes (dead ciphertext) and archives, then deletes,
//   events older than the retention row. A dry run deletes nothing and counts
//   what it would delete. Exactly ONE `sweep` event per 200, detail
//   {dry_run, envelopes, events, archive, more}; the answer has the same fields.
// PUT /api/secrets/envelope/public-key {pem}   (main bearer AND hub token)
//   400 unless pem is one PUBLIC KEY block of base64 lines, 1200 chars max, with
//   no PRIVATE. Upserts settings hub_envelope_public_key (actor envelope-keygen)
//   and writes ONE `public_key_set` event (detail = 16 hex of its SHA-256).
//   PUT /api/settings caps a value at 256 chars; a 4096-bit PEM is ~800.
//
// No line here logs a body, a header or a key.
import { hubTokenOk, envelopeEvent, ENVELOPE_EXPIRED_SQL } from "./secret-envelopes.js";
import { d1Guarded } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { archiveBound, ensureArchiveTable, archiveCopy } from "../lib/archive.js";

export { ENVELOPE_EXPIRED_SQL };
// ?1 now, ?2 limit+1. ix_secret_envelopes_expires.
export const PENDING_SQL = "SELECT id, scope FROM secret_envelopes WHERE expires_at > ?1 ORDER BY expires_at LIMIT ?2";
// ?1 envelope id. ix_secret_envelope_events_env.
export const CONFIRM_LOOKUP_SQL =
  "SELECT event, scope FROM secret_envelope_events WHERE envelope_id = ?1 AND event IN ('consumed','applied','apply_failed')";
// ?1 cutoff, ?2 limit. ix_secret_envelope_events_at.
export const EVENTS_OLD_SQL = "SELECT * FROM secret_envelope_events WHERE at < ?1 ORDER BY at LIMIT ?2";

// Fallback of the lane knob SECRETS_APPLY_BATCH (settings row
// lane.secrets-apply.secrets_apply_batch); the hub always sends its own limit.
const PENDING_LIMIT_DEFAULT = 20;
// The max of that knob's declared range (catalog/lanes.d/secrets-apply.json,
// 1..100): a request-format bound, so a typo cannot list a whole table.
const PENDING_LIMIT_MAX = 100;
// Fallback of settings row secret_envelope_events_retention_days (1..3650).
const RETENTION_DAYS_DEFAULT = 90;
// Fallback of settings row secret_envelope_sweep_batch (1..5000).
const SWEEP_BATCH_DEFAULT = 500;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const DETAIL_RE = /^[A-Za-z0-9 =/:._,@-]{0,200}$/;
const PEM_RE = /^-----BEGIN PUBLIC KEY-----\n(?:[A-Za-z0-9+/=]{1,76}\n)+-----END PUBLIC KEY-----\n?$/;
// A format bound, like the BH-7964 ciphertext bound: a 4096-bit SPKI PEM is
// about 800 chars, so 1200 holds one key and nothing else.
const PEM_MAX = 1200;

const noStore = (status, body) => new Response(JSON.stringify(body), {
  status,
  headers: { "content-type": "application/json", "cache-control": "no-store" },
});
const isoAt = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

// The hub gate the BH-7964 GET uses: 503 unset or blank, 403 wrong. null = pass.
function hubGate(req, env) {
  if (!String(env.ENVELOPE_HUB_TOKEN ?? "").trim()) return noStore(503, { error: "envelope read not configured" });
  if (!hubTokenOk(req, env)) return noStore(403, { error: "forbidden" });
  return null;
}

async function ensureTables(env) {
  await ensureTable(env, "secret_envelopes");
  await ensureTable(env, "secret_envelope_events");
}

// A settings row read as an integer in lo..hi, else the fallback.
async function intSetting(db, key, lo, hi, fallback) {
  const v = String((await db.prepare("SELECT value FROM settings WHERE key=?1").bind(key).first("value")) ?? "").trim();
  if (!/^\d+$/.test(v)) return fallback;
  const n = Number(v);
  return n >= lo && n <= hi ? n : fallback;
}

async function sha16(text) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 16);
}

const idsJson = (rows) => JSON.stringify(rows.map((r) => r.id));

export const routes = [
  [
    "GET", "/api/secrets/envelope",
    ({ req, env, t, url }) => {
      const gate = hubGate(req, env);
      if (gate) return gate;
      if (url.searchParams.get("state") !== "pending") return noStore(400, { error: "state must be pending" });
      let limit = PENDING_LIMIT_DEFAULT;
      const raw = url.searchParams.get("limit");
      if (raw !== null) {
        if (!/^\d+$/.test(raw) || Number(raw) < 1 || Number(raw) > PENDING_LIMIT_MAX) {
          return noStore(400, { error: `limit must be an integer 1..${PENDING_LIMIT_MAX}` });
        }
        limit = Number(raw);
      }
      return d1Guarded("secret_envelopes", async () => {
        await ensureTables(env);
        const rows = (await env.DB.prepare(PENDING_SQL).bind(t, limit + 1).all()).results || [];
        return noStore(200, {
          envelopes: rows.slice(0, limit).map((r) => ({ id: r.id, scope: r.scope })),
          truncated: rows.length > limit,
        });
      });
    },
  ],
  [
    "POST", /^\/api\/secrets\/envelope\/([^/]+)\/confirm$/,
    ({ req, env, m, body }) => {
      const gate = hubGate(req, env);
      if (gate) return gate;
      const id = m[1];
      if (!UUID_RE.test(id)) return noStore(404, { error: "no envelope" });
      const { ok, detail } = body || {};
      if (typeof ok !== "boolean") return noStore(400, { error: "ok must be a boolean" });
      if (typeof detail !== "string" || !DETAIL_RE.test(detail)) {
        return noStore(400, { error: "detail must be a string of [A-Za-z0-9 =/:._,@-], 200 chars max" });
      }
      return d1Guarded("secret_envelopes", async () => {
        await ensureTables(env);
        const evs = (await env.DB.prepare(CONFIRM_LOOKUP_SQL).bind(id).all()).results || [];
        const consumed = evs.find((e) => e.event === "consumed");
        if (!consumed) return noStore(404, { error: "no envelope" });
        if (evs.some((e) => e.event === "applied" || e.event === "apply_failed")) {
          return noStore(409, { error: "already confirmed" });
        }
        const event = ok ? "applied" : "apply_failed";
        await envelopeEvent(env.DB, id, consumed.scope, event, detail);
        return noStore(200, { id, event });
      });
    },
  ],
  [
    "POST", "/api/secrets/envelope/sweep",
    ({ env, t, body }) => {
      const b = body || {};
      if ("dry_run" in b && typeof b.dry_run !== "boolean") return noStore(400, { error: "dry_run must be a boolean" });
      const dry = b.dry_run !== false;
      return d1Guarded("secret_envelopes", async () => {
        await ensureTables(env);
        const days = await intSetting(env.DB, "secret_envelope_events_retention_days", 1, 3650, RETENTION_DAYS_DEFAULT);
        const batch = await intSetting(env.DB, "secret_envelope_sweep_batch", 1, 5000, SWEEP_BATCH_DEFAULT);
        const expired = (await env.DB.prepare(ENVELOPE_EXPIRED_SQL).bind(t, batch).all()).results || [];
        const cutoff = isoAt(Date.parse(t) - days * 86400e3);
        const old = (await env.DB.prepare(EVENTS_OLD_SQL).bind(cutoff, batch).all()).results || [];
        let envelopes = expired.length;
        let events = old.length;
        let archive = "dry";
        if (!dry) {
          // Expired envelopes go whatever the archive says: dead ciphertext, not history.
          envelopes = 0;
          if (expired.length) {
            const r = await env.DB.prepare("DELETE FROM secret_envelopes WHERE id IN (SELECT value FROM json_each(?1))")
              .bind(idsJson(expired)).run();
            envelopes = Number(r?.meta?.changes ?? 0);
          }
          events = 0;
          if (!archiveBound(env)) archive = "not bound";
          else {
            let copied = false;
            try {
              if (old.length) {
                await ensureArchiveTable(env, "secret_envelope_events");
                copied = await archiveCopy(env, "secret_envelope_events", old, t);
              } else copied = true;
            } catch {
              copied = false;
            }
            archive = copied ? "ok" : "failed";
            if (copied && old.length) {
              const r = await env.DB.prepare("DELETE FROM secret_envelope_events WHERE id IN (SELECT value FROM json_each(?1))")
                .bind(idsJson(old)).run();
              events = Number(r?.meta?.changes ?? 0);
            }
          }
        }
        const out = { dry_run: dry, envelopes, events, archive, more: expired.length === batch || old.length === batch };
        await envelopeEvent(env.DB, null, null, "sweep", JSON.stringify(out));
        return noStore(200, out);
      });
    },
  ],
  [
    "PUT", "/api/secrets/envelope/public-key",
    ({ req, env, t, body }) => {
      const gate = hubGate(req, env);
      if (gate) return gate;
      const pem = (body || {}).pem;
      if (typeof pem !== "string" || pem.length > PEM_MAX || pem.includes("PRIVATE") || !PEM_RE.test(pem)) {
        return noStore(400, { error: `pem must be one PUBLIC KEY block, ${PEM_MAX} chars max` });
      }
      return d1Guarded("secret_envelopes", async () => {
        await ensureTables(env);
        const fingerprint = await sha16(pem);
        await env.DB.prepare(
          "INSERT INTO settings (key, value, note, actor, updated_at) VALUES ('hub_envelope_public_key', ?1, 'BH-7964: the hub public key a caller seals an envelope to', 'envelope-keygen', ?2) " +
          "ON CONFLICT(key) DO UPDATE SET value=excluded.value, actor=excluded.actor, updated_at=excluded.updated_at"
        ).bind(pem, t).run();
        await envelopeEvent(env.DB, null, null, "public_key_set", fingerprint);
        return noStore(200, { key: "hub_envelope_public_key", fingerprint });
      });
    },
  ],
];
