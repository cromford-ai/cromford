// Issue record WRITER for GitHub deliveries (BH-10199 slice 1). The tables
// and their read rule live in src/routes/issue-records.js and
// bin/lib/issue-record.sh; this file turns what a signed delivery to POST
// /webhooks/github already carries into issue_records / issue_comments writes.
//
//   issues          any action: the issue fields (newer only on GitHub's
//                   updated_at). deleted or transferred: the record of the
//                   number is removed, so the next read is no-record.
//   issue_comment   created, edited, deleted: the issue fields, the comment
//                   (deleted is terminal), and rev + 1 when the comment row
//                   changed.
//   pull_request, pull_request_review: the PR's issue fields (state, title,
//                   body, labels, updated_at), so the list backstop does not
//                   call a PR thread stale after a push or a review.
//
// THE COUNT CHECK (review of #10343): a delivery that carries issue.comments
// (or pull_request.comments) compares it with the stored count of comments
// that are not deleted, after its own writes. A different count marks a
// thread that holds the whole thread stale (COUNT_STALE_SQL): a comment
// delivery was lost, and a later delivery's newer updated_at would otherwise
// hide it from the list backstop.
//
// THE CHANGE MARK is issue_records.rev, never a wake id: the worker keeps one
// wakes row per (repo, kind, key, minute), so two comments in one minute
// share one wake row and id, while each applied write here adds 1 to rev.
// The writes ride the wake batch under the delivery claim (BH-9934), so a
// duplicate delivery changes 0 rows; a delivery that makes no wake writes
// alone. Neither path throws: a lost write is one console.warn, and the list
// backstop (stale_at) or the backfill age heals the record.
import { ensureTable } from "./core.js";
import { CLAIM_GUARD_SQL } from "./webhook-receiver.js";
import {
  issueFieldsOf, commentOf, knobs, issueUpsertSql, commentUpsertSql, COMMENT_REV_SQL,
  DROP_ISSUE_SQL, DROP_COMMENTS_SQL, COUNT_STALE_SQL,
} from "../routes/issue-records.js";
import { REPO_RE } from "../routes/pr-records.js";

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const num = (v) => (Number.isSafeInteger(v) && v >= 1 && v <= 1e9 ? v : null);
// The count check after the writes of one delivery: only when the payload
// carries an integer comment count and the issue fields parsed (their time).
const countWrite = (repo, n, obj, f) =>
  (f && isObj(obj) && Number.isSafeInteger(obj.comments) && obj.comments >= 0
    ? [{ kind: "count", repo, number: n, count: obj.comments, at: f.gh_updated_at }] : []);

// issueRecordWritesOf(event, payload, bodyMax) — PURE. [] or a list of
//   {kind:'issue', repo, number, f}            f = issueFieldsOf
//   {kind:'comment', repo, number, c, deleted} c = commentOf
//   {kind:'drop', repo, number}
//   {kind:'count', repo, number, count, at}   the payload's issue.comments (review of #10343)
export function issueRecordWritesOf(event, payload, bodyMax) {
  if (!isObj(payload)) return [];
  const repo = String((isObj(payload.repository) && payload.repository.full_name) || "").toLowerCase();
  if (!REPO_RE.test(repo)) return [];
  const action = String(payload.action || "");
  if (event === "issues") {
    const n = num(isObj(payload.issue) ? payload.issue.number : null);
    if (n === null) return [];
    if (action === "deleted" || action === "transferred") return [{ kind: "drop", repo, number: n }];
    const f = issueFieldsOf(payload.issue, bodyMax);
    return f ? [{ kind: "issue", repo, number: n, f }, ...countWrite(repo, n, payload.issue, f)] : [];
  }
  if (event === "issue_comment") {
    if (!["created", "edited", "deleted"].includes(action)) return [];
    const n = num(isObj(payload.issue) ? payload.issue.number : null);
    if (n === null) return [];
    const f = issueFieldsOf(payload.issue, bodyMax);
    const c = commentOf(payload.comment, bodyMax);
    return [
      ...(f ? [{ kind: "issue", repo, number: n, f }] : []),
      ...(c ? [{ kind: "comment", repo, number: n, c, deleted: action === "deleted" ? 1 : 0 }] : []),
      ...countWrite(repo, n, payload.issue, f),
    ];
  }
  if (event === "pull_request" || event === "pull_request_review") {
    const pr = payload.pull_request;
    const n = num(isObj(pr) ? pr.number : null);
    const f = n === null ? null : issueFieldsOf(pr, bodyMax, 1);
    return f ? [{ kind: "issue", repo, number: n, f }, ...countWrite(repo, n, pr, f)] : [];
  }
  return [];
}

// The statements of the writes. With a claim each one carries the delivery
// claim guard, its two binds numbered right after the statement's own.
function stmtsOf(DB, writes, t, claim) {
  const g = (at) => (claim ? CLAIM_GUARD_SQL(at) : "");
  const gb = () => (claim ? [claim.deliveryId, claim.claim] : []);
  const out = [];
  for (const w of writes) {
    if (w.kind === "issue") {
      const f = w.f;
      out.push(DB.prepare(issueUpsertSql(g(11)))
        .bind(w.repo, w.number, f.is_pr, f.state, f.title, f.body, f.labels, f.gh_updated_at, f.truncated, t, ...gb()));
    } else if (w.kind === "comment") {
      const c = w.c;
      out.push(DB.prepare(commentUpsertSql(g(12)))
        .bind(w.repo, w.number, c.comment_id, c.author, c.author_type, c.gh_created_at, c.gh_updated_at, c.body, c.truncated, w.deleted, t, ...gb()));
      // Right after the comment upsert: changes() is its count. With a
      // claim the guard is already in that count (0 rows on a duplicate).
      out.push(DB.prepare(COMMENT_REV_SQL).bind(w.repo, w.number, t));
    } else if (w.kind === "count") {
      out.push(DB.prepare(COUNT_STALE_SQL(g(6))).bind(w.repo, w.number, w.count, w.at, t, ...gb()));
    } else {
      // sql-ident-ok: DROP_*_SQL are module constants; g() appends CLAIM_GUARD_SQL with a numeric bind index only
      out.push(DB.prepare(DROP_COMMENTS_SQL + (claim ? ` AND ${g(3)}` : "")).bind(w.repo, w.number, ...gb()));
      // sql-ident-ok: as above
      out.push(DB.prepare(DROP_ISSUE_SQL + (claim ? ` AND ${g(3)}` : "")).bind(w.repo, w.number, ...gb()));
    }
  }
  return out;
}

async function prepared(env, event, payload) {
  const k = await knobs(env);
  const writes = issueRecordWritesOf(event, payload, k.bodyMax);
  if (!writes.length) return [];
  for (const tb of ["issue_records", "issue_comments"]) await ensureTable(env, tb);
  return writes;
}

// issueRecordStmts(env, t, event, payload, {deliveryId, claim}) — the guarded
// statements for the receiver's ONE wake batch (routes/webhooks.js). NEVER
// throws: a failure is one warn and [].
export async function issueRecordStmts(env, t, event, payload, { deliveryId, claim }) {
  try {
    const writes = await prepared(env, event, payload);
    return stmtsOf(env.DB, writes, t, { deliveryId, claim });
  } catch (e) {
    console.warn("[issue-record-intake] webhook record statements not built", event, String((e && e.message) || e).slice(0, 300));
    return [];
  }
}

// recordIssueRecord — {written} (rows changed) or {written: 0, error}. Never throws.
export async function recordIssueRecord(env, t, event, payload) {
  try {
    const writes = await prepared(env, event, payload);
    if (!writes.length) return { written: 0 };
    const res = await env.DB.batch(stmtsOf(env.DB, writes, t, null));
    return { written: res.reduce((n, r) => n + ((r && r.meta && r.meta.changes) || 0), 0) };
  } catch (e) {
    const error = String((e && e.message) || e).slice(0, 300);
    console.warn("[issue-record-intake] webhook record write failed", event, error);
    return { written: 0, error };
  }
}
