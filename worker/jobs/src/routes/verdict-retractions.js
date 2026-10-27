// verdict-retractions routes — BH-8476: retract a lead BLOCK row whose review
// report was empty.
//
// The land lane (bin/lead-review-land.sh) once posted a source=lead BLOCK for a
// review whose report held no finding line. That row stood on the head and held
// the PR with nothing to fix. The verdicts table is append-only (its triggers
// refuse UPDATE/DELETE), so a retraction is a row in verdict_retractions, keyed
// by the verdict id. GET /api/verdicts (routes/verdicts.js) reads a retracted
// row as absent for `standing` and keeps it in history with retracted_at and
// retract_reason. The one writer outside a test is `bin/lead-verdict.sh retract`.
//
// Auth: the lead token (leadTokenOk, the POST /api/verdicts credential) on top
// of the bearer. Only a source=lead verdict=BLOCK row can be retracted, so the
// lead token can never remove a human, box or risk-tier row, or a MERGE.
// Exactly once: verdict_id is the PRIMARY KEY and the write is INSERT OR IGNORE,
// so a retried retract answers the stored row (200, existing:true).
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { leadTokenOk, optStr } from "./verdicts.js";

export const RETRACT_REASONS = ["empty-report"];

export const routes = [
  [
    "POST", /^\/api\/verdicts\/([1-9][0-9]{0,17})\/retract$/,
    async ({ req, env, t, body, m }) => {
      return d1Guarded("verdicts", async () => {
        if (!leadTokenOk(req, env)) {
          return json(403, { error: "a retract needs the lead verdict token (x-lead-verdict-token); HARNESS_SECRET alone may write source=box only" });
        }
        const b = body || {};
        if (!RETRACT_REASONS.includes(b.reason)) {
          return json(400, { error: `reason must be one of ${RETRACT_REASONS.join(", ")}` });
        }
        const actor = optStr(b, "actor", 100);
        if (!actor.ok) return json(400, { error: actor.err });
        const id = Number(m[1]);
        if (!Number.isSafeInteger(id)) return json(404, { error: `verdict #${m[1]} not found` });
        await ensureTable(env, "verdicts");
        await ensureTable(env, "verdict_retractions");
        const verdict = await env.DB.prepare("SELECT * FROM verdicts WHERE id=?1").bind(id).first();
        if (!verdict) return json(404, { error: `verdict #${id} not found` });
        if (verdict.source !== "lead" || verdict.verdict !== "BLOCK") {
          return json(409, { error: "only a lead BLOCK row can be retracted", verdict });
        }
        const res = await env.DB.prepare(
          `INSERT OR IGNORE INTO verdict_retractions (verdict_id, reason, actor, created_at)
           VALUES (?1,?2,?3,?4)`
        ).bind(id, b.reason, actor.v, t).run();
        const retraction = await env.DB.prepare("SELECT * FROM verdict_retractions WHERE verdict_id=?1")
          .bind(id).first();
        const created = Number(res?.meta?.changes) === 1;
        if (created) {
          console.warn(`[verdicts] BH-8476 retracted lead BLOCK #${id} on ${verdict.repo}#${verdict.pr} ${String(verdict.head_sha).slice(0, 12)}: ${b.reason}`);
        }
        return json(created ? 201 : 200, { retraction, verdict, existing: !created });
      });
    },
  ],
];
