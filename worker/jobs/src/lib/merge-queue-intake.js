// BH-5667 (BH-5008 child 1): a signed GitHub delivery on a Mergify merge-queue
// ref becomes merge_queue_batches / merge_queue_checks rows.
//
// mapMergeQueueDelivery(db, event, payload, {repo, at}) answers null for every
// delivery that is not about a batch draft, so ordinary traffic costs one
// regex and no read. For a batch draft it answers the prepared statements the
// github receiver runs in the SAME env.DB.batch as the delivery-dedupe row
// (src/routes/webhooks.js), so the rows and "this delivery was seen" commit
// together or not at all. Every write is an upsert on the natural key, so a
// redelivery rewrites the same values. An upsert that would change nothing
// changes nothing (updated_at included), so a replay leaves the rows identical.
//
// What it never does: call GitHub or Mergify, write a row for a repo that is
// not armed (a `projects` row or the `merge_queue_repos` settings row), write
// a row for a fork's head, or record `merged` without pull_request.merged ===
// true.

import { jobClass } from "./merge-queue-stage.js";
import { medianStatements } from "./merge-queue-intake-medians.js";
import { stageStatements } from "./merge-queue-intake-stages.js";

export const MQ_REF_RE = /^mergify\/merge-queue\/[A-Za-z0-9._/-]{1,200}$/;

export function isMergeQueueRef(ref) {
  if (typeof ref !== "string") return false;
  return MQ_REF_RE.test(ref.replace(/^refs\/heads\//, ""));
}

// A check conclusion that makes an unmerged close a failed batch.
export const FAILED_CONCLUSIONS = ["failure", "timed_out", "cancelled", "action_required", "startup_failure"];
const OPEN_ACTIONS = ["opened", "reopened", "synchronize", "edited"];
const CHECK_ACTIONS = ["created", "completed", "rerequested", "requested_action"];
const MEMBER_CAP = 100;
const BODY_SCAN = 65536;

const obj = (v) => (v && typeof v === "object" && !Array.isArray(v) ? v : {});
const prNum = (v) => (Number.isInteger(v) && v > 0 && v < 1e9 ? v : null);
const text = (v, max) => (typeof v === "string" && v !== "" ? v.slice(0, max) : null);
const isoOf = (v) => (typeof v === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/.test(v) ? v : null);
const ghUrl = (v) => (typeof v === "string" && v.startsWith("https://github.com/") ? v.slice(0, 500) : null);
const sha = (v) => (typeof v === "string" && /^[0-9a-f]{7,64}$/i.test(v) ? v.toLowerCase() : null);

// The PRs a Mergify draft body names as `#<n>`: distinct, not the draft
// itself, sorted, at most MEMBER_CAP.
export function membersOf(body, draft) {
  const seen = new Set();
  for (const m of String(body ?? "").slice(0, BODY_SCAN).matchAll(/(?<![\w/&#])#(\d{1,9})\b/g)) {
    const n = Number(m[1]);
    if (n > 0 && n < 1e9 && n !== draft) seen.add(n);
  }
  return [...seen].sort((a, b) => a - b).slice(0, MEMBER_CAP);
}

// The draft a check_run / check_suite belongs to: the first pull_requests[]
// entry whose head ref is the check's own branch. None → no draft, no row.
function draftOf(prs, ref) {
  const hit = (Array.isArray(prs) ? prs : []).find((x) => obj(obj(x).head).ref === ref);
  return hit ? prNum(hit.number) : null;
}

function locate(event, p, repo) {
  if (event === "pull_request") {
    const pr = obj(p.pull_request);
    const head = obj(pr.head);
    if (!isMergeQueueRef(head.ref)) return null;
    // A same-repo draft only: Mergify pushes its drafts to the repo itself, so
    // a head in another repo is somebody else's branch with a lookalike name.
    if (obj(head.repo).full_name !== repo) return null;
    const draft = prNum(pr.number);
    return draft ? { ref: head.ref, draft } : null;
  }
  if (event === "check_run" || event === "check_suite") {
    const c = obj(p[event]);
    const ref = event === "check_run" ? obj(c.check_suite).head_branch : c.head_branch;
    if (!isMergeQueueRef(ref)) return null;
    const draft = draftOf(c.pull_requests, ref);
    return draft ? { ref, draft } : null;
  }
  return null;
}

// The fleet gate: one read, only after a ref matched. Slugs compare
// case-insensitively, as GitHub resolves them.
async function armed(db, repo) {
  const row = await db.prepare(
    `SELECT (SELECT COUNT(*) FROM projects WHERE lower(repo) = lower(?1)) AS n,
            (SELECT value FROM settings WHERE key = 'merge_queue_repos') AS list`
  ).bind(repo).first();
  if (row && Number(row.n) > 0) return true;
  const want = repo.toLowerCase();
  return String((row && row.list) || "").split(",").some((s) => s.trim().toLowerCase() === want);
}

function batchOpenStmt(db, { repo, draft, pr, at }) {
  return db.prepare(
    `INSERT INTO merge_queue_batches (repo, draft_pr, members_json, base_sha, started_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)
     ON CONFLICT(repo, draft_pr) DO UPDATE SET
       members_json = excluded.members_json,
       base_sha = COALESCE(excluded.base_sha, merge_queue_batches.base_sha),
       started_at = COALESCE(merge_queue_batches.started_at, excluded.started_at),
       updated_at = excluded.updated_at
     WHERE merge_queue_batches.finished_at IS NULL
       AND (merge_queue_batches.members_json IS NOT excluded.members_json
         OR merge_queue_batches.base_sha IS NOT COALESCE(excluded.base_sha, merge_queue_batches.base_sha)
         OR merge_queue_batches.started_at IS NOT COALESCE(merge_queue_batches.started_at, excluded.started_at))`
  ).bind(repo, draft, JSON.stringify(membersOf(pr.body, draft)), sha(obj(pr.base).sha), isoOf(pr.created_at), at);
}

// A close sets finished_at and outcome ONCE: the WHERE keeps a finished batch
// as it is, so a redelivered or late close cannot rewrite it.
function batchCloseStmt(db, { repo, draft, pr, at }) {
  const ph = FAILED_CONCLUSIONS.map((_, i) => `?${i + 9}`).join(",");
  // sql-ident-ok: ph is ?N placeholder text
  return db.prepare(
    `INSERT INTO merge_queue_batches (repo, draft_pr, members_json, base_sha, started_at, finished_at, outcome, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6,
       CASE WHEN ?7 = 1 THEN 'merged'
            WHEN EXISTS (SELECT 1 FROM merge_queue_checks WHERE repo = ?1 AND draft_pr = ?2 AND conclusion IN (${ph})) THEN 'failed'
            ELSE 'closed' END,
       ?8)
     ON CONFLICT(repo, draft_pr) DO UPDATE SET
       finished_at = excluded.finished_at, outcome = excluded.outcome, updated_at = excluded.updated_at
     WHERE merge_queue_batches.finished_at IS NULL`
  ).bind(repo, draft, JSON.stringify(membersOf(pr.body, draft)), sha(obj(pr.base).sha), isoOf(pr.created_at),
    isoOf(pr.closed_at) || at, pr.merged === true ? 1 : 0, at, ...FAILED_CONCLUSIONS);
}

// An out-of-order `created` after `completed` must not undo it, and a check
// row that would not change is left as it is.
function checkStmt(db, row, at) {
  return db.prepare(
    `INSERT INTO merge_queue_checks (repo, draft_pr, name, job_class, status, conclusion, url, started_at, finished_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
     ON CONFLICT(repo, draft_pr, name) DO UPDATE SET
       job_class = excluded.job_class, status = excluded.status, conclusion = excluded.conclusion,
       url = excluded.url, started_at = excluded.started_at, finished_at = excluded.finished_at,
       updated_at = excluded.updated_at
     WHERE (merge_queue_checks.status IS NOT 'completed' OR excluded.status = 'completed')
       AND (merge_queue_checks.job_class IS NOT excluded.job_class OR merge_queue_checks.status IS NOT excluded.status
         OR merge_queue_checks.conclusion IS NOT excluded.conclusion OR merge_queue_checks.url IS NOT excluded.url
         OR merge_queue_checks.started_at IS NOT excluded.started_at OR merge_queue_checks.finished_at IS NOT excluded.finished_at)`
  ).bind(row.repo, row.draft_pr, row.name, row.job_class, row.status, row.conclusion, row.url,
    row.started_at, row.finished_at, at);
}

export async function mapMergeQueueDelivery(db, event, payload, { repo, at } = {}) {
  const p = obj(payload);
  const where = locate(event, p, repo);
  if (!where) return null;
  const action = String(p.action || "");
  const { draft } = where;
  const ctx = { repo, at, draft, ref: where.ref };
  const stmts = [];

  if (event === "pull_request") {
    const pr = obj(p.pull_request);
    if (OPEN_ACTIONS.includes(action)) {
      if (!(await armed(db, repo))) return null;
      stmts.push(batchOpenStmt(db, { repo, draft, pr, at }));
    } else if (action === "closed") {
      if (!(await armed(db, repo))) return null;
      stmts.push(batchCloseStmt(db, { repo, draft, pr, at }));
    } else {
      return null;
    }
  } else if (event === "check_run") {
    if (!CHECK_ACTIONS.includes(action)) return null;
    const c = obj(p.check_run);
    const name = text(typeof c.name === "string" ? c.name.trim() : null, 200);
    if (!name) return null;
    if (!(await armed(db, repo))) return null;
    const row = {
      repo, draft_pr: draft, name, job_class: jobClass(name).slice(0, 200),
      status: text(c.status, 32), conclusion: text(c.conclusion, 32), url: ghUrl(c.html_url),
      started_at: isoOf(c.started_at), finished_at: isoOf(c.completed_at),
    };
    stmts.push(checkStmt(db, row, at));
    stmts.push(...(await medianStatements(db, row)));
  } else {
    // check_suite: no check row (a suite has no check name, and a row per
    // suite would inflate checks.total). It reaches the stage seam only.
    if (!(await armed(db, repo))) return null;
  }

  stmts.push(...(await stageStatements(db, event, p, ctx)));
  return stmts.length ? stmts : null;
}
