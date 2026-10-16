// pauses routes — BH-1682 (BH-1672.1): a pause is a row with a reason, an actor
// and an expiry, so nothing stays paused because somebody forgot it.
//
// The table, its pauses_live partial unique index and the pause_default_ttl_s
// settings seed shipped in BH-1681 (schema.sql). bin/lib/pause.sh is the box-side
// reader, and its header is the wire contract these four routes answer.
//
// ONE TIMESTAMP SHAPE. Every value this file writes goes through isoZ(), so it is
// YYYY-MM-DDTHH:MM:SSZ, the same shape as nowIso(). "Live" is the SQL string
// comparison `expires_at > now`, which is only a time comparison while every
// stored value has that one shape (the operator, #1868 review).
//
// LIVE IS JUDGED AT READ TIME. A row is live while ended_at IS NULL and
// expires_at > now. An unended row past its expiry is not live to any route here,
// so no janitor has to run before a pause stops holding; /expire only stamps the
// record so it says what happened.

import { json, d1Guarded } from "../lib/http.js";

// Mirrors the schema's CHECK(what IN (...)).
const WHATS = ["reviews", "merges", "builds", "triage"];
// 'fleet' or a project name. The flags routes' legal set, for the same reason:
// a scope is read back as a key on every box.
const SCOPE_RE = /^[A-Za-z0-9._-]+$/;
const SCOPE_MAX = 128;
// The ticket's clamp: a pause lives at least a minute and at most a week.
const TTL_MIN = 60;
const TTL_MAX = 604800;
// Fallback only, for a pause_default_ttl_s row that is absent or unusable.
const TTL_FALLBACK = 86400;
const CAP = 500;

function isoZ(ms) { return new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z"); }

function scopeOk(s) { return typeof s === "string" && s.length <= SCOPE_MAX && SCOPE_RE.test(s); }

async function defaultTtl(env) {
  try {
    const v = await env.DB.prepare("SELECT value FROM settings WHERE key='pause_default_ttl_s'").first("value");
    const n = Number(v);
    if (typeof v === "string" && /^\d+$/.test(v.trim()) && Number.isInteger(n) && n > 0) return n;
  } catch { /* settings unreadable: the fallback below */ }
  return TTL_FALLBACK;
}

export const routes = [
  // ── Pauses (BH-1672) ─────────────────────────────────────────────────────
  // ?active=1 → live rows only; ?active=0 or absent → every row. ?scope=X is a
  // literal match (the box reader ORs 'fleet' in itself). Newest first, capped.
  [
    "GET", "/api/pauses",
    async ({ env, url, t }) => d1Guarded("pauses", async () => {
      const active = url.searchParams.get("active");
      if (active !== null && active !== "0" && active !== "1") return json(400, { error: "active must be 0 or 1" });
      const scope = url.searchParams.get("scope");
      if (scope !== null && !scopeOk(scope)) return json(400, { error: "valid scope required" });
      const where = [];
      const binds = [];
      if (active === "1") { binds.push(t); where.push(`ended_at IS NULL AND expires_at > ?${binds.length}`); }
      if (scope !== null) { binds.push(scope); where.push(`scope = ?${binds.length}`); }
      // sql-ident-ok: where holds literal column clauses with ?N binds; CAP is a module number const
      const rows = (await env.DB.prepare(
        `SELECT * FROM pauses${where.length ? " WHERE " + where.join(" AND ") : ""} ORDER BY id DESC LIMIT ${CAP + 1}`
      ).bind(...binds).all()).results || [];
      return json(200, { pauses: rows.slice(0, CAP), truncated: rows.length > CAP, as_of: t });
    }),
  ],

  // Creates the live pause for (scope, what) or renews it: a renew keeps the id
  // and created_at and sets expires_at to now + ttl (shorter is allowed).
  [
    "PUT", "/api/pauses",
    async ({ env, t, body }) => d1Guarded("pauses", async () => {
      const scope = typeof body.scope === "string" ? body.scope.trim() : "";
      if (!scopeOk(scope)) return json(400, { error: "valid scope required" });
      if (!WHATS.includes(body.what)) return json(400, { error: `what must be one of ${WHATS.join("|")}` });
      const reason = typeof body.reason === "string" ? body.reason.trim().slice(0, 512) : "";
      if (!reason) return json(400, { error: "reason required" });
      const actor = typeof body.actor === "string" ? body.actor.trim().slice(0, 128) : "";
      if (!actor) return json(400, { error: "actor required" });

      const now = Date.parse(t);
      let ttl;
      if (body.ttl_s !== undefined && body.ttl_s !== null) {
        ttl = typeof body.ttl_s === "number" ? body.ttl_s : NaN;
        if (!Number.isFinite(ttl)) return json(400, { error: "ttl_s must be a number of seconds" });
      } else if (body.expires_at !== undefined && body.expires_at !== null) {
        const at = typeof body.expires_at === "string" ? Date.parse(body.expires_at) : NaN;
        if (!Number.isFinite(at)) return json(400, { error: "expires_at must be an ISO-8601 time" });
        ttl = (at - now) / 1000;
      } else {
        ttl = await defaultTtl(env);
      }
      ttl = Math.min(TTL_MAX, Math.max(TTL_MIN, Math.round(ttl)));
      const expiresAt = isoZ(now + ttl * 1000);

      // An unended row already past its expiry is not live, but it still holds
      // the pauses_live index. Stamp it expired first, so the upsert below
      // creates a fresh row instead of reviving a pause that already ran out.
      await env.DB.prepare(
        `UPDATE pauses SET ended_at=expires_at, end_reason='expired'
         WHERE scope=?1 AND what=?2 AND ended_at IS NULL AND expires_at <= ?3`
      ).bind(scope, body.what, t).run();
      // Create or renew in ONE statement, so two racing PUTs cannot both insert.
      const rows = (await env.DB.prepare(
        `INSERT INTO pauses (scope, what, reason, actor, created_at, expires_at) VALUES (?1,?2,?3,?4,?5,?6)
         ON CONFLICT(scope, what) WHERE ended_at IS NULL
         DO UPDATE SET expires_at=excluded.expires_at, reason=excluded.reason, actor=excluded.actor
         RETURNING *`
      ).bind(scope, body.what, reason, actor, t, expiresAt).all()).results || [];
      if (!rows.length) return json(503, { error: "pauses unavailable", detail: "upsert returned no row" });
      return json(200, { pause: rows[0] });
    }),
  ],

  // Stamps due rows ended_at=expires_at and returns exactly the rows THIS call
  // stamped: the outer `ended_at IS NULL` means a second or concurrent caller
  // gets [] for the same row. At most CAP per call; the rest wait for the next.
  [
    "POST", "/api/pauses/expire",
    async ({ env, t }) => d1Guarded("pauses", async () => {
      // sql-ident-ok: CAP is a module number const
      const rows = (await env.DB.prepare(
        `UPDATE pauses SET ended_at=expires_at, end_reason='expired'
         WHERE id IN (SELECT id FROM pauses WHERE ended_at IS NULL AND expires_at <= ?1 ORDER BY id LIMIT ${CAP})
           AND ended_at IS NULL
         RETURNING *`
      ).bind(t).all()).results || [];
      return json(200, { expired: rows, as_of: t });
    }),
  ],

  // Resume: ends a LIVE row only. Ended, already expired or unknown → 404.
  [
    "POST", /^\/api\/pauses\/(\d+)\/end$/,
    async ({ env, t, m }) => d1Guarded("pauses", async () => {
      const rows = (await env.DB.prepare(
        `UPDATE pauses SET ended_at=?1, end_reason='resumed'
         WHERE id=?2 AND ended_at IS NULL AND expires_at > ?1
         RETURNING *`
      ).bind(t, Number(m[1])).all()).results || [];
      if (!rows.length) return json(404, { error: "pause not live" });
      return json(200, { pause: rows[0] });
    }),
  ],
];
