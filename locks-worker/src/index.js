// harness-locks — cross-harness ticket/file lease service (the operator+reviewer-1, 2026-08-01).
// Leases, not locks: every acquire carries a TTL; expiry frees the key with no
// janitor. Contract doc: cromford docs/HARNESS-COORDINATION.md
//
// Auth, two lanes:
//   1. static per-harness bearer tokens in the HARNESS_TOKENS secret (JSON
//      {token: harnessName}) — the fleet boxes, unchanged;
//   2. minted per-machine tokens in the D1 `tokens` table (2026-08-05, partner
//      night-lane ask) — named, expiring, revocable. Only sha-256 hashes are
//      stored, so the mint response is the ONLY time a token is readable.
// Admin endpoints ride a SEPARATE ADMIN_TOKEN secret. A minted token can never
// mint or revoke — an open mint would let anyone who finds the URL issue valid
// lease credentials and poison cross-harness coordination.
function now() { return Math.floor(Date.now() / 1000); }
function json(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
async function sha256Hex(s) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function randomHex(bytes) {
  const a = crypto.getRandomValues(new Uint8Array(bytes));
  return [...a].map((b) => b.toString(16).padStart(2, "0")).join("");
}
export default {
  async fetch(req, env, ctx) {
    const auth = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    const url = new URL(req.url);
    const path = url.pathname;
    const t = now();

    // ── Admin lane (mint / revoke / list / log) ─────────────────────────────
    // Two admin identities (minter lane added 2026-08-21, collaborator-1 self-serve ask):
    //   * ADMIN_TOKEN secret — full power, incl. minting `minter` tokens.
    //   * a minted token with role='minter' — SCOPED delegation: may mint/list/
    //     revoke ONLY machine tokens whose name starts with its `prefix`
    //     (e.g. "partner-"), never another minter, never outside the prefix,
    //     capped at MINT_CAP mints per rolling 24h (deployed value 20, pinned in
    //     wrangler.jsonc `vars`; the code fallback when the var is unset is 5).
    //     It cannot hold leases (role check in the lease lane below), so a
    //     leaked minter credential cannot poison coordination — and it is
    //     itself expiring and revocable by name like any minted token. The
    //     master ADMIN_TOKEN is never handed outside: the answer to "give us
    //     a long-lived token that mints tokens" is this lane, with attribution
    //     and a kill switch.
    if (path.startsWith("/v1/admin/")) {
      let actor = null; // {name, prefix} — null means full admin
      if (env.ADMIN_TOKEN && auth === env.ADMIN_TOKEN) {
        actor = null;
      } else if (auth) {
        const m = await env.DB.prepare(
          "SELECT id, name, prefix, last_used_at FROM tokens WHERE token_hash=?1 AND role='minter' AND revoked_at IS NULL AND expires_at > ?2"
        ).bind(await sha256Hex(auth), t).first();
        if (!m || !m.prefix) return json(401, { error: "admin auth" });
        actor = { name: m.name, prefix: m.prefix };
        if (!m.last_used_at || t - m.last_used_at > 3600) {
          ctx.waitUntil(env.DB.prepare("UPDATE tokens SET last_used_at=?1 WHERE id=?2").bind(t, m.id).run());
        }
      } else {
        return json(401, { error: "admin auth" });
      }
      const actorName = actor ? actor.name : "admin";

      if (req.method === "GET" && path === "/v1/admin/tokens") {
        const rows = actor
          ? await env.DB.prepare(
              "SELECT id, name, role, prefix, created_by, created_at, expires_at, revoked_at, last_used_at FROM tokens WHERE role='machine' AND substr(name,1,length(?1))=?1 ORDER BY created_at DESC"
            ).bind(actor.prefix).all()
          : await env.DB.prepare(
              "SELECT id, name, role, prefix, created_by, created_at, expires_at, revoked_at, last_used_at FROM tokens ORDER BY created_at DESC"
            ).all();
        return json(200, { tokens: rows.results, as_of: t });
      }
      if (req.method === "GET" && path === "/v1/admin/log") {
        // Digest feed (hub cron): mint/revoke/lease history. Full admin only.
        if (actor) return json(403, { error: "admin only" });
        const since = Number(url.searchParams.get("since")) || t - 86400;
        const action = url.searchParams.get("action") || "";
        const rows = action
          ? await env.DB.prepare("SELECT key,holder,action,outcome,at FROM locks_log WHERE at > ?1 AND action=?2 ORDER BY at DESC LIMIT 200").bind(since, action).all()
          : await env.DB.prepare("SELECT key,holder,action,outcome,at FROM locks_log WHERE at > ?1 ORDER BY at DESC LIMIT 200").bind(since).all();
        return json(200, { log: rows.results, as_of: t });
      }
      if (req.method !== "POST") return json(405, { error: "method" });
      const body = await req.json().catch(() => ({}));
      if (path === "/v1/admin/tokens") {
        const name = String(body.name || "").trim().toLowerCase();
        if (!/^[a-z0-9][a-z0-9._-]{1,63}$/.test(name)) {
          return json(400, { error: "name required: 2-64 chars, [a-z0-9._-]" });
        }
        let role = body.role === "minter" ? "minter" : "machine";
        let prefix = null;
        if (actor) {
          // Minter constraints: machine tokens only, inside its prefix, rate-capped.
          if (body.role === "minter") return json(403, { error: "a minter cannot mint minters" });
          role = "machine";
          if (!name.startsWith(actor.prefix)) {
            return json(403, { error: `name must start with your prefix '${actor.prefix}'` });
          }
        } else if (role === "minter") {
          prefix = String(body.prefix || "").trim().toLowerCase();
          if (!/^[a-z0-9][a-z0-9._-]{0,31}$/.test(prefix)) {
            return json(400, { error: "minter requires prefix: 1-32 chars, [a-z0-9._-]" });
          }
          if (!name.startsWith(prefix)) {
            return json(400, { error: "minter name must start with its own prefix" });
          }
        }
        const ttlDays = Math.min(Math.max(Number(body.ttl_days) || 90, 1), 365);
        const token = randomHex(24);
        const id = crypto.randomUUID();
        const exp = t + ttlDays * 86400;
        const cap = actor ? Math.max(Number(env.MINT_CAP) || 5, 1) : null;
        // Admission and issuance are one conditional write. Counting issued
        // rows also keeps revocation or log retention from resetting the cap.
        // D1 batches transact both writes: a failed audit rolls issuance back.
        const [issued] = await env.DB.batch([
          env.DB.prepare(
            `INSERT INTO tokens (id, name, token_hash, created_by, created_at, expires_at, role, prefix)
             SELECT ?1,?2,?3,?4,?5,?6,?7,?8
             WHERE ?9 IS NULL OR (SELECT COUNT(*) FROM tokens WHERE created_by=?4 AND created_at > ?10) < ?9`
          ).bind(id, name, await sha256Hex(token), actor ? actor.name : String(body.created_by || "admin").slice(0, 64), t, exp, role, prefix, cap, t - 86400),
          env.DB.prepare("INSERT INTO locks_log (key,holder,action,at) SELECT name,?2,'token-mint',?3 FROM tokens WHERE id=?1")
            .bind(id, actorName, t),
        ]);
        if (issued.meta.changes === 0) {
          return json(429, { error: `mint cap ${cap}/24h reached`, retry_after_s: 86400 });
        }
        // The one and only time the token is returned.
        return json(201, { id, name, token, role, prefix, expires_at: exp, ttl_days: ttlDays });
      }
      if (path === "/v1/admin/revoke") {
        const { id = "", name = "" } = body;
        if (!id && !name) return json(400, { error: "id or name required" });
        let r;
        if (actor) {
          // Minter may revoke only machine tokens inside its prefix.
          if (id) {
            const row = await env.DB.prepare("SELECT name, role FROM tokens WHERE id=?1").bind(id).first();
            if (!row || row.role !== "machine" || !row.name.startsWith(actor.prefix)) {
              return json(403, { error: "outside your prefix" });
            }
            r = await env.DB.prepare("UPDATE tokens SET revoked_at=?1 WHERE id=?2 AND revoked_at IS NULL").bind(t, id).run();
          } else {
            const nm = String(name).toLowerCase();
            if (!nm.startsWith(actor.prefix)) return json(403, { error: "outside your prefix" });
            r = await env.DB.prepare("UPDATE tokens SET revoked_at=?1 WHERE name=?2 AND role='machine' AND revoked_at IS NULL").bind(t, nm).run();
          }
        } else {
          r = id
            ? await env.DB.prepare("UPDATE tokens SET revoked_at=?1 WHERE id=?2 AND revoked_at IS NULL").bind(t, id).run()
            : await env.DB.prepare("UPDATE tokens SET revoked_at=?1 WHERE name=?2 AND revoked_at IS NULL").bind(t, String(name).toLowerCase()).run();
        }
        await env.DB.prepare("INSERT INTO locks_log (key,holder,action,at) VALUES (?1,?2,'token-revoke',?3)")
          .bind(id || name, actorName, t).run();
        return json(200, { revoked: r.meta.changes });
      }
      return json(404, { error: "unknown admin endpoint" });
    }

    // ── Harness auth: static secret first, then minted-token lookup ──
    let tokens = {};
    try {
      const parsed = JSON.parse(env.HARNESS_TOKENS || "{}");
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)
          && Object.values(parsed).every((value) => typeof value === "string" && value.trim())) tokens = parsed;
    } catch {}
    let harness = auth && Object.hasOwn(tokens, auth) ? tokens[auth] : null;
    if (!harness && auth) {
      // role='machine' only: a minter credential administers tokens, it never
      // holds leases — lane separation keeps a leaked minter out of coordination.
      const row = await env.DB.prepare(
        "SELECT id, name, last_used_at FROM tokens WHERE token_hash=?1 AND role='machine' AND revoked_at IS NULL AND expires_at > ?2"
      ).bind(await sha256Hex(auth), t).first();
      if (row) {
        harness = row.name;
        // Best-effort usage stamp, at most hourly — never on the request path.
        if (!row.last_used_at || t - row.last_used_at > 3600) {
          ctx.waitUntil(env.DB.prepare("UPDATE tokens SET last_used_at=?1 WHERE id=?2").bind(t, row.id).run());
        }
      }
    }
    if (!harness) return json(401, { error: "unknown harness token" });

    if (req.method === "GET" && path === "/v1/locks") {
      const prefix = url.searchParams.get("prefix") || "";
      const rows = await env.DB.prepare(
        "SELECT key, kind, holder, expires_at, acquired_at FROM locks WHERE expires_at > ?1 AND key LIKE ?2 ORDER BY key"
      ).bind(t, prefix + "%").all();
      return json(200, { locks: rows.results, as_of: t });
    }

    if (req.method !== "POST") return json(405, { error: "method" });
    const body = await req.json().catch(() => ({}));

    if (path === "/v1/acquire") {
      const { kind = "ticket", key, ttl_s = 7200 } = body;
      if (!key) return json(400, { error: "key required" });
      const exp = t + Math.min(Math.max(ttl_s, 60), 86400);
      const lease = crypto.randomUUID();
      // Atomic: insert fresh, or steal only if expired, or renew if we hold it.
      const r = await env.DB.prepare(
        `INSERT INTO locks (key, kind, holder, lease_id, expires_at, acquired_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(key) DO UPDATE SET holder=?3, lease_id=?4, expires_at=?5, acquired_at=?6
           WHERE locks.expires_at <= ?6 OR locks.holder = ?3`
      ).bind(key, kind, harness, lease, exp, t).run();
      if (r.meta.changes === 0) {
        const cur = await env.DB.prepare("SELECT holder, expires_at FROM locks WHERE key=?1").bind(key).first();
        return json(409, { error: "held", holder: cur?.holder, expires_at: cur?.expires_at });
      }
      await env.DB.prepare("INSERT INTO locks_log (key,holder,action,at) VALUES (?1,?2,'acquire',?3)").bind(key, harness, t).run();
      return json(201, { lease_id: lease, key, holder: harness, expires_at: exp });
    }

    if (path === "/v1/renew") {
      const { key, lease_id, ttl_s = 7200 } = body;
      const exp = t + Math.min(Math.max(ttl_s, 60), 86400);
      const r = await env.DB.prepare(
        "UPDATE locks SET expires_at=?1 WHERE key=?2 AND lease_id=?3 AND holder=?4"
      ).bind(exp, key, lease_id, harness).run();
      if (r.meta.changes === 0) return json(404, { error: "no such lease (expired or stolen)" });
      return json(200, { key, expires_at: exp });
    }

    if (path === "/v1/release") {
      const { key, lease_id, outcome = "" } = body;
      if (!key) return json(400, { error: "key required" });
      // lease_id optional (2026-08-02): fleet sessions release by key+outcome;
      // holder is token-authenticated, so deleting own lock by key is safe.
      // Binding undefined into D1 threw (CF 1101) — medic finding.
      const r = lease_id
        ? await env.DB.prepare("DELETE FROM locks WHERE key=?1 AND lease_id=?2 AND holder=?3").bind(key, lease_id, harness).run()
        : await env.DB.prepare("DELETE FROM locks WHERE key=?1 AND holder=?2").bind(key, harness).run();
      await env.DB.prepare("INSERT INTO locks_log (key,holder,action,outcome,at) VALUES (?1,?2,'release',?3,?4)")
        .bind(key, harness, outcome.slice(0, 200), now()).run();
      if (r.meta.changes === 0) return json(404, { error: "no such lease" });
      return json(200, { key, released: true });
    }

    return json(404, { error: "unknown endpoint" });
  }
};
