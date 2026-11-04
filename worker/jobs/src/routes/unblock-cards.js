// unblock-cards routes — BH-8817 (C0): Tackler cards go to Archie first, and
// the operator is paged once, only for a decision he must make. The rows are
// unblock_decisions (BH-7722); the columns are core.d/bh-8817-unblock-cards.js.
//
//   POST /api/unblock/decisions/:id/archie-claim   Archie claims a card BEFORE its model call
//   POST /api/unblock/decisions/:id/route          the card goes to the operator (once)
//   POST /api/unblock/decisions/:id/paged          Tackler paged the operator for it (once)
//   GET  /api/unblock/cards/daily?project=&day=    the digest counts for one UTC day
//   GET  /api/unblock/cards/repeats?since=&min=&limit=
//                                                  Archie's answers that repeat (the rule miner)
//
// ARCHIE-CLAIM. ONE `UPDATE ... SET archie_claimed_at WHERE id=?1 AND
// outcome='escalated' AND archie_claimed_at IS NULL AND routed_to IS NULL`
// (bin/archie-cards.sh, dedup before spend). 200 {ok, id, claimed:true,
// claimed_at}. With 0 changes: no row 404; not escalated 422 not_escalated;
// routed 409 routed; claimed 409 claimed.
//
// ROUTE. {to:"operator", by:"archie"|"timeout", reason?, claimed_before?}. ONE
// `UPDATE ... SET routed_to='operator' WHERE id=?1 AND outcome='escalated' AND
// routed_to IS NULL AND (claimed_before IS NULL OR archie_claimed_at IS NULL
// OR archie_claimed_at < claimed_before)`. route_reason is "<by>: <reason>",
// or "<by>" for an empty reason. Archie's needs-operator sends by archie;
// Tackler's sweep sends by timeout with claimed_before = now - the claim
// lease, so a card Archie is still working is not taken from it. 200 {ok, id,
// routed_to}. With 0 changes: no row 404; not escalated 422 not_escalated;
// routed 409 routed; a claim at or after claimed_before 409 claimed.
// to other than operator 400 to; by 400 by; reason over 500 chars 400 reason;
// claimed_before not YYYY-MM-DDTHH:MM:SSZ 400 claimed_before.
//
// PAGED. ONE `UPDATE ... SET paged_at WHERE id=?1 AND routed_to='operator' AND
// paged_at IS NULL`, after lane-alert.sh answered rc 0. 200 {ok, id,
// paged_at}; no row 404; not routed to operator 409 not_routed; already 409 paged.
//
// DAILY. ONE aggregate over the sent cards (card set, outcome escalated,
// answered or expired) created in the day: received, archie (Archie answered
// hold, none or acted), operator (every card the operator got: routed back to the operator by
// Archie or the timeout, or sent to the operator direct, which is a card with no
// route, such as BH-8736's ask card or a legacy card, or with route operator),
// false (Archie closed it with none), acted (Archie pulled a lever).
// idx_unblock_decisions_created serves the window (W6 EXPLAINs DAILY_SQL;
// the json_extract is in the SELECT list only).
//
// REPEATS. ONE aggregate over Archie's answers (answer_source 'archie')
// created at or after `since` (YYYY-MM-DDTHH:MM:SSZ): per project,
// stall_class, answer and lever, the count and the newest row id, only the
// groups with count >= min (2..100), most first, at most limit (1..200).
// bin/rule-miner.sh (bin/lib/unblock/archie-repeats.sh) turns each group into
// one incident: the same card answered the same way is a candidate rule for
// catalog/unblock-rules.d. The caller's window and threshold are its knobs;
// the ranges here only bound the input. idx_unblock_decisions_created serves
// the window (W6 EXPLAINs REPEATS_SQL).
//
// D1 has no RLS. Every route sits behind the HARNESS_SECRET bearer (this
// family is not in OPEN_FAMILIES).

import { json, d1Guarded } from "../lib/http.js";
import { ensureTable, ensureColumns } from "../lib/core.js";

const TABLE = "unblock_decisions";
const PROJECT_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const BYS = new Set(["archie", "timeout"]);
const TEXT_MAX = 500;

// ?1 id ?2 now
export const ARCHIE_CLAIM_SQL =
  `UPDATE unblock_decisions SET archie_claimed_at = ?2
    WHERE id = ?1 AND outcome = 'escalated' AND archie_claimed_at IS NULL AND routed_to IS NULL`;
// ?1 id ?2 now ?3 route_reason ?4 claimed_before (or null)
export const ROUTE_SQL =
  `UPDATE unblock_decisions SET routed_to = 'operator', routed_at = ?2, route_reason = ?3
    WHERE id = ?1 AND outcome = 'escalated' AND routed_to IS NULL
      AND (?4 IS NULL OR archie_claimed_at IS NULL OR archie_claimed_at < ?4)`;
// ?1 id ?2 now
export const PAGED_SQL =
  `UPDATE unblock_decisions SET paged_at = ?2 WHERE id = ?1 AND routed_to = 'operator' AND paged_at IS NULL`;
const READ_SQL =
  `SELECT id, outcome, routed_to, paged_at, archie_claimed_at FROM unblock_decisions WHERE id = ?1`;
// ?1 day start ?2 next day start ?3 project
export const DAILY_SQL =
  `SELECT count(*) AS received,
          coalesce(sum(CASE WHEN answer_source = 'archie' AND answer IN ('hold', 'none', 'acted') THEN 1 ELSE 0 END), 0) AS archie,
          coalesce(sum(CASE WHEN routed_to = 'operator' OR coalesce(json_extract(card, '$.route'), 'operator') <> 'archie'
                            THEN 1 ELSE 0 END), 0) AS operator,
          coalesce(sum(CASE WHEN answer_source = 'archie' AND answer = 'none' THEN 1 ELSE 0 END), 0) AS false_cards,
          coalesce(sum(CASE WHEN answer_source = 'archie' AND answer = 'acted' THEN 1 ELSE 0 END), 0) AS acted
     FROM unblock_decisions
    WHERE created_at >= ?1 AND created_at < ?2 AND +project = ?3 AND card IS NOT NULL
      AND +outcome IN ('escalated', 'answered', 'expired')`;
// ?1 since ?2 min ?3 limit
export const REPEATS_SQL =
  `SELECT project, stall_class, answer, coalesce(archie_lever, '') AS lever, count(*) AS n, max(id) AS last_id
     FROM unblock_decisions
    WHERE created_at >= ?1 AND +answer_source = 'archie'
    GROUP BY project, stall_class, answer, lever
   HAVING count(*) >= ?2
    ORDER BY n DESC, last_id DESC
    LIMIT ?3`;

const bad = (field) => json(400, { error: field });
const changesOf = (res) => Number((res && res.meta && res.meta.changes) || 0);
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const ready = async (env) => { await ensureTable(env, TABLE); await ensureColumns(env, TABLE); };
const readRow = (env, id) => env.DB.prepare(READ_SQL).bind(id).first();

export const routes = [
  // ── POST /api/unblock/decisions/:id/archie-claim — claim before the call ───
  [
    "POST", /^\/api\/unblock\/decisions\/(\d{1,15})\/archie-claim$/,
    async ({ env, t, m }) => {
      const id = Number(m[1]);
      return d1Guarded(TABLE, async () => {
        await ready(env);
        const res = await env.DB.prepare(ARCHIE_CLAIM_SQL).bind(id, t).run();
        if (changesOf(res) === 1) return json(200, { ok: true, id, claimed: true, claimed_at: t });
        const row = await readRow(env, id);
        if (!row) return json(404, { error: "decision not found" });
        if (row.outcome !== "escalated") return json(422, { error: "not_escalated", outcome: row.outcome });
        if (row.routed_to !== null) return json(409, { error: "routed", routed_to: row.routed_to });
        return json(409, { error: "claimed", claimed_at: row.archie_claimed_at });
      });
    },
  ],

  // ── POST /api/unblock/decisions/:id/route — hand the card to the operator, once ────
  [
    "POST", /^\/api\/unblock\/decisions\/(\d{1,15})\/route$/,
    async ({ env, t, body, m }) => {
      const id = Number(m[1]);
      const b = isObj(body) ? body : {};
      if (b.to !== "operator") return bad("to");
      if (!BYS.has(b.by)) return bad("by");
      const reason = b.reason ?? "";
      if (typeof reason !== "string" || reason.length > TEXT_MAX) return bad("reason");
      const cb = b.claimed_before ?? null;
      if (cb !== null && (typeof cb !== "string" || !ISO_RE.test(cb))) return bad("claimed_before");
      const why = reason.trim() === "" ? b.by : `${b.by}: ${reason.trim()}`;
      return d1Guarded(TABLE, async () => {
        await ready(env);
        const res = await env.DB.prepare(ROUTE_SQL).bind(id, t, why, cb).run();
        if (changesOf(res) === 1) return json(200, { ok: true, id, routed_to: "operator", routed_at: t });
        const row = await readRow(env, id);
        if (!row) return json(404, { error: "decision not found" });
        if (row.outcome !== "escalated") return json(422, { error: "not_escalated", outcome: row.outcome });
        if (row.routed_to !== null) return json(409, { error: "routed", routed_to: row.routed_to });
        return json(409, { error: "claimed", claimed_at: row.archie_claimed_at });
      });
    },
  ],

  // ── POST /api/unblock/decisions/:id/paged — the operator was paged, once ───────────
  [
    "POST", /^\/api\/unblock\/decisions\/(\d{1,15})\/paged$/,
    async ({ env, t, m }) => {
      const id = Number(m[1]);
      return d1Guarded(TABLE, async () => {
        await ready(env);
        const res = await env.DB.prepare(PAGED_SQL).bind(id, t).run();
        if (changesOf(res) === 1) return json(200, { ok: true, id, paged_at: t });
        const row = await readRow(env, id);
        if (!row) return json(404, { error: "decision not found" });
        if (row.routed_to !== "operator") return json(409, { error: "not_routed" });
        return json(409, { error: "paged", paged_at: row.paged_at });
      });
    },
  ],

  // ── GET /api/unblock/cards/daily?project=&day=YYYY-MM-DD ───────────────────
  [
    "GET", "/api/unblock/cards/daily",
    async ({ env, url }) => {
      const project = url.searchParams.get("project");
      const day = url.searchParams.get("day");
      if (project === null || !PROJECT_RE.test(project)) return bad("project");
      if (day === null || !DAY_RE.test(day)) return bad("day");
      const start = Date.parse(`${day}T00:00:00Z`);
      if (!Number.isFinite(start) || new Date(start).toISOString().slice(0, 10) !== day) return bad("day");
      const next = new Date(start + 86400000).toISOString().replace(/\.\d{3}Z$/, "Z");
      return d1Guarded(TABLE, async () => {
        await ready(env);
        const r = await env.DB.prepare(DAILY_SQL).bind(`${day}T00:00:00Z`, next, project).first();
        return json(200, {
          project, day, received: Number(r?.received || 0), archie: Number(r?.archie || 0),
          operator: Number(r?.operator || 0), false: Number(r?.false_cards || 0), acted: Number(r?.acted || 0),
        });
      });
    },
  ],

  // ── GET /api/unblock/cards/repeats?since=&min=&limit= ──────────────────────
  [
    "GET", "/api/unblock/cards/repeats",
    async ({ env, url }) => {
      const since = url.searchParams.get("since");
      if (since === null || !ISO_RE.test(since) || !Number.isFinite(Date.parse(since))) return bad("since");
      const int = (name, lo, hi) => {
        const v = url.searchParams.get(name);
        return v !== null && /^\d{1,3}$/.test(v) && Number(v) >= lo && Number(v) <= hi ? Number(v) : null;
      };
      const min = int("min", 2, 100);
      if (min === null) return bad("min");
      const limit = int("limit", 1, 200);
      if (limit === null) return bad("limit");
      return d1Guarded(TABLE, async () => {
        await ready(env);
        const { results } = await env.DB.prepare(REPEATS_SQL).bind(since, min, limit).all();
        return json(200, { since, min, limit, repeats: (results || []).map((r) => ({ ...r, n: Number(r.n) })) });
      });
    },
  ],
];
