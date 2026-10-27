// fleet accounts — the fleet-wide secrets a person saves on the console: the
// Telegram bot token, the Fly org token, the fleet Tailscale key (BH-7976,
// BH-7939.2). A token never reaches this worker. The console seals it to the
// hub key and stores the ciphertext as a BH-7964 envelope with a `fleet:` scope
// (secret-envelopes.js); this route only records which envelope is the bot's.
// Note: docs/notes/2026-10-25-BH-7976-fleet-accounts.md.
//
// POST /api/fleet/accounts/telegram {envelope_id}   (main bearer, index.js)
//   400, before any D1 call, when the body is not an object with exactly the
//   key envelope_id (a `token` or `bot_token` key is refused whatever its
//   value), or the id is not a lower-case uuid.
//   ONE batch of two reads: the `stored` scope and the envelope state. 400
//   when there is no stored event, the scope is not exactly fleet:telegram,
//   the newest event is expired or apply_failed, or the row is past expires_at.
//   ONE batch of two settings upserts: telegram.envelope_id=<id> and
//   telegram.state=pending. 200 {envelope_id, state:'pending'}, no-store.
//   It never writes telegram.chat_id or telegram.bot_present: the hub does.
//
// No line here logs the body, and no error text repeats a body value.
import { d1Guarded } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { invalidateSettings } from "../lib/settings-cache.js";
import { STORED_SCOPE_SQL } from "./ai-accounts.js";

export { STORED_SCOPE_SQL };
// ?1 envelope id. The newest event (ix_secret_envelope_events_env) and the
// live row's expiry (secret_envelopes PK). Two scalar reads, no correlation.
export const STATE_SQL =
  "SELECT (SELECT event FROM secret_envelope_events WHERE envelope_id = ?1 ORDER BY id DESC LIMIT 1) AS event, "
  + "(SELECT expires_at FROM secret_envelopes WHERE id = ?1) AS expires_at";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const DEAD_EVENTS = new Set(["expired", "apply_failed"]);
const ACTOR = "fleet-accounts";
const UPSERT_SQL =
  `INSERT INTO settings (key, value, note, actor, updated_at) VALUES (?1,?2,?3,?4,?5)
   ON CONFLICT(key) DO UPDATE SET value=?2, note=?3, actor=?4, updated_at=?5`;

const noStore = (status, body) => new Response(JSON.stringify(body), {
  status,
  headers: { "content-type": "application/json", "cache-control": "no-store" },
});

// The body rule: a plain object whose only key is envelope_id. Returns an
// error string or null. The text never holds a body value.
function bodyError(body) {
  if (body === null || typeof body !== "object" || Array.isArray(body)) return "send {envelope_id}";
  const keys = Object.keys(body);
  if (keys.includes("token") || keys.includes("bot_token")) return "send the token sealed in an envelope, never in the body";
  if (keys.length !== 1 || keys[0] !== "envelope_id") return "send {envelope_id} and no other field";
  if (typeof body.envelope_id !== "string" || !UUID_RE.test(body.envelope_id)) return "no such envelope";
  return null;
}

export const routes = [
  [
    "POST", "/api/fleet/accounts/telegram",
    ({ env, t, body }) => d1Guarded("settings", async () => {
      const err = bodyError(body);
      if (err) return noStore(400, { error: err });
      const id = body.envelope_id;
      await ensureTable(env, "secret_envelopes");
      await ensureTable(env, "secret_envelope_events");
      const db = env.DB;
      const [scopeRes, stateRes] = await db.batch([
        db.prepare(STORED_SCOPE_SQL).bind(id),
        db.prepare(STATE_SQL).bind(id),
      ]);
      const scope = scopeRes.results?.[0]?.scope;
      if (scope === undefined || scope === null) return noStore(400, { error: "no such envelope" });
      if (scope !== "fleet:telegram") return noStore(400, { error: "the envelope was not sealed for the Telegram bot" });
      const { event, expires_at: expiresAt } = stateRes.results?.[0] || {};
      if (DEAD_EVENTS.has(event) || (expiresAt && expiresAt <= t)) {
        return noStore(400, { error: "the envelope expired or failed: save the token again" });
      }
      const note = "BH-7976: the envelope that carries the Telegram bot token";
      await db.batch([
        db.prepare(UPSERT_SQL).bind("telegram.envelope_id", id, note, ACTOR, t),
        db.prepare(UPSERT_SQL).bind("telegram.state", "pending", note, ACTOR, t),
      ]);
      invalidateSettings(env);
      return noStore(200, { envelope_id: id, state: "pending" });
    }),
  ],
];
