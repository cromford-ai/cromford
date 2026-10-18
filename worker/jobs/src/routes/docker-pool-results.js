// docker-pool result rows — the reap of a pull-mode Docker host (BH-7348,
// BH-7300 slice C2). The host keeps its disk after the container exits, so it
// reaps its own build dir (bin/lib/docker-pool-reap.sh): it pushes the cost
// rows first, then posts ONE summary row here. The hub reads the rows back
// through the reap route (bin/lib/docker-pool.sh docker_pool_results_reap,
// called by bin/jobs-watchdog.sh). Nothing needs an inbound path to the host.
// Contract: docs/notes/2026-10-17-BH-7348-docker-pool-results.md.
//
// POST /api/docker-pool/result {project, key, box, result, cost_box,
//   cost_rows, unpriced_rows, cost_verified, job_id?, pr_url?, tier?, auth_account?}
//   400 on any bad field, nothing written. Then ONE read of this box's newest
//   lease for the key: none -> 409 no_lease; expired | killed | released ->
//   409 superseded (the row went back on the queue, so this run is not the
//   ticket's result); active | done -> ONE upsert on (project, key,
//   claimed_at). A re-post before the hub read replaces the row; after it,
//   409 already_reaped and the row is unchanged.
//   200 {recorded:true, claimed_at}.
// POST /api/docker-pool/results/reap {limit?}
//   limit 1..50 (default 50; anything else is 400). ONE read of the oldest
//   unread ids, then ONE UPDATE that stamps reaped_at and RETURNS only the
//   rows it stamped, so two concurrent reads never return one row twice.
//   200 {reaped:[...], backlog:0|1}; backlog 1 when the read was full.
//
// The clock is the worker's `t`; a box never sends a time. The row holds no
// money: the money is in cost_rows under cost_box.
import { d1Guarded, json } from "../lib/http.js";
import { laneName } from "../lib/core.js";

export const REAP_CAP = 50;

// ?1 project, ?2 key, ?3 box. idx_docker_pool_leases_key (ticket_key, box, then the rowid).
export const LEASE_READ_SQL = `SELECT id, claimed_at, status FROM docker_pool_leases
 WHERE project=?1 AND ticket_key=?2 AND box=?3 ORDER BY id DESC LIMIT 1`;
// ?1 project, ?2 key, ?3 claimed_at, ?4 box, ?5 cost_box, ?6 auth_account,
// ?7 job_id, ?8 result, ?9 pr_url, ?10 tier, ?11 cost_rows, ?12 unpriced_rows,
// ?13 cost_verified, ?14 t. The WHERE on the update keeps a row the hub already
// read, and a row of another box, unchanged (0 changes).
export const UPSERT_SQL = `INSERT INTO docker_pool_results (project, ticket_key, claimed_at, box, cost_box, auth_account, job_id,
   result, pr_url, tier, cost_rows, unpriced_rows, cost_verified, posted_at)
 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)
 ON CONFLICT(project, ticket_key, claimed_at) DO UPDATE SET
   cost_box=excluded.cost_box, auth_account=excluded.auth_account, job_id=excluded.job_id, result=excluded.result,
   pr_url=excluded.pr_url, tier=excluded.tier, cost_rows=excluded.cost_rows, unpriced_rows=excluded.unpriced_rows,
   cost_verified=excluded.cost_verified, posted_at=excluded.posted_at
 WHERE docker_pool_results.box=excluded.box AND docker_pool_results.reaped_at IS NULL`;
// ?1 limit. idx_docker_pool_results_unread.
export const REAP_IDS_SQL = "SELECT id FROM docker_pool_results WHERE reaped_at IS NULL ORDER BY posted_at LIMIT ?1";
// ?1 JSON ids, ?2 t. The INTEGER PRIMARY KEY; reaped_at IS NULL is the CAS.
export const REAP_STAMP_SQL = `UPDATE docker_pool_results SET reaped_at=?2
 WHERE id IN (SELECT value FROM json_each(?1)) AND reaped_at IS NULL
 RETURNING id, project, ticket_key, claimed_at, box, cost_box, auth_account, job_id, result, pr_url, tier,
   cost_rows, unpriced_rows, cost_verified, posted_at, reaped_at`;

const RESULT_RE = /^[A-Z][A-Z_]+/;
const PR_RE = /^https:\/\/github\.com\/[^/]+\/[^/]+\/pull\/[0-9]+$/;
const JOB_RE = /^[A-Za-z0-9._:-]{1,64}$/;
const COST_BOX_RE = /^[A-Za-z0-9._-]{1,64}$/;
const ACCOUNT_RE = /^[^\s,"']{1,128}$/;
// A credential is never an account label: an Anthropic key or a GitHub token.
const CREDENTIAL_RE = /^(sk-|ghs_|ghp_|gho_|ghu_|github_pat_)/;
const RESULT_MAX = 500;

const count = (v) => (Number.isInteger(v) && v >= 0 ? v : null);
const optional = (v) => (v === undefined || v === null ? "" : v);

// The validated row, or { error, reason? } for a 400.
function parse(raw) {
  const b = raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
  const project = laneName(b.project), key = laneName(b.key), box = laneName(b.box);
  if (!project || !key || !box) return { error: "project, key and box are required and must match [A-Za-z0-9._-]{1,64}" };
  const result = typeof b.result === "string" ? b.result.split(/\r?\n/, 1)[0].trim().slice(0, RESULT_MAX) : "";
  if (!RESULT_RE.test(result)) return { error: "result is required: line 1 of RESULT, starting with an upper-case word" };
  const costBox = typeof b.cost_box === "string" ? b.cost_box : "";
  if (!COST_BOX_RE.test(costBox)) return { error: "cost_box is required and must match [A-Za-z0-9._-]{1,64}" };
  // Absent is a 400, never 0: a row that says 0 cost rows must have counted them.
  const costRows = count(b.cost_rows), unpriced = count(b.unpriced_rows);
  if (costRows === null || unpriced === null) return { error: "cost_rows and unpriced_rows are required integers >= 0" };
  if (unpriced > costRows) return { error: "unpriced_rows is more than cost_rows" };
  if (b.cost_verified !== 0 && b.cost_verified !== 1) return { error: "cost_verified is required: 0 or 1" };
  const jobId = optional(b.job_id);
  if (jobId !== "" && (typeof jobId !== "string" || !JOB_RE.test(jobId))) return { error: "job_id must match [A-Za-z0-9._:-]{1,64}" };
  const prUrl = optional(b.pr_url);
  if (prUrl !== "" && (typeof prUrl !== "string" || !PR_RE.test(prUrl))) return { error: "pr_url must be a GitHub pull request URL" };
  const tier = optional(b.tier);
  if (tier !== "" && tier !== 1 && tier !== 2) return { error: "tier must be 1 or 2" };
  const acct = optional(b.auth_account);
  if (typeof acct !== "string") return { error: "auth_account must be a string" };
  if (CREDENTIAL_RE.test(acct)) return { error: "auth_account looks like a credential, not an account label", reason: "auth_account_not_a_label" };
  if (acct !== "" && !ACCOUNT_RE.test(acct)) return { error: "auth_account must be 1-128 chars with no whitespace, comma or quote" };
  return {
    project, key, box, result, costBox, costRows, unpriced, verified: b.cost_verified,
    jobId: jobId || null, prUrl: prUrl || null, tier: tier === "" ? null : tier, acct: acct || "unknown",
  };
}

const changes = (r) => Number((r && r.meta && r.meta.changes) || 0);
const refuse = (reason, t) => json(409, { error: "refused", refused: true, scope: "docker-pool-result", reason, as_of: t });

export const routes = [
  [
    "POST", "/api/docker-pool/result",
    ({ env, t, body }) => d1Guarded("docker_pool_results", async () => {
      const q = parse(body);
      if (q.error) return json(400, { error: q.error, ...(q.reason ? { reason: q.reason } : {}) });
      const lease = await env.DB.prepare(LEASE_READ_SQL).bind(q.project, q.key, q.box).first();
      if (!lease) return refuse("no_lease", t);
      if (lease.status !== "active" && lease.status !== "done") return refuse("superseded", t);
      const r = await env.DB.prepare(UPSERT_SQL).bind(
        q.project, q.key, lease.claimed_at, q.box, q.costBox, q.acct, q.jobId, q.result, q.prUrl, q.tier,
        q.costRows, q.unpriced, q.verified, t,
      ).run();
      if (changes(r) !== 1) return refuse("already_reaped", t);
      return json(200, { recorded: true, claimed_at: lease.claimed_at, as_of: t });
    }),
  ],
  [
    "POST", "/api/docker-pool/results/reap",
    ({ env, t, body }) => d1Guarded("docker_pool_results", async () => {
      const raw = body && typeof body === "object" && body.limit !== undefined ? body.limit : REAP_CAP;
      if (!Number.isInteger(raw) || raw < 1 || raw > REAP_CAP) return json(400, { error: `limit must be an integer 1..${REAP_CAP}` });
      const ids = ((await env.DB.prepare(REAP_IDS_SQL).bind(raw).all()).results || []).map((x) => x.id);
      if (ids.length === 0) return json(200, { reaped: [], backlog: 0, as_of: t });
      const rows = (await env.DB.prepare(REAP_STAMP_SQL).bind(JSON.stringify(ids), t).all()).results || [];
      const reaped = rows.slice().sort((a, b) => (a.posted_at < b.posted_at ? -1 : a.posted_at > b.posted_at ? 1 : a.id - b.id))
        .map((x) => ({
          project: x.project, key: x.ticket_key, claimed_at: x.claimed_at, box: x.box, cost_box: x.cost_box,
          auth_account: x.auth_account, job_id: x.job_id, result: x.result, pr_url: x.pr_url, tier: x.tier,
          cost_rows: Number(x.cost_rows), unpriced_rows: Number(x.unpriced_rows), cost_verified: Number(x.cost_verified),
          posted_at: x.posted_at, reaped_at: x.reaped_at,
        }));
      return json(200, { reaped, backlog: ids.length === raw ? 1 : 0, as_of: t });
    }),
  ],
];
