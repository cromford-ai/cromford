// pr-record-lists routes — BH-8452 (C0): one FULL GitHub list read of a
// repo's open PRs, written into pr_records as one batch. Table:
// schema.d/202610261210-bh-8452-pr-record-lists.sql. Client:
// bin/lib/pr-record.sh pr_record_list_sync. Reader of the stamp:
// GET /api/pr-records?repo=&state= (routes/pr-records.js, `sync`).
// test/route-table.d/bh-8452-pr-record-lists.txt pins this route list.
//
// POST /api/pr-record-lists  {repo, state: "open"|"merged", at?, rows: [{number, fields}]}
//   at is the time of the GitHub read (YYYY-MM-DDTHH:MM:SSZ), default the
//   worker's clock, and a later time is the worker's clock. Each row is
//   checked as a PUT /api/pr-records body with source github; the first bad
//   row is a 400 {error, field, index} and nothing is written. Duplicate
//   numbers and more rows than the pr_records.list_limit row are a 400.
//   ONE env.DB.batch, all or nothing:
//     1. one upsert per row (source github, the per-field time guard);
//     2. ABSENT_SQL: an open record of the repo that is not in the list, and
//        whose state is not newer than `at`, gets state NULL (unknown: closed
//        or merged with a lost webhook, or open but not yet in a lagging
//        GitHub answer). A PR opened after the read keeps open. The list GET
//        counts the rows the newest sync marked as `unknown`, and a list
//        reader misses on unknown > 0 (pr-records.js UNKNOWN_SQL);
//     3. STAMP_SQL: pr_record_lists (repo, state) = {synced_at, rows};
//     4. SYNC_SQL: the stamp read back (an older `at` does not move it).
//   200 {written, absent, synced_at}.
// BH-8481: state merged too. A merged list is the newest window of merged PRs
// (`gh pr list --state merged --limit n`), never every merged PR, so step 2
// does not run (absent is 0), and every row must carry fields.state "merged"
// (else a 400 `state` at its index): a merged sync never writes an open row.
// The stamp (repo, merged) then tells a window reader the record holds that
// window. closed stays a 400.
import { json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { checkPut, guarded, listLimit, upsertSql, REPO_RE, SYNC_SQL } from "./pr-records.js";

const AT_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

// Binds: ?1 repo, ?2 the listed numbers as a JSON array, ?3 at.
// Index: the (repo, state) prefix of idx_pr_records_repo_state_upd, test X2.
export const ABSENT_SQL = `UPDATE pr_records SET state = NULL,
      fields_at = json_set(fields_at, '$.state', ?3),
      last_source = 'github',
      gh_read_at = max(coalesce(gh_read_at, ''), ?3)
    WHERE repo = ?1 AND state = 'open'
      AND number NOT IN (SELECT value FROM json_each(?2))
      AND coalesce(json_extract(fields_at, '$.state'), '') <= ?3`;
// Binds: ?1 repo, ?2 state, ?3 at, ?4 rows. synced_at only moves forward.
// Index: ux_pr_record_lists_repo_state (the conflict target), test X2.
export const STAMP_SQL = `INSERT INTO pr_record_lists (repo, state, synced_at, rows) VALUES (?1, ?2, ?3, ?4)
    ON CONFLICT(repo, state) DO UPDATE SET
      rows = CASE WHEN excluded.synced_at >= pr_record_lists.synced_at THEN excluded.rows ELSE pr_record_lists.rows END,
      synced_at = max(pr_record_lists.synced_at, excluded.synced_at)`;

// {repo, state, at, rows: [{number, fields}]} with checked values, or {error, field, index?}.
export function checkList(body, t, limit) {
  if (!isObj(body)) return { error: "invalid_body" };
  for (const k of Object.keys(body)) {
    if (!["repo", "state", "at", "rows"].includes(k)) return { error: "unknown_key", field: k };
  }
  const repo = typeof body.repo === "string" ? body.repo.trim().toLowerCase() : "";
  if (!REPO_RE.test(repo)) return { error: "invalid_field", field: "repo" };
  if (body.state !== "open" && body.state !== "merged") return { error: "invalid_field", field: "state" };
  let at = body.at === undefined ? t : body.at;
  if (typeof at !== "string" || !AT_RE.test(at) || Number.isNaN(Date.parse(at))) return { error: "invalid_field", field: "at" };
  if (Date.parse(at) > Date.parse(t)) at = t;
  if (!Array.isArray(body.rows)) return { error: "invalid_field", field: "rows" };
  if (body.rows.length > limit) return { error: "too_many_rows", field: "rows" };
  const rows = [], seen = new Set();
  for (const [index, r] of body.rows.entries()) {
    if (!isObj(r)) return { error: "invalid_field", field: "rows", index };
    for (const k of Object.keys(r)) {
      if (!["number", "fields"].includes(k)) return { error: "unknown_key", field: k, index };
    }
    const c = checkPut({ repo, number: r.number, source: "github", at, fields: r.fields }, t);
    if (c.error) return { error: c.error, field: c.field, index };
    if (body.state === "merged" && c.fields.state !== "merged") return { error: "invalid_field", field: "state", index };
    if (seen.has(c.number)) return { error: "duplicate_number", field: "number", index };
    seen.add(c.number);
    rows.push({ number: c.number, fields: c.fields });
  }
  return { repo, state: body.state, at, rows };
}

export const routes = [
  [
    "POST", "/api/pr-record-lists",
    guarded(async ({ env, t, body }) => {
      await ensureTable(env, "pr_record_lists");
      const c = checkList(body, t, await listLimit(env));
      if (c.error) {
        const out = { error: c.error };
        if (c.field) out.field = c.field;
        if (c.index !== undefined) out.index = c.index;
        return json(400, out);
      }
      const stmts = c.rows.map((r) => {
        const names = Object.keys(r.fields);
        return env.DB.prepare(upsertSql(names)).bind(c.repo, r.number, c.at, "github", ...names.map((f) => r.fields[f]));
      });
      const full = c.state === "open";
      if (full) stmts.push(env.DB.prepare(ABSENT_SQL).bind(c.repo, JSON.stringify(c.rows.map((r) => r.number)), c.at));
      stmts.push(env.DB.prepare(STAMP_SQL).bind(c.repo, c.state, c.at, c.rows.length));
      stmts.push(env.DB.prepare(SYNC_SQL).bind(c.repo, c.state));
      const res = await env.DB.batch(stmts);
      const absent = full ? res[res.length - 3] : null;
      const read = res[res.length - 1];
      const synced = read && read.results && read.results[0];
      return json(200, {
        written: c.rows.length,
        absent: (absent && absent.meta && absent.meta.changes) || 0,
        synced_at: synced ? synced.synced_at : c.at,
      });
    }),
  ],
];
