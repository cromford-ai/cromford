// job-artifacts routes — what a job produced, keyed by kind.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { queueWake } from "./queue.js";
import { recordBuilderApprove } from "../lib/pr-gate-intake.js";
import { LEAD_ROUND_SQL_LIST } from "../lib/verdict-rounds.js";

export const routes = [
  // ── Artifacts (phase 7) ────────────────────────────────────────────────
  // What a job PRODUCED, as opposed to what it did. Keyed on the JOB rather
  // than the phase because not every artifact comes out of a stage: the PR is
  // created by bin/run-build.sh after the review phase has already closed,
  // and the merge sha is written by bin/merge-sweep.sh on a different box on
  // a different day. `phase_id` records which attempt produced it when there
  // was one — attribution, without forcing an artifact to invent a phase.
  [
    "PUT", /^\/api\/jobs\/([^/]+)\/artifacts$/,
    async ({ env, t, body, m: artMatch }) => {
      const id = decodeURIComponent(artMatch[1]);
      const job = await env.DB.prepare("SELECT id, project FROM jobs WHERE id=?1").bind(id).first();
      // An artifact without its job would be invisible on every screen that
      // starts from a job. 404 is honest, and the client is fail-open.
      if (!job) return json(404, { error: "no such job" });
      const kind = String(body.artifact_kind || "").trim().slice(0, 64);
      const ref = String(body.artifact_ref === undefined ? "" : body.artifact_ref).trim().slice(0, 1024);
      if (!kind) return json(400, { error: "artifact_kind required" });
      // An empty ref is refused rather than stored: a blank artifact that
      // satisfies a contract is worse than no contract at all.
      if (!ref) return json(400, { error: "artifact_ref must be a non-empty value" });
      const phaseId = Number.isInteger(Number(body.phase_id)) ? Number(body.phase_id) : null;
      const detail = body.detail === undefined || body.detail === null
        ? null
        : (typeof body.detail === "string" ? body.detail : JSON.stringify(body.detail)).slice(0, 4000);
      await env.DB.prepare(
        `INSERT INTO job_artifacts (job_id, artifact_kind, artifact_ref, phase_id, detail, actor, created_at, updated_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?7)
         ON CONFLICT(job_id, artifact_kind) DO UPDATE SET
           artifact_ref=?3, phase_id=COALESCE(?4, phase_id),
           detail=COALESCE(?5, detail), actor=COALESCE(?6, actor), updated_at=?7`
      ).bind(id, kind, ref, phaseId, detail,
        body.actor ? String(body.actor).slice(0, 128) : null, t).run();
      const row = await env.DB.prepare(
        "SELECT * FROM job_artifacts WHERE job_id=?1 AND artifact_kind=?2"
      ).bind(id, kind).first();
      // BH-4059 (slice BH-4171): a finished Fly build rings the queue doorbell,
      // so the armed hub runs fly-dispatch + fly-pool-tick now rather than on
      // their next cron tick; both ingest the RESULT under their own flocks.
      // It does NOT launch bin/fly-results-ingest.sh, which holds no flock and
      // stays on its own */2 timer. Best effort, after the artifact has landed:
      // queueWake never throws and the response does not change.
      if (kind === "fly_result") {
        await queueWake(env, `${job.project}:${id}`.slice(0, 160), "fly_result.put", t);
      }
      // BH-4954: a settled builder APPROVE bound to a sha is a PR gate fact
      // (builder_approved_sha). Both puts are hooked because the verdict can
      // land before `gh pr create` writes pr_url; whichever is second records
      // it. Never throws, and the response does not change.
      if (kind === "verdict" || kind === "pr_url") await recordBuilderApprove(env, t, id);
      // BH-1024: the row above is the STANDING verdict and the upsert replaced
      // whatever was there — which is right for a merge gate and wrong for
      // everything that wants to know how the build got here. A verdict write
      // also appends to verdict_history, and only when it SAYS something new:
      // the round is keyed on the content (verdict, reviewed_sha, tier,
      // provenance), so a lane that re-puts the same row every tick writes one
      // round and a rebind onto a new head writes the next one. The detail is
      // parsed defensively, the same rule /api/verdict follows — somebody's
      // free-text breadcrumb must not 500 an artifact write.
      //
      // READ OFF THE STANDING ROW, NOT OFF THE REQUEST. `detail=COALESCE(?5,
      // detail)` means a PUT that sends no detail KEEPS the old one — that is
      // how `jobs-client.sh artifact-put verdict APPROVE` (the operator verb,
      // no detail) behaves. Taking the round from the request there would write
      // "the approval lost its sha" into the history while the standing row
      // still carried it, which is the one question this table exists to
      // answer. So the round is whatever the row SAYS after the upsert.
      let historyAppended = false;
      let historyError = null;
      if (kind === "verdict") {
        const stored = row && row.detail ? String(row.detail) : null;
        let d = {};
        if (stored) { try { d = JSON.parse(stored) || {}; } catch { d = {}; } }
        if (typeof d !== "object" || d === null) d = {};
        const vals = {
          verdict: row && row.artifact_ref !== undefined ? String(row.artifact_ref) : ref,
          reviewed_sha: d.reviewed_sha === undefined || d.reviewed_sha === null
            ? null : String(d.reviewed_sha),
          tier: d.tier === undefined || d.tier === null ? null : String(d.tier),
          provenance: d.provenance === undefined || d.provenance === null
            ? null : String(d.provenance),
          served_by: d.served_by === undefined || d.served_by === null
            ? null : String(d.served_by),
          source: d.source === undefined || d.source === null ? null : String(d.source),
        };
        // ONE STATEMENT, NOT READ-THEN-INSERT. D1 does not serialise across
        // requests, so a read-compare-insert across two awaits lets run-build's
        // settle write and review-rescue.sh's verdict_backfill both see the same
        // empty history on one strandee and both append. The `WHERE NOT EXISTS`
        // form makes the comparison part of the write; `meta.changes` is then
        // the honest answer to "was a round recorded", not a stale read's guess.
        // `IS` (not `=`) because every column but `verdict` is nullable and
        // `NULL = NULL` is NULL — the old JS comparison was null-safe and this
        // one has to stay null-safe too.
        //
        // AND THE HISTORY IS BEST EFFORT; THE STANDING VERDICT IS NOT. The
        // upsert above has already landed by the time we get here, and it is
        // what every merge gate acts on. So the append runs inside a try: a D1
        // blip, or a database this table has not reached yet, must not turn
        // `job_artifact_put verdict` into a 500 — that is a failed rebind, an
        // `mc_rebase` rc 5 and a rebased approved PR parked "rebind-failed". The
        // reason rides out as `history_error` rather than being swallowed.
        try {
          // The table creates itself: `wrangler deploy` is the whole deploy, so
          // schema.sql has not necessarily reached the live D1 (BH-658).
          await ensureTable(env, "verdict_history");
          // BH-9558: the dedupe compares against the job's newest BUILDER
          // round. A lead round (lib/verdict-rounds.js) sits in the same table,
          // and a re-put of the same APPROVE after a lead BLOCK must not append
          // the stale APPROVE again and make it the current verdict.
          // sql-ident-ok: LEAD_ROUND_SQL_LIST is a constant list of literal source words
          const ins = await env.DB.prepare(
            `INSERT INTO verdict_history
               (job_id, verdict, reviewed_sha, tier, provenance, served_by, source, detail, actor, created_at)
             SELECT ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10
              WHERE NOT EXISTS (
                SELECT 1 FROM verdict_history h
                 WHERE h.id=(SELECT MAX(id) FROM verdict_history
                              WHERE job_id=?1 AND COALESCE(source,'') NOT IN (${LEAD_ROUND_SQL_LIST}))
                   AND h.verdict IS ?2 AND h.reviewed_sha IS ?3
                   AND h.tier IS ?4 AND h.provenance IS ?5
              )`
          ).bind(id, vals.verdict, vals.reviewed_sha, vals.tier, vals.provenance,
            vals.served_by, vals.source, stored,
            body.actor ? String(body.actor).slice(0, 128) : null, t).run();
          historyAppended = ((ins && ins.meta && Number(ins.meta.changes)) || 0) > 0;
        } catch (e) {
          historyError = String((e && e.message) || e).slice(0, 300);
          // AND IT IS SAID OUT LOUD. `history_error` rides out in the body, but
          // the only fleet caller is `job_artifact_put`, which does
          // `_jobs_req PUT … >/dev/null` — rc 0, body dropped. Without this line
          // an append that fails on EVERY put (a D1 quota error, a column drift
          // between CREATED_TABLES and a hand-applied schema.sql) is completely
          // silent: every verdict PUT still answers 200, every lane still logs
          // "recorded in the ledger", and `verdict-history` answers one round
          // for every PR — the dead-feed smell, indistinguishable from "nothing
          // changed". One console.error per failed append puts the reason in
          // `wrangler tail` and the Cloudflare log, where a persistent failure
          // is visible as a rate rather than inferred from an empty table.
          console.error("verdict_history append failed", id, historyError);
        }
      }
      return json(200, historyError
        ? { artifact: row, history_appended: historyAppended, history_error: historyError }
        : { artifact: row, history_appended: historyAppended });
    },
  ],

  [
    "GET", /^\/api\/jobs\/([^/]+)\/artifacts$/,
    async ({ env, t, m: artMatch }) => {
      const id = decodeURIComponent(artMatch[1]);
      const rows = await env.DB.prepare(
        "SELECT * FROM job_artifacts WHERE job_id=?1 ORDER BY artifact_kind ASC"
      ).bind(id).all();
      return json(200, { job_id: id, artifacts: rows.results || [], as_of: t });
    },
  ],
];
