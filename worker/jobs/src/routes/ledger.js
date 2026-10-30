// ledger routes — the append-only build ledger.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// Since then GET /api/ledger's list has gained the BH-2450 `before_key` cursor.
// BH-8735 added an optional exact `status` filter to that list.
// GET with a key now falls back to the archive store for listed kinds (BH-6780).
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import {
  str, jobId, isoPlusSeconds,
} from "../lib/core.js";
import { ledgerArchiveLookup } from "../lib/ledger-archive.js";
import { claimArchiveGuard } from "../lib/ledger-archive-claim.js";

export const routes = [
  // ── Ledgers (phase 2) ──────────────────────────────────────────────────
  // merge-sweep and migration-autopilot used per-hub text files. Those stay
  // as write-through fallback; this table is what a rebuilt hub, a second
  // writer, or the console actually consults. GET with a key 404s when the
  // row is absent (a real answer, not an outage). GET without a key lists.
  [
    "GET", "/api/ledger",
    async ({ env, url, t }) => {
      const kind = (url.searchParams.get("kind") || "").trim();
      const key = url.searchParams.get("key");
      if (!kind) return json(400, { error: "kind required" });
      if (key !== null && key !== "") {
        const row = await env.DB.prepare("SELECT * FROM ledgers WHERE kind=?1 AND key=?2")
          .bind(kind, key).first();
        if (!row) {
          const a = await ledgerArchiveLookup(env, kind, key);
          if (a.status === 200) return json(200, { ledger: a.row, archived: true });
          if (a.status === 503) return json(503, { error: a.error });
          return json(404, { error: "not found" });
        }
        return json(200, { ledger: row });
      }
      // A positive integer: `limit=-1` used to build `LIMIT -1`, which is no limit at all.
      const lim = Math.min(Math.max(Math.floor(Number(url.searchParams.get("limit"))) || 200, 1), 1000);
      const before = str(url.searchParams.get("before"), 32);
      // BH-2450: updated_at has 1-second resolution, so `before` alone skips
      // every row sharing the page's last second. `before` + `before_key` (the
      // last row's updated_at and key) is a compound cursor over the same
      // order, `updated_at DESC, key DESC`. `before` alone keeps the legacy
      // strict predicate for callers that have not moved.
      const beforeKey = url.searchParams.get("before_key") || "";
      if (beforeKey && !before) return json(400, { error: "before_key requires before" });
      if (beforeKey.length > 512) return json(400, { error: "before_key longer than a key" });
      const where = ["kind=?1"];
      const binds = [kind];
      // BH-8735: an optional exact status (the infra collector's BLOCKED_HUMAN
      // parks). idx_ledgers_kind_status_updated serves it; no status keeps the
      // query text as it was.
      const status = str(url.searchParams.get("status"), 64);
      if (status) { binds.push(status); where.push(`status=?${binds.length}`); }
      if (before && beforeKey) {
        binds.push(before, beforeKey);
        const b = binds.length - 1, k = binds.length;
        where.push(`(updated_at<?${b} OR (updated_at=?${b} AND key<?${k}))`);
      } else if (before) {
        binds.push(before); where.push(`updated_at<?${binds.length}`);
      }
      // sql-ident-ok: where holds literal predicates with ?N binds; lim is a clamped integer
      const rows = await env.DB.prepare(
        `SELECT * FROM ledgers WHERE ${where.join(" AND ")} ORDER BY updated_at DESC, key DESC LIMIT ${lim}`
      ).bind(...binds).all();
      return json(200, { ledgers: rows.results, as_of: t });
    },
  ],

  [
    "PUT", "/api/ledger",
    async ({ env, t, body }) => {
      const kind = String(body.kind || "").trim().slice(0, 32);
      const key = String(body.key || "").trim().slice(0, 512);
      const status = String(body.status || "").trim().slice(0, 128);
      if (!kind || !key || !status) return json(400, { error: "kind, key and status are required" });
      const actor = body.actor ? String(body.actor).slice(0, 128) : null;
      const jobId = body.job_id ? String(body.job_id).slice(0, 256) : null;
      const detail = body.detail ? String(body.detail).slice(0, 4000) : null;
      await env.DB.prepare(
        `INSERT INTO ledgers (kind, key, status, job_id, actor, detail, created_at, updated_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?7)
         ON CONFLICT(kind, key) DO UPDATE SET
           status=?3,
           job_id=COALESCE(?4, job_id),
           actor=COALESCE(?5, actor),
           detail=COALESCE(?6, detail),
           updated_at=?7`
      ).bind(kind, key, status, jobId, actor, detail, t).run();
      const row = await env.DB.prepare("SELECT * FROM ledgers WHERE kind=?1 AND key=?2")
        .bind(kind, key).first();
      return json(200, { ledger: row });
    },
  ],

  // BH-5003: the compare-and-set the blind PUT above cannot give. Two hubs
  // ticking in the same second around a lease handover both read "not sent"
  // and both sent the daily digest; a build note read on two boxes was used
  // twice. ONE statement decides: the row is taken when it is absent, or when
  // its status is not terminal AND (it holds a different status, or the same
  // status older than stale_s). `claimed` is D1's own changes count, and the
  // row is re-read so the answer is what the table holds, never what the
  // caller hoped to write. The cutoff is the worker's clock, never the box's.
  [
    "POST", "/api/ledger/claim",
    async ({ env, t, body }) => {
      const kind = String(body.kind || "").trim().slice(0, 32);
      const key = String(body.key || "").trim().slice(0, 512);
      const status = String(body.status || "").trim().slice(0, 128);
      if (!kind || !key || !status) return json(400, { error: "kind, key and status are required" });
      const staleS = body.stale_s;
      if (!Number.isInteger(staleS) || staleS < 30 || staleS > 86400) {
        return json(400, { error: "stale_s must be an integer from 30 to 86400" });
      }
      const terminal = body.terminal === undefined ? [] : body.terminal;
      if (!Array.isArray(terminal) || terminal.length > 8
          || !terminal.every((s) => typeof s === "string" && s.trim() !== "" && s.length <= 128)) {
        return json(400, { error: "terminal must be an array of at most 8 non-empty strings" });
      }
      const actor = body.actor ? String(body.actor).slice(0, 128) : null;
      const detail = body.detail ? String(body.detail).slice(0, 4000) : null;
      const guard = await claimArchiveGuard(env, kind, key, t);
      if (guard) return guard;
      const cutoff = isoPlusSeconds(t, -staleS);
      // ?1..?7 are fixed; the terminal list binds from ?8 on (≤ 15 binds total).
      const term = terminal.map((_, i) => `?${8 + i}`);
      const notTerminal = term.length ? `ledgers.status NOT IN (${term.join(",")}) AND ` : "";
      // sql-ident-ok: notTerminal is a literal with ?N placeholder text from term; every value is a ?N bind
      const r = await env.DB.prepare(
        `INSERT INTO ledgers (kind, key, status, actor, detail, created_at, updated_at)
         VALUES (?1,?2,?3,?4,?5,?6,?6)
         ON CONFLICT(kind, key) DO UPDATE SET
           status=?3,
           actor=COALESCE(?4, actor),
           detail=COALESCE(?5, detail),
           updated_at=?6
         WHERE ${notTerminal}(ledgers.status <> ?3 OR ledgers.updated_at < ?7)`
      ).bind(kind, key, status, actor, detail, t, cutoff, ...terminal.map((s) => s.trim())).run();
      const claimed = Number((r && r.meta && r.meta.changes) || 0) > 0;
      const row = await env.DB.prepare("SELECT * FROM ledgers WHERE kind=?1 AND key=?2")
        .bind(kind, key).first();
      return json(200, { claimed, ledger: row, as_of: t });
    },
  ],
];
