// lead-review-release — BH-8579: the rule behind POST
// /api/lead-reviews/reclaim-stale (routes/lead-reviews.js, the BH-5779 sweep).
// A `running` lead review request is released when:
// - its bound job ended failed more than one beat interval ago, and no request
//   heartbeat arrived after the job ended (reason `job-failed`), or
// - it went past the deadline with no heartbeat (reason `stale`).
// A job that ended abandoned or budget_stopped is terminal (core.js: a budget
// stop is never retried; abandoned is an operator's "over for good"). Its row
// goes straight to `failed` with reason `job-terminal`, never to `requested`,
// and lg_gate_retry does not reset it.
// Before a requeue, the worker's own pr_records fact is read. A fact field
// stamped after the request was created that says closed/merged, or another
// head, makes the row `superseded` (reasons `pr-closed`, `head-moved`). Else
// the row goes back to `requested` while stale_reclaims < cap, and to `failed`
// at the cap. Every write is ONE compare-and-set pinned to what the sweep read.
import { ensureTable, isoPlusSeconds, strictInt } from "./core.js";
import { STALE_FALLBACK_S } from "../routes/participants.js";

// Code fallback for settings lead_review.stale_running_min (seed
// schema.d/202610270826-bh-8579-lead-review-release-knobs.sql).
export const LEAD_REVIEW_STALE_RUNNING_MIN_FALLBACK = 15;
// Code fallback for settings lead_review.release_max_resets (same seed).
export const LEAD_REVIEW_RELEASE_MAX_FALLBACK = 3;

// queued_for_retry, orphaned and parked are left out: the jobs watchdog can
// resume them under the same job id. done is left out: finish_done marks the
// job done only after its result post.
export const FAILED_JOB_STATUSES = ["failed"];
// Terminal: released to failed only, never requeued (no second paid run).
export const TERMINAL_JOB_STATUSES = ["abandoned", "budget_stopped"];

const KNOB_KEYS = ["lead_review.stale_running_min", "lead_review_running_deadline_s", "lead_review_claim_stale_s", "lead_review.release_max_resets"];
const KNOB_SQL = "SELECT key, value FROM settings WHERE key IN ('lead_review.stale_running_min','lead_review_running_deadline_s','lead_review_claim_stale_s','lead_review.release_max_resets')";

const posInt = (v) => { const n = strictInt(v); return n !== null && n > 0 ? n : null; };

// leadReleaseKnobs — ONE settings statement. deadline_s: the new row in
// minutes, else lead_review_running_deadline_s, else the fallback, floored at
// stale_s (the /claim takeover window) so the sweep never undercuts it.
// beat_s: stale_s / 3, the ratio lr_beat_start beats at. cap: a non-negative
// integer row, else the fallback.
export async function leadReleaseKnobs(env) {
  const { results } = await env.DB.prepare(KNOB_SQL).all();
  const v = Object.fromEntries(KNOB_KEYS.map((k) => [k, null]));
  for (const r of results || []) v[r.key] = r.value;
  const stale_s = posInt(v.lead_review_claim_stale_s) ?? STALE_FALLBACK_S;
  const min = posInt(v["lead_review.stale_running_min"]);
  const deadline = min !== null ? min * 60 : posInt(v.lead_review_running_deadline_s) ?? LEAD_REVIEW_STALE_RUNNING_MIN_FALLBACK * 60;
  const capRow = strictInt(v["lead_review.release_max_resets"]);
  return {
    deadline_s: Math.max(deadline, stale_s),
    stale_s,
    beat_s: Math.floor(stale_s / 3),
    cap: capRow !== null && capRow >= 0 ? capRow : LEAD_REVIEW_RELEASE_MAX_FALLBACK,
  };
}

// ?1 = now - deadline_s, ?2 = now - beat_s, ?3 = the page size.
// Indexes: r by idx_lead_review_requests_status (status, repo), j by the jobs
// primary key, p by ux_pr_records_repo_number (test P1b). A field of the fact
// is dated by its fields_at stamp, else by refreshed_at.
export const RELEASE_SELECT_SQL =
  `SELECT r.id, r.repo, r.pr, r.head_sha, r.job_id, r.box, r.participant, r.heartbeat_at, r.updated_at, r.created_at, r.stale_reclaims,
          CASE WHEN j.status IN ('failed','abandoned','budget_stopped') AND j.updated_at < ?2
                AND COALESCE(r.heartbeat_at, r.updated_at) <= j.updated_at THEN 1 ELSE 0 END AS job_ended,
          j.status AS job_status, j.stage AS job_stage, j.box AS job_box, j.updated_at AS job_updated_at,
          p.state AS pr_state, p.head_sha AS pr_head,
          COALESCE(CASE WHEN json_valid(p.fields_at) THEN json_extract(p.fields_at, '$.state') END, p.refreshed_at) AS pr_state_at,
          COALESCE(CASE WHEN json_valid(p.fields_at) THEN json_extract(p.fields_at, '$.head_sha') END, p.refreshed_at) AS pr_head_at
     FROM lead_review_requests r
     LEFT JOIN jobs j ON j.id = r.job_id
     LEFT JOIN pr_records p ON p.repo = r.repo AND p.number = r.pr
    WHERE r.status = 'running'
      AND (COALESCE(r.heartbeat_at, r.updated_at) < ?1
           OR (j.status IN ('failed','abandoned','budget_stopped') AND j.updated_at < ?2
               AND COALESCE(r.heartbeat_at, r.updated_at) <= j.updated_at))
    ORDER BY r.updated_at LIMIT ?3`;

// a fact field stamped after the request was created
const newer = (at, created) => {
  const a = Date.parse(at ?? ""), c = Date.parse(created ?? "");
  return Number.isFinite(a) && Number.isFinite(c) && a > c;
};

// decideRelease — pure. { to, reason, detail } for one selected row.
export function decideRelease(row, knobs) {
  const prHead = typeof row.pr_head === "string" ? row.pr_head.trim().toLowerCase() : "";
  if ((row.pr_state === "closed" || row.pr_state === "merged") && newer(row.pr_state_at, row.created_at)) {
    return { to: "superseded", reason: "pr-closed", detail: "pr closed" };
  }
  if (prHead && prHead !== String(row.head_sha).toLowerCase() && newer(row.pr_head_at, row.created_at)) {
    return { to: "superseded", reason: "head-moved", detail: `head moved to ${prHead.slice(0, 12)}` };
  }
  const beat = row.heartbeat_at ?? row.updated_at;
  // A terminal job is never requeued, on the job path or the deadline path.
  if (TERMINAL_JOB_STATUSES.includes(row.job_status)) {
    return {
      to: "failed", reason: "job-terminal",
      detail: `job terminal: job ${row.job_id} ended ${row.job_status} at stage ${row.job_stage ?? "unknown"} on ${row.job_box ?? row.box ?? "none"} at ${row.job_updated_at}; not requeued`.slice(0, 4000),
    };
  }
  // A failed job names the cause, so it wins over the plain deadline.
  const jobFailed = row.job_ended === 1 && FAILED_JOB_STATUSES.includes(row.job_status);
  const reason = jobFailed ? "job-failed" : "stale";
  const detail = (jobFailed
    ? `job failed: job ${row.job_id} ended ${row.job_status} at stage ${row.job_stage ?? "unknown"} on ${row.job_box ?? row.box ?? "none"} at ${row.job_updated_at}; no heartbeat since ${beat}`
    : `stale: running with no heartbeat since ${beat} (job ${row.job_id ?? "none"}, box ${row.box ?? "none"}); reclaimed after ${knobs.deadline_s} s`
  ).slice(0, 4000);
  return { to: (row.stale_reclaims || 0) < knobs.cap ? "requested" : "failed", reason, detail };
}

// The CAS of each outcome. Binds: ?1 detail, ?2 now, ?3 id, ?4 job_id read,
// ?5 beat read, ?6 stale_reclaims read. A claim, a heartbeat or another
// sweep that lands first makes changes 0, and the row is not listed.
const PIN = "WHERE id=?3 AND status='running' AND job_id IS ?4 AND COALESCE(heartbeat_at, updated_at) = ?5 AND COALESCE(stale_reclaims, 0) = ?6";
export const RELEASE_CAS_SQL = {
  requested: `UPDATE lead_review_requests
                 SET status='requested', job_id=NULL, box=NULL, participant=NULL, heartbeat_at=NULL, verdict=NULL,
                     report_ref=NULL, promoted_verdict_at=NULL, detail=?1, reset_count=COALESCE(reset_count, 0) + 1,
                     reset_at=?2, stale_reclaims=COALESCE(stale_reclaims, 0) + 1, updated_at=?2
               ${PIN}`,
  // job_id is kept: a late /result of that job is still bound to the row.
  failed: `UPDATE lead_review_requests
              SET status='failed', detail=?1, stale_reclaims=COALESCE(stale_reclaims, 0) + 1, updated_at=?2
            ${PIN}`,
  superseded: `UPDATE lead_review_requests SET status='superseded', detail=?1, updated_at=?2 ${PIN}`,
};

// releaseSweep — the whole reclaim-stale answer. `limit` is the route's page size.
export async function releaseSweep(env, t, limit) {
  await ensureTable(env, "pr_records");
  const knobs = await leadReleaseKnobs(env);
  const { results } = await env.DB.prepare(RELEASE_SELECT_SQL)
    .bind(isoPlusSeconds(t, -knobs.deadline_s), isoPlusSeconds(t, -knobs.beat_s), limit).all();
  const rows = results || [];
  const reclaimed = [];
  for (const r of rows) {
    const d = decideRelease(r, knobs);
    const beat = r.heartbeat_at ?? r.updated_at;
    const read = r.stale_reclaims || 0;
    const res = await env.DB.prepare(RELEASE_CAS_SQL[d.to]).bind(d.detail, t, r.id, r.job_id ?? null, beat, read).run();
    if (res.meta.changes !== 1) continue;
    reclaimed.push({
      id: r.id, repo: r.repo, pr: r.pr, head_sha: r.head_sha, to: d.to, reason: d.reason, detail: d.detail,
      releases: d.to === "superseded" ? read : read + 1, cap: knobs.cap, last_beat: beat, job_id: r.job_id ?? null,
    });
  }
  return { reclaimed, deadline_s: knobs.deadline_s, cap: knobs.cap, as_of: t, truncated: rows.length === limit };
}
