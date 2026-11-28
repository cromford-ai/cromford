// issue-records routes — BH-10199 (slice 1): the fleet's own record of an
// issue or PR thread (issue state and comments). Tables:
// worker/jobs/schema.d/202611270600-bh-10199-issue-records.sql. Client:
// bin/lib/issue-record.sh. test/route-table.d/bh-10199-issue-records.txt pins
// this route list.
//
// GET /api/issue-records?repo=&number=
//   200 {row, comments, why, sync}. ONE batch, three statements. row is null
//   when the thread has no record. comments: the stored comments that are not
//   deleted, oldest first, at most issue_records.comments_max + 1. why is null
//   when the record is READY (it holds the whole thread and nothing says it
//   missed a change), else one miss word, in this order:
//     no-record    no row
//     no-backfill  no full GitHub write yet (backfill_at NULL)
//     stale        a list sync saw a GitHub change no webhook brought
//     backfill-old the last full write is older than issue_records.backfill_max_age_s
//     no-sync      no complete list sync of the repo
//     sync-old     the last complete list sync is older than issue_records.sync_max_age_s
//     truncated    a stored body was cut at issue_records.body_max
//     too-many     more comments than issue_records.comments_max
//   Every age is the worker clock minus a worker-clock stamp.
//
// PUT /api/issue-records  {repo, number, base_rev, issue, comments}
//   A full GitHub read of the thread: the REST issue object (or null for a
//   comments-only read of a stored row, PUT_THREAD_SQL) and its whole
//   REST comment list. base_rev is the rev the reader saw BEFORE its GitHub
//   read (0 = no row). Every statement runs only while the stored rev is
//   still base_rev, so a webhook that landed during the read wins and nothing
//   is written (applied:false). Applied: the comments are upserted (seen_at
//   moves), a stored comment not in the list is marked deleted, the issue
//   fields are replaced, backfill_at = now, stale_at cleared when the read is
//   not older than it, rev + 1. A fourth statement reads the row back. 200 {applied, rev}.
//
// POST /api/issue-record-syncs/claim  {repo}
//   The per-repo list backstop is due when the last complete sync and the last
//   claim are older than issue_records.sync_every_s. Due: the claim is stored
//   (a lease of the same length) and 200 {due: true, since, started,
//   pages_max, every_s}: since is the stored mark (GitHub's clock), or now minus
//   issue_records.backfill_max_age_s for a repo with none; started is the
//   worker clock of the claim. Not due: 200 {due: false, every_s}. every_s
//   is the row issue_records.sync_every_s: a box does not ask again for the
//   repo inside it (bin/lib/issue-record.sh, the claim marker).
//
// POST /api/issue-record-syncs  {repo, started, mark, complete, items}
//   One list read (`issues?state=all&since=&sort=updated&direction=asc`).
//   Each item updates an EXISTING record only, when GitHub's updated_at is
//   newer than the record's: the issue fields, gh_updated_at, stale_at (the
//   comments may have changed), rev + 1. complete: synced_at = started (the
//   claim time). Incomplete: the mark moves, synced_at does not. 200
//   {written, synced_at, mark}.
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";
import { REPO_RE } from "./pr-records.js";

const ISO_RE = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?Z$/;
const LOGIN_RE = /^[A-Za-z0-9-]{1,39}(\[bot\])?$/;
const TYPE_RE = /^[A-Za-z]{1,32}$/;
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const str = (v) => (typeof v === "string" ? v : "");
const posInt = (v) => (Number.isSafeInteger(v) && v >= 1 && v <= 1e12 ? v : null);
// A GitHub time without its fraction, or null.
export const isoOf = (v) => { const m = ISO_RE.exec(str(v)); return m && !Number.isNaN(Date.parse(`${m[1]}Z`)) ? `${m[1]}Z` : null; };
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

// The settings rows of this record, each with its code fallback (the seed in
// the schema fragment is the same value).
export const KNOBS = {
  backfillMaxAge: ["issue_records.backfill_max_age_s", 604800, 1, 31536000],
  syncMaxAge: ["issue_records.sync_max_age_s", 1800, 1, 31536000],
  syncEvery: ["issue_records.sync_every_s", 600, 1, 86400],
  pagesMax: ["issue_records.sync_pages_max", 5, 1, 100],
  bodyMax: ["issue_records.body_max", 65536, 1, 1048576],
  commentsMax: ["issue_records.comments_max", 1000, 1, 10000],
  itemsMax: ["issue_records.items_max", 500, 1, 5000],
};
export async function knobs(env) {
  const byKey = (await settingsRows(env)).byKey;
  const out = {};
  for (const [name, [key, def, min, max]] of Object.entries(KNOBS)) {
    const row = byKey.get(key);
    const v = row ? String(row.value).trim() : "";
    const n = /^\d{1,9}$/.test(v) ? Number(v) : NaN;
    out[name] = n >= min && n <= max ? n : def;
  }
  return out;
}

// A body cut at max characters: [text, truncated 0|1].
const cut = (v, max) => { const s = str(v); return s.length > max ? [s.slice(0, max), 1] : [s, 0]; };

// The record columns of a REST issue (or the issue view of a pull request):
// {is_pr, state, title, body, labels, gh_updated_at, truncated}, or null when
// the object has no state word or no updated_at.
export function issueFieldsOf(issue, bodyMax, isPr = null) {
  if (!isObj(issue)) return null;
  const merged = Boolean(issue.merged_at) || issue.merged === true;
  const state = merged ? "closed" : str(issue.state);
  const upd = isoOf(issue.updated_at);
  if (!["open", "closed"].includes(state) || !upd) return null;
  const [body, tb] = cut(issue.body === null ? "" : issue.body, bodyMax);
  const [title, tt] = cut(issue.title, bodyMax);
  const labels = Array.isArray(issue.labels)
    ? issue.labels.map((l) => (isObj(l) ? str(l.name) : str(l))).filter((s) => s.length > 0 && s.length <= 100).slice(0, 100)
    : [];
  return {
    is_pr: isPr === null ? (isObj(issue.pull_request) ? 1 : 0) : isPr,
    state, title, body, labels: JSON.stringify(labels), gh_updated_at: upd, truncated: tb || tt ? 1 : 0,
  };
}

// The stored columns of a REST comment, or null.
export function commentOf(c, bodyMax) {
  if (!isObj(c)) return null;
  const id = posInt(c.id), created = isoOf(c.created_at), updated = isoOf(c.updated_at) || created;
  const user = isObj(c.user) ? c.user : {};
  if (id === null || !created) return null;
  const [body, truncated] = cut(c.body === null ? "" : c.body, bodyMax);
  return {
    comment_id: id, author: LOGIN_RE.test(str(user.login)) ? user.login : null,
    author_type: TYPE_RE.test(str(user.type)) ? user.type : null,
    gh_created_at: created, gh_updated_at: updated, body, truncated,
  };
}

// The fields that count as a change of the issue row (rev + 1).
const SAME_ISSUE = `issue_records.is_pr IS excluded.is_pr AND issue_records.state IS excluded.state
      AND issue_records.title IS excluded.title AND issue_records.body IS excluded.body
      AND issue_records.labels IS excluded.labels AND issue_records.truncated IS excluded.truncated`;

// The webhook upsert of the issue fields, newer only on gh_updated_at. Binds:
// ?1 repo ?2 number ?3 is_pr ?4 state ?5 title ?6 body ?7 labels ?8 gh_updated_at
// ?9 truncated ?10 now. A replay (same values, same time) changes nothing; a
// newer time with the same values moves gh_updated_at and refreshed_at, rev + 0.
// guardAt appends the delivery claim guard (lib/webhook-receiver.js) at that bind.
export const issueUpsertSql = (guard = "") => `INSERT INTO issue_records
      (repo, number, is_pr, state, title, body, labels, gh_updated_at, truncated, created_at, refreshed_at)
    SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10 WHERE ${guard || "1"}
    ON CONFLICT(repo, number) DO UPDATE SET
      is_pr = excluded.is_pr, state = excluded.state, title = excluded.title, body = excluded.body,
      labels = excluded.labels, truncated = excluded.truncated, gh_updated_at = excluded.gh_updated_at,
      rev = issue_records.rev + (CASE WHEN ${SAME_ISSUE} THEN 0 ELSE 1 END),
      refreshed_at = excluded.refreshed_at
    WHERE (issue_records.gh_updated_at IS NULL OR issue_records.gh_updated_at <= excluded.gh_updated_at)
      AND NOT (${SAME_ISSUE} AND issue_records.gh_updated_at IS excluded.gh_updated_at)`;

// The webhook upsert of one comment. Binds: ?1 repo ?2 number ?3 comment_id
// ?4 author ?5 author_type ?6 gh_created_at ?7 gh_updated_at ?8 body
// ?9 truncated ?10 deleted ?11 now. A deleted comment stays deleted (a late
// `created` does not bring it back); an edit applies only when it is newer,
// or the same time with another body; a replay changes nothing.
export const commentUpsertSql = (guard = "") => `INSERT INTO issue_comments
      (repo, number, comment_id, author, author_type, gh_created_at, gh_updated_at, body, truncated, deleted, seen_at)
    SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11 WHERE ${guard || "1"}
    ON CONFLICT(repo, comment_id) DO UPDATE SET
      number = excluded.number, author = excluded.author, author_type = excluded.author_type,
      gh_created_at = excluded.gh_created_at, gh_updated_at = excluded.gh_updated_at, body = excluded.body,
      truncated = excluded.truncated, deleted = excluded.deleted, seen_at = excluded.seen_at
    WHERE issue_comments.deleted = 0
      AND (excluded.deleted = 1 OR issue_comments.gh_updated_at IS NULL
           OR issue_comments.gh_updated_at < excluded.gh_updated_at
           OR (issue_comments.gh_updated_at = excluded.gh_updated_at AND issue_comments.body IS NOT excluded.body))`;

// rev + 1 when the statement right before it (the comment upsert) changed a
// row. Binds: ?1 repo ?2 number ?3 now. changes() is that statement's count.
export const COMMENT_REV_SQL = `UPDATE issue_records SET rev = rev + 1, refreshed_at = ?3
    WHERE repo = ?1 AND number = ?2 AND changes() > 0`;

// THE COUNT CHECK (review of #10343). A later delivery moves gh_updated_at
// past a LOST comment delivery, so the list backstop never sees that thread.
// Each delivery that carries issue.comments compares it with the stored count
// of comments that are not deleted. A different count on a record that holds
// the whole thread (backfill_at set) sets stale_at, so the next read is a
// miss and the full read repairs it. An older delivery (out of order:
// gh_updated_at is already past it) checks nothing: its count is old. Binds: ?1 repo ?2 number ?3 count
// ?4 the delivery's gh_updated_at ?5 now. A row already stale at or after ?4
// is left alone (a replay changes 0 rows). The count is one SEARCH on
// idx_issue_comments_thread, once per statement.
export const COUNT_STALE_SQL = (guard = "") => `UPDATE issue_records SET
      stale_at = max(coalesce(stale_at, ''), ?4), rev = rev + 1, refreshed_at = ?5
    WHERE repo = ?1 AND number = ?2 AND backfill_at IS NOT NULL
      AND gh_updated_at <= ?4 AND (stale_at IS NULL OR stale_at < ?4)
      AND ?3 IS NOT (SELECT COUNT(*) FROM issue_comments WHERE repo = ?1 AND number = ?2 AND deleted = 0)${guard ? ` AND ${guard}` : ""}`;

// An `issues.deleted` or `issues.transferred` delivery: the record of that
// number is gone (the next read is no-record and reads GitHub). Binds ?1 ?2.
export const DROP_ISSUE_SQL = "DELETE FROM issue_records WHERE repo = ?1 AND number = ?2";
export const DROP_COMMENTS_SQL = "DELETE FROM issue_comments WHERE repo = ?1 AND number = ?2";

export const GET_SQL = "SELECT * FROM issue_records WHERE repo = ?1 AND number = ?2";
// Binds ?1 repo ?2 number ?3 limit. Index: idx_issue_comments_thread.
export const COMMENTS_SQL = `SELECT comment_id, author, author_type, gh_created_at, gh_updated_at, body, truncated
    FROM issue_comments WHERE repo = ?1 AND number = ?2 AND deleted = 0
    ORDER BY gh_created_at, comment_id LIMIT ?3`;
export const SYNC_GET_SQL = "SELECT mark, synced_at, claim_at, rows FROM issue_record_syncs WHERE repo = ?1";

// THE PUT. The guard: the stored rev (0 for no row) is still the base. Binds
// ?1 repo ?2 number, then the statement's own; the guard bind is named.
const REV_GUARD = (b) => `coalesce((SELECT rev FROM issue_records WHERE repo = ?1 AND number = ?2), 0) = ?${b}`;
// Binds: ?1 repo ?2 number ?3 comments JSON ?4 now ?5 base_rev.
export const PUT_COMMENTS_SQL = `INSERT INTO issue_comments
      (repo, number, comment_id, author, author_type, gh_created_at, gh_updated_at, body, truncated, deleted, seen_at)
    SELECT ?1, ?2, json_extract(value, '$.comment_id'), json_extract(value, '$.author'), json_extract(value, '$.author_type'),
           json_extract(value, '$.gh_created_at'), json_extract(value, '$.gh_updated_at'), json_extract(value, '$.body'),
           json_extract(value, '$.truncated'), 0, ?4
      FROM json_each(?3) WHERE ${REV_GUARD(5)}
    ON CONFLICT(repo, comment_id) DO UPDATE SET
      number = excluded.number, author = excluded.author, author_type = excluded.author_type,
      gh_created_at = excluded.gh_created_at, gh_updated_at = excluded.gh_updated_at, body = excluded.body,
      truncated = excluded.truncated, deleted = 0, seen_at = excluded.seen_at`;
// Binds: ?1 repo ?2 number ?3 the listed comment ids (JSON) ?4 now ?5 base_rev.
export const PUT_ABSENT_SQL = `UPDATE issue_comments SET deleted = 1, seen_at = ?4
    WHERE repo = ?1 AND number = ?2 AND deleted = 0
      AND comment_id NOT IN (SELECT value FROM json_each(?3)) AND ${REV_GUARD(5)}`;
// Binds: ?1 repo ?2 number ?3 is_pr ?4 state ?5 title ?6 body ?7 labels
// ?8 gh_updated_at ?9 truncated ?10 now ?11 base_rev. Runs LAST: it is the
// statement that moves rev, so the guard of the statements above still saw base.
export const PUT_ISSUE_SQL = `INSERT INTO issue_records
      (repo, number, is_pr, state, title, body, labels, gh_updated_at, truncated, backfill_at, created_at, refreshed_at)
    SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10, ?10 WHERE ${REV_GUARD(11)}
    ON CONFLICT(repo, number) DO UPDATE SET
      is_pr = excluded.is_pr, state = excluded.state, title = excluded.title, body = excluded.body,
      labels = excluded.labels, truncated = excluded.truncated,
      gh_updated_at = max(coalesce(issue_records.gh_updated_at, ''), excluded.gh_updated_at),
      stale_at = CASE WHEN issue_records.stale_at IS NOT NULL AND issue_records.stale_at > excluded.gh_updated_at
                      THEN issue_records.stale_at END,
      backfill_at = excluded.backfill_at, rev = issue_records.rev + 1, refreshed_at = excluded.refreshed_at`;

// The comments-only PUT (issue null, a PR thread): the issue fields stay as
// stored (the webhooks and the list sync keep them); the comment set is now
// whole, so backfill_at moves and stale_at is cleared. Binds: ?1 repo
// ?2 number ?3 now ?4 base_rev. An existing row only.
export const PUT_THREAD_SQL = `UPDATE issue_records SET backfill_at = ?3, stale_at = NULL, rev = rev + 1, refreshed_at = ?3
    WHERE repo = ?1 AND number = ?2 AND rev = ?4`;

// THE SYNC. Binds: ?1 repo ?2 now ?3 now - sync_every_s. A row is returned
// only when the claim was taken (insert, or the update's WHERE held).
export const CLAIM_SQL = `INSERT INTO issue_record_syncs (repo, claim_at) VALUES (?1, ?2)
    ON CONFLICT(repo) DO UPDATE SET claim_at = excluded.claim_at
    WHERE (issue_record_syncs.synced_at IS NULL OR issue_record_syncs.synced_at <= ?3)
      AND (issue_record_syncs.claim_at IS NULL OR issue_record_syncs.claim_at <= ?3)
    RETURNING mark`;
// One listed item. Binds: ?1 repo ?2 number ?3 is_pr ?4 state ?5 title ?6 body
// ?7 labels ?8 gh_updated_at ?9 truncated ?10 now. Existing rows only, GitHub's
// updated_at newer than the record's.
export const SYNC_ITEM_SQL = `UPDATE issue_records SET
      is_pr = ?3, state = ?4, title = ?5, body = ?6, labels = ?7, truncated = ?9,
      gh_updated_at = ?8, stale_at = max(coalesce(stale_at, ''), ?8), rev = rev + 1, refreshed_at = ?10
    WHERE repo = ?1 AND number = ?2 AND (gh_updated_at IS NULL OR gh_updated_at < ?8)`;
// Binds: ?1 repo ?2 mark or NULL ?3 synced_at or NULL ?4 rows.
export const SYNC_STAMP_SQL = `INSERT INTO issue_record_syncs (repo, mark, synced_at, rows) VALUES (?1, ?2, ?3, ?4)
    ON CONFLICT(repo) DO UPDATE SET
      mark = CASE WHEN ?2 IS NOT NULL AND (issue_record_syncs.mark IS NULL OR issue_record_syncs.mark < ?2) THEN ?2 ELSE issue_record_syncs.mark END,
      synced_at = CASE WHEN ?3 IS NOT NULL AND (issue_record_syncs.synced_at IS NULL OR issue_record_syncs.synced_at < ?3) THEN ?3 ELSE issue_record_syncs.synced_at END,
      rows = ?4, claim_at = NULL`;

const TABLES = ["issue_records", "issue_comments", "issue_record_syncs"];
const guarded = (fn) => (ctx) =>
  d1Guarded("issue_records", async () => {
    for (const tb of TABLES) await ensureTable(ctx.env, tb);
    return fn(ctx);
  });
const bad = (field) => json(400, { error: "invalid_field", field });
const repoOf = (v) => { const r = str(v).trim().toLowerCase(); return REPO_RE.test(r) ? r : null; };
const ageS = (t, at) => Math.floor((Date.parse(t) - Date.parse(at)) / 1000);

// The miss word of one GET answer, or null (ready). Exported for the tests.
export function whyOf(t, row, comments, sync, k) {
  if (!row) return "no-record";
  if (!row.backfill_at) return "no-backfill";
  if (row.stale_at) return "stale";
  const ba = ageS(t, row.backfill_at);
  if (!(ba >= 0 && ba <= k.backfillMaxAge)) return "backfill-old";
  if (!sync || !sync.synced_at) return "no-sync";
  const sa = ageS(t, sync.synced_at);
  if (!(sa >= 0 && sa <= k.syncMaxAge)) return "sync-old";
  if (row.truncated || comments.some((c) => c.truncated)) return "truncated";
  if (comments.length > k.commentsMax) return "too-many";
  return null;
}

async function getRecord({ env, url, t }) {
  const repo = repoOf(url.searchParams.get("repo"));
  const n = posInt(Number(url.searchParams.get("number")));
  if (!repo) return bad("repo");
  if (n === null) return bad("number");
  const k = await knobs(env);
  const [r, c, s] = await env.DB.batch([
    env.DB.prepare(GET_SQL).bind(repo, n),
    env.DB.prepare(COMMENTS_SQL).bind(repo, n, k.commentsMax + 1),
    env.DB.prepare(SYNC_GET_SQL).bind(repo),
  ]);
  const row = (r && r.results && r.results[0]) || null;
  const comments = (c && c.results) || [];
  const sync = (s && s.results && s.results[0]) || null;
  if (row && typeof row.labels === "string") { try { row.labels = JSON.parse(row.labels); } catch { /* left as stored */ } }
  return json(200, {
    row, comments: row ? comments : [], why: whyOf(t, row, comments, sync, k),
    sync: sync ? { synced_at: sync.synced_at, mark: sync.mark, age_s: sync.synced_at ? ageS(t, sync.synced_at) : null } : null,
  });
}

async function putRecord({ env, t, body }) {
  if (!isObj(body)) return json(400, { error: "invalid_body" });
  for (const key of Object.keys(body)) {
    if (!["repo", "number", "base_rev", "issue", "comments"].includes(key)) return json(400, { error: "unknown_key", field: key });
  }
  const repo = repoOf(body.repo);
  if (!repo) return bad("repo");
  const n = posInt(body.number);
  if (n === null) return bad("number");
  if (!(Number.isSafeInteger(body.base_rev) && body.base_rev >= 0)) return bad("base_rev");
  const k = await knobs(env);
  // issue null: a comments-only read (a PR thread). It needs a stored row.
  const f = body.issue === null ? null : issueFieldsOf(body.issue, k.bodyMax);
  if (body.issue !== null && (!f || (posInt(body.issue.number) !== null && body.issue.number !== n))) return bad("issue");
  if (body.issue === null && body.base_rev < 1) return bad("base_rev");
  if (!Array.isArray(body.comments) || body.comments.length > k.commentsMax) return bad("comments");
  const cs = body.comments.map((c) => commentOf(c, k.bodyMax));
  if (cs.some((c) => c === null)) return bad("comments");
  const ids = JSON.stringify(cs.map((c) => c.comment_id));
  const res = await env.DB.batch([
    env.DB.prepare(PUT_COMMENTS_SQL).bind(repo, n, JSON.stringify(cs), t, body.base_rev),
    env.DB.prepare(PUT_ABSENT_SQL).bind(repo, n, ids, t, body.base_rev),
    f ? env.DB.prepare(PUT_ISSUE_SQL).bind(repo, n, f.is_pr, f.state, f.title, f.body, f.labels, f.gh_updated_at, f.truncated, t, body.base_rev)
      : env.DB.prepare(PUT_THREAD_SQL).bind(repo, n, t, body.base_rev),
    env.DB.prepare(GET_SQL).bind(repo, n),
  ]);
  // The issue statement runs only under the guard: its change count is the answer.
  const applied = ((res[2] && res[2].meta && res[2].meta.changes) || 0) > 0;
  const row = res[3] && res[3].results && res[3].results[0];
  return json(200, applied && row ? { applied: true, rev: row.rev } : { applied: false, rev: null });
}

async function claimSync({ env, t, body }) {
  if (!isObj(body)) return json(400, { error: "invalid_body" });
  const repo = repoOf(body.repo);
  if (!repo) return bad("repo");
  const k = await knobs(env);
  const now = Date.parse(t);
  const r = await env.DB.prepare(CLAIM_SQL).bind(repo, t, iso(now - k.syncEvery * 1000)).first();
  if (!r) return json(200, { due: false, every_s: k.syncEvery });
  return json(200, { due: true, since: r.mark || iso(now - k.backfillMaxAge * 1000), started: t, pages_max: k.pagesMax, every_s: k.syncEvery });
}

async function writeSync({ env, t, body }) {
  if (!isObj(body)) return json(400, { error: "invalid_body" });
  for (const key of Object.keys(body)) {
    if (!["repo", "started", "mark", "complete", "items"].includes(key)) return json(400, { error: "unknown_key", field: key });
  }
  const repo = repoOf(body.repo);
  if (!repo) return bad("repo");
  const started = isoOf(body.started);
  if (!started || Date.parse(started) > Date.parse(t)) return bad("started");
  const mark = body.mark === null || body.mark === undefined || body.mark === "" ? null : isoOf(body.mark);
  if (mark === null && !(body.mark === null || body.mark === undefined || body.mark === "")) return bad("mark");
  if (typeof body.complete !== "boolean") return bad("complete");
  const k = await knobs(env);
  if (!Array.isArray(body.items) || body.items.length > k.itemsMax) return bad("items");
  const stmts = [];
  for (const it of body.items) {
    const num = isObj(it) ? posInt(it.number) : null;
    const f = num === null ? null : issueFieldsOf(it, k.bodyMax);
    if (!f) return bad("items");
    stmts.push(env.DB.prepare(SYNC_ITEM_SQL).bind(repo, num, f.is_pr, f.state, f.title, f.body, f.labels, f.gh_updated_at, f.truncated, t));
  }
  stmts.push(env.DB.prepare(SYNC_STAMP_SQL).bind(repo, mark, body.complete ? started : null, body.items.length));
  stmts.push(env.DB.prepare(SYNC_GET_SQL).bind(repo));
  const res = await env.DB.batch(stmts);
  const written = res.slice(0, -2).reduce((s, x) => s + ((x && x.meta && x.meta.changes) || 0), 0);
  const st = res[res.length - 1] && res[res.length - 1].results && res[res.length - 1].results[0];
  return json(200, { written, synced_at: (st && st.synced_at) || null, mark: (st && st.mark) || null });
}

export const routes = [
  ["GET", "/api/issue-records", guarded(getRecord)],
  ["PUT", "/api/issue-records", guarded(putRecord)],
  ["POST", "/api/issue-record-syncs/claim", guarded(claimSync)],
  ["POST", "/api/issue-record-syncs", guarded(writeSync)],
];
