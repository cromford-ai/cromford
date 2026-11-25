// verdict_history rounds that come from the verdicts table (lead, human,
// risk-tier), and the read of a PR's CURRENT verdict across every round.
//
// verdict_history held only builder and review-lane rounds (PUT
// /api/jobs/:id/artifacts). A lead BLOCK landed in the `verdicts` table alone,
// so a reader of the history saw the builder's APPROVE as the last word on a
// PR the lead had blocked. recordLeadRound appends the lead round to the PR's
// ledger job; currentVerdicts answers the newest round per PR url.
//
// The standing job_artifacts(kind=verdict) row is NOT changed here: every
// merge gate reads it, and the lead gate fact rides lib/pr-gate-intake.js.

import { ensureTable } from "./core.js";
import { STANDING_SOURCES } from "./verdict-sources.js";

// The sources whose rows append a lead round. ONE list with the standing
// sources, so a row that stands is a row that appends.
export const LEAD_ROUND_SOURCES = STANDING_SOURCES;

// A constant SQL list of LEAD_ROUND_SOURCES, for `source NOT IN (...)`.
// sql-ident-ok: built from a frozen export const of literal words, never input.
export const LEAD_ROUND_SQL_LIST = LEAD_ROUND_SOURCES.map((s) => `'${s}'`).join(",");

// The fallback cap of POST /api/verdict/current when the settings row
// `verdict.current.max_prs` is missing or not a positive integer.
export const VERDICT_CURRENT_MAX_PRS_DEFAULT = 200;

// prLedgerJob lives in routes/verdict.js; it is passed in so this lib does not
// import a route module.
export async function recordLeadRound(env, t, row, prLedgerJob) {
  try {
    if (!row || !LEAD_ROUND_SOURCES.includes(row.source)) return { recorded: false, why: "not-a-lead-source" };
    const pr = `https://github.com/${row.repo}/pull/${row.pr}`;
    const { hit } = await prLedgerJob(env.DB, pr);
    if (!hit) return { recorded: false, why: "no-ledger-job" };
    await ensureTable(env, "verdict_history");
    // One statement: the dedupe is part of the write (the job-artifacts.js
    // rule). An exact replay of the job's newest lead round appends nothing.
    // sql-ident-ok: LEAD_ROUND_SQL_LIST is a constant list of literal words
    const ins = await env.DB.prepare(
      `INSERT INTO verdict_history
         (job_id, verdict, reviewed_sha, tier, provenance, served_by, source, detail, actor, created_at)
       SELECT ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10
        WHERE NOT EXISTS (
          SELECT 1 FROM verdict_history h
           WHERE h.id=(SELECT MAX(id) FROM verdict_history
                        WHERE job_id=?1 AND source IN (${LEAD_ROUND_SQL_LIST}))
             AND h.verdict IS ?2 AND h.reviewed_sha IS ?3 AND h.source IS ?7
        )`
    ).bind(hit.job_id, row.verdict, row.head_sha ?? null, row.review_tier ?? null, row.review_mode ?? null,
      row.reviewer_model ?? null, row.source, JSON.stringify({ verdicts_id: row.id ?? null, reviewer: row.reviewer ?? null }),
      row.reviewer ?? null, t).run();
    const recorded = ((ins && ins.meta && Number(ins.meta.changes)) || 0) > 0;
    return { recorded, why: recorded ? null : "replay", job_id: hit.job_id };
  } catch (e) {
    const error = String((e && e.message) || e).slice(0, 300);
    console.error("[verdict-rounds] BH-9558 lead round not recorded", row && row.id, error);
    return { recorded: false, why: "error", error };
  }
}

// Who decided a round: `builder` for every non-lead source (run-build,
// review-prs, a raw lane row with no source), else the lead source itself.
export function roundBy(source) {
  return LEAD_ROUND_SOURCES.includes(source) ? source : "builder";
}

// The state word the kanban shows. `lead_blocked` only for a BLOCK by lead or
// human (risk-tier can only write MERGE).
export function verdictState(verdict, by) {
  const v = String(verdict || "").toUpperCase();
  if (v === "BLOCK") return by === "lead" || by === "human" ? "lead_blocked" : "blocked";
  if (v === "REQUEST_CHANGES") return "blocked";
  if (v === "APPROVE" || v === "MERGE" || v === "MERGE-WITH-NOTES") return "approved";
  return "other";
}

// The newest round per PR url, plus the round count, in ONE statement. The
// urls ride as one JSON array (?1): D1 caps bound parameters at 100 per
// statement, and the cap here is a settings row that can exceed that. SQLite
// takes the bare columns from the row that holds MAX(h.id). Index use:
// idx_artifacts_ref for the IN list, idx_verdict_history_job for the join
// (test V13, EXPLAIN QUERY PLAN at 20,000 artifacts and 120,000 rounds).
export const CURRENT_VERDICTS_SQL =
  `SELECT a.artifact_ref AS pr, MAX(h.id) AS id, h.verdict, h.source, h.reviewed_sha, h.created_at,
          COUNT(*) AS rounds
     FROM job_artifacts a JOIN verdict_history h ON h.job_id=a.job_id
    WHERE a.artifact_kind='pr_url' AND a.artifact_ref IN (SELECT value FROM json_each(?1))
    GROUP BY a.artifact_ref
    LIMIT ?2`;

export async function currentVerdicts(env, prs) {
  const out = {};
  if (!prs.length) return out;
  await ensureTable(env, "verdict_history");
  const res = await env.DB.prepare(CURRENT_VERDICTS_SQL).bind(JSON.stringify(prs), prs.length).all();
  for (const r of (res && res.results) || []) {
    const by = roundBy(r.source);
    out[r.pr] = {
      verdict: r.verdict, by, state: verdictState(r.verdict, by),
      reviewed_sha: r.reviewed_sha ?? null, at: r.created_at ?? null, rounds: Number(r.rounds) || 0,
    };
  }
  return out;
}
