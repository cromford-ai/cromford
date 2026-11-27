// pr-record-notes routes — BH-10213: a lane's GitHub read after a PR-record
// miss, written back into pr_records, so the same miss does not repeat at
// every tick. Client: bin/lib/pr-record.sh pr_record_gh_note, called by the
// pipeline-health and dequeue-watch seams (bin/lib/prr-shadow.d/) in step
// `record` only. test/route-table.d/bh-10213-pr-record-notes.txt pins this
// route list.
//
// POST /api/pr-record-notes
//   {repo, number, kind: "statuses", head, at?, statuses: [{context, state, description, updated_at}]}
//   {repo, number, kind: "mergify", at?, comment: {id, created_at, updated_at, body, login} | null}
//   at is the ISO time the GitHub read started (YYYY-MM-DDTHH:MM:SSZ),
//   default the worker's clock; a later time is the worker's clock.
//   The GitHub answer is replayed through the webhook writes
//   (fieldWritesOf + fieldStmtOf, src/lib/pr-record-fields.js), so the
//   "newer only" rule of each field applies:
//     statuses, non-empty: each entry is a synthetic `status` delivery for
//       <head> (STATUS_MERGE_SQL: per context, newer only).
//     statuses, empty: EMPTY_STATUSES_SQL sets gh_empty.statuses =
//       {sha: head, at} on the record (repo, number) whose head_sha is <head>.
//     mergify, a comment: a synthetic issue_comment `created` delivery
//       (MERGIFY_SQL). A stored payload with the same (at, comment_id) is
//       replaced when the value differs, so a row written before #10195 gets
//       updated_at and run_id. A comment that does not parse (no payload, not
//       mergify[bot]) writes nothing: parsed false.
//     mergify, null: EMPTY_MERGIFY_SQL sets gh_empty.mergify_queue =
//       {sha: <the row's head_sha>, at}.
//   A marker is replaced only by one with a later or equal at, and a replay
//   changes 0 rows. No write moves refreshed_at: a partial answer does not
//   carry the whole PR. A marker needs an existing record; it never inserts.
//   ONE env.DB.batch. 200 {written, parsed}. 400 {error, field[, index]}
//   names the first bad field and writes nothing.
import { json } from "../lib/http.js";
import { guarded, REPO_RE, CHECKS_MAX } from "./pr-records.js";
import { fieldWritesOf, fieldStmtOf } from "../lib/pr-record-fields.js";

const AT_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;
const SHA_RE = /^[0-9a-f]{40}$/;
// Input shape bounds, not tunable limits: GitHub's comment body limit
// (65,536 characters) and a login of at most 39 characters (+ "[bot]").
const COMMENT_BODY_MAX = 65536;
const LOGIN_MAX = 64;
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const iso = (v) => typeof v === "string" && ISO_RE.test(v) && !Number.isNaN(Date.parse(v));

// The statuses marker. Binds: ?1 repo, ?2 number, ?3 head (lower case), ?4 at.
// Index: ux_pr_records_repo_number (repo, number), test W8.
export const EMPTY_STATUSES_SQL = `UPDATE pr_records SET
      gh_empty = json_set(coalesce(gh_empty, '{}'), '$.statuses', json_object('sha', ?3, 'at', ?4))
    WHERE repo = ?1 AND number = ?2 AND head_sha = ?3
      AND coalesce(json_extract(gh_empty, '$.statuses.at'), '') <= ?4
      AND json_extract(gh_empty, '$.statuses') IS NOT json_object('sha', ?3, 'at', ?4)`;

// The Mergify marker, bound to the row's head. Binds: ?1 repo, ?2 number, ?3 at.
// Index: ux_pr_records_repo_number (repo, number), test W8.
export const EMPTY_MERGIFY_SQL = `UPDATE pr_records SET
      gh_empty = json_set(coalesce(gh_empty, '{}'), '$.mergify_queue', json_object('sha', head_sha, 'at', ?3))
    WHERE repo = ?1 AND number = ?2 AND head_sha IS NOT NULL
      AND coalesce(json_extract(gh_empty, '$.mergify_queue.at'), '') <= ?3
      AND json_extract(gh_empty, '$.mergify_queue') IS NOT json_object('sha', head_sha, 'at', ?3)`;

const bad = (field, extra = {}) => ({ error: "invalid_field", field, ...extra });

// checkNote(body, t) — {repo, number, kind, at, head?, statuses?, comment?}
// with checked values, or {error, field[, index]}.
export function checkNote(body, t) {
  if (!isObj(body)) return { error: "invalid_body" };
  for (const k of Object.keys(body)) {
    if (!["repo", "number", "kind", "head", "at", "statuses", "comment"].includes(k)) return { error: "unknown_key", field: k };
  }
  const repo = typeof body.repo === "string" ? body.repo.trim().toLowerCase() : "";
  if (!REPO_RE.test(repo)) return bad("repo");
  const number = body.number;
  if (!Number.isSafeInteger(number) || number < 1 || number > 1e9) return bad("number");
  if (body.kind !== "statuses" && body.kind !== "mergify") return bad("kind");
  let at = body.at === undefined ? t : body.at;
  if (typeof at !== "string" || !AT_RE.test(at) || Number.isNaN(Date.parse(at))) return bad("at");
  if (Date.parse(at) > Date.parse(t)) at = t;
  const out = { repo, number, kind: body.kind, at };
  if (body.kind === "statuses") {
    const head = typeof body.head === "string" ? body.head.toLowerCase() : "";
    if (!SHA_RE.test(head)) return bad("head");
    if (!Array.isArray(body.statuses) || body.statuses.length > CHECKS_MAX) return bad("statuses");
    for (const [index, s] of body.statuses.entries()) {
      if (!isObj(s) || !iso(s.updated_at)) return bad("statuses", { index });
    }
    return { ...out, head, statuses: body.statuses };
  }
  if (!Object.hasOwn(body, "comment")) return bad("comment");
  const c = body.comment;
  if (c === null) return { ...out, comment: null };
  if (!isObj(c) || !Number.isSafeInteger(c.id) || c.id < 1 || !iso(c.created_at)
      || !(c.updated_at === null || c.updated_at === undefined || iso(c.updated_at))
      || typeof c.body !== "string" || c.body.length > COMMENT_BODY_MAX
      || typeof c.login !== "string" || c.login.length > LOGIN_MAX) return bad("comment");
  return { ...out, comment: c };
}

// writesOf(c, t) — the fieldWritesOf writes of a checked note, or null when
// one status entry is not a status a webhook could store (a 400).
export function writesOf(c, t) {
  if (c.kind === "statuses") {
    const writes = [];
    for (const [index, s] of c.statuses.entries()) {
      const w = fieldWritesOf("status", { sha: c.head, context: s.context, state: s.state, description: s.description,
        updated_at: s.updated_at, repository: { full_name: c.repo } }, t, CHECKS_MAX);
      if (w.length !== 1) return { index };
      writes.push(w[0]);
    }
    return { writes };
  }
  const cm = c.comment;
  return { writes: fieldWritesOf("issue_comment", { action: "created", repository: { full_name: c.repo },
    issue: { number: c.number, pull_request: {} },
    comment: { id: cm.id, created_at: cm.created_at, updated_at: cm.updated_at ?? undefined, body: cm.body, user: { login: cm.login } } }, t, CHECKS_MAX) };
}

export const routes = [
  [
    "POST", "/api/pr-record-notes",
    guarded(async ({ env, t, body }) => {
      const c = checkNote(body, t);
      if (c.error) return json(400, c);
      let stmts, parsed = true;
      if (c.kind === "statuses" && c.statuses.length === 0) {
        stmts = [env.DB.prepare(EMPTY_STATUSES_SQL).bind(c.repo, c.number, c.head, c.at)];
      } else if (c.kind === "mergify" && c.comment === null) {
        stmts = [env.DB.prepare(EMPTY_MERGIFY_SQL).bind(c.repo, c.number, c.at)];
      } else {
        const w = writesOf(c, t);
        if (!w.writes) return json(400, bad("statuses", { index: w.index }));
        parsed = w.writes.length > 0;
        stmts = w.writes.map((x) => fieldStmtOf(env.DB, x, CHECKS_MAX));
      }
      if (!stmts.length) return json(200, { written: 0, parsed });
      const res = await env.DB.batch(stmts);
      const written = res.reduce((n, r) => n + ((r && r.meta && r.meta.changes) || 0), 0);
      return json(200, { written, parsed });
    }),
  ],
];
