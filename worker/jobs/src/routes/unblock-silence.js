// unblock-silence routes — BH-9447: a safe recommended lever runs when nobody
// answers a Tackler card. The rows are unblock_decisions (BH-7722); the
// columns are core.d/bh-9447-unblock-silence.js. The caller is
// bin/lib/unblock/silence.sh (unblock_silence_sweep, from card.sh's sweep).
//
//   POST /api/unblock/silence/:id/claim    claim the card BEFORE the lever runs
//   POST /api/unblock/silence/:id/result   the lever's outcome; done answers the card
//
// CLAIM. {lever, cap}: lever ^[a-z_]{1,40}$, cap an integer 1..1000 (the
// caller reads it from the row unblock.silence_auto_day_cap), else 400. ONE
// `UPDATE ... SET silence_claimed_at, silence_lever, silence_outcome='claimed'
// WHERE id=?1 AND outcome='escalated' AND silence_claimed_at IS NULL AND <the
// project's silence claims since the worker's own UTC day start> < cap`. The
// count's subqueries name no outer column, so each runs once
// (idx_unblock_decisions_silence). The worker's clock decides the day, so two
// sweeps cannot both take the last slot. 200 {ok, id, claimed:true,
// claimed_at}. With 0 changes: no row 404; not escalated (answered, hold,
// expired) 422 not_escalated; already claimed 409 claimed; else 409 day_cap
// {count, cap}. A card is claimed once, ever: a lever that failed is not tried
// again.
//
// RESULT. {outcome: done|failed|refused|would, detail?} (detail at most 500
// chars). done: ONE `UPDATE ... SET outcome='answered', answer=<the card's
// recommendation>, answered_by='silence-default', answer_source=
// 'silence-default', answered_at, resolved_at, silence_outcome='done' WHERE
// id=?1 AND outcome='escalated' AND silence_outcome='claimed'` = 200
// {answered:true}. With 0 changes (the operator answered between the claim and the
// result), and for every other outcome: ONE `UPDATE ... SET silence_outcome,
// silence_detail WHERE id=?1 AND silence_outcome='claimed'` = 200
// {answered:false}; the row keeps its outcome (escalated: the card stays open
// and keeps its deadline). With 0 changes: no row 404; else 409 not_claimed.
//
// D1 has no RLS. Every route sits behind the HARNESS_SECRET bearer (this
// family is not in OPEN_FAMILIES).

import { json, d1Guarded } from "../lib/http.js";
import { ensureTable, ensureColumns } from "../lib/core.js";

const TABLE = "unblock_decisions";
const LEVER_RE = /^[a-z_]{1,40}$/;
const OUTCOMES = new Set(["done", "failed", "refused", "would"]);
// The range of the row unblock.silence_auto_day_cap (schema.d/*-bh-9447-unblock-silence.sql).
const CAP_MIN = 1;
const CAP_MAX = 1000;
const TEXT_MAX = 500;

// ?1 id ?2 lever ?3 now ?4 the UTC day (YYYY-MM-DD) ?5 cap
export const SILENCE_CLAIM_SQL =
  `UPDATE unblock_decisions
      SET silence_claimed_at = ?3, silence_lever = ?2, silence_outcome = 'claimed'
    WHERE id = ?1 AND outcome = 'escalated' AND silence_claimed_at IS NULL
      AND (SELECT count(*) FROM unblock_decisions
            WHERE project = (SELECT project FROM unblock_decisions WHERE id = ?1)
              AND silence_claimed_at >= ?4) < ?5`;
// ?1 id ?2 day
const SILENCE_COUNT_SQL =
  `SELECT count(*) AS n FROM unblock_decisions
    WHERE project = (SELECT project FROM unblock_decisions WHERE id = ?1) AND silence_claimed_at >= ?2`;
// ?1 id ?2 now ?3 detail
export const SILENCE_DONE_SQL =
  `UPDATE unblock_decisions
      SET outcome = 'answered', answer = CAST(json_extract(card, '$.recommendation') AS TEXT),
          answered_by = 'silence-default', answer_source = 'silence-default', answered_at = ?2, resolved_at = ?2,
          silence_outcome = 'done', silence_detail = ?3
    WHERE id = ?1 AND outcome = 'escalated' AND silence_outcome = 'claimed'`;
// ?1 id ?2 outcome ?3 detail
export const SILENCE_RESULT_SQL =
  `UPDATE unblock_decisions SET silence_outcome = ?2, silence_detail = ?3 WHERE id = ?1 AND silence_outcome = 'claimed'`;
const READ_SQL = `SELECT id, outcome, silence_claimed_at, silence_outcome FROM unblock_decisions WHERE id = ?1`;

const bad = (field) => json(400, { error: field });
const changesOf = (res) => Number((res && res.meta && res.meta.changes) || 0);
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const ready = async (env) => { await ensureTable(env, TABLE); await ensureColumns(env, TABLE); };
const readRow = (env, id) => env.DB.prepare(READ_SQL).bind(id).first();

export const routes = [
  // ── POST /api/unblock/silence/:id/claim — claim before the lever runs ──────
  [
    "POST", /^\/api\/unblock\/silence\/(\d{1,15})\/claim$/,
    async ({ env, t, body, m }) => {
      const id = Number(m[1]);
      const b = isObj(body) ? body : {};
      if (typeof b.lever !== "string" || !LEVER_RE.test(b.lever)) return bad("lever");
      if (!Number.isInteger(b.cap) || b.cap < CAP_MIN || b.cap > CAP_MAX) return bad("cap");
      const day = t.slice(0, 10);
      return d1Guarded(TABLE, async () => {
        await ready(env);
        const res = await env.DB.prepare(SILENCE_CLAIM_SQL).bind(id, b.lever, t, day, b.cap).run();
        if (changesOf(res) === 1) return json(200, { ok: true, id, claimed: true, claimed_at: t });
        const row = await readRow(env, id);
        if (!row) return json(404, { error: "decision not found" });
        if (row.outcome !== "escalated") return json(422, { error: "not_escalated", outcome: row.outcome });
        if (row.silence_claimed_at !== null) return json(409, { error: "claimed", claimed_at: row.silence_claimed_at });
        const c = await env.DB.prepare(SILENCE_COUNT_SQL).bind(id, day).first();
        return json(409, { error: "day_cap", count: Number((c && c.n) || 0), cap: b.cap });
      });
    },
  ],

  // ── POST /api/unblock/silence/:id/result — the lever's outcome ─────────────
  [
    "POST", /^\/api\/unblock\/silence\/(\d{1,15})\/result$/,
    async ({ env, t, body, m }) => {
      const id = Number(m[1]);
      const b = isObj(body) ? body : {};
      if (!OUTCOMES.has(b.outcome)) return bad("outcome");
      const detail = b.detail ?? "";
      if (typeof detail !== "string" || detail.length > TEXT_MAX) return bad("detail");
      return d1Guarded(TABLE, async () => {
        await ready(env);
        if (b.outcome === "done") {
          const res = await env.DB.prepare(SILENCE_DONE_SQL).bind(id, t, detail).run();
          if (changesOf(res) === 1) return json(200, { ok: true, id, answered: true, answered_at: t });
        }
        const res = await env.DB.prepare(SILENCE_RESULT_SQL).bind(id, b.outcome, detail).run();
        if (changesOf(res) === 1) return json(200, { ok: true, id, answered: false, silence_outcome: b.outcome });
        const row = await readRow(env, id);
        if (!row) return json(404, { error: "decision not found" });
        return json(409, { error: "not_claimed", silence_outcome: row.silence_outcome });
      });
    },
  ],
];
