// pr-record-refs route — BH-10217: the closed and merged PR record rows for a
// list of head refs of one repo. Read-only, bearer-gated.
//
//   GET /api/pr-record-refs?repo=<owner/name>&refs=<JSON array of head refs>
//
// ANSWER: 200 {rows:[{number, state, head_ref, merged_at}], truncated}.
// Rows are only those with state closed or merged, with an exact head_ref
// match in that repo. An open row is never in the answer.
//
// The reader is bin/lib/prr-shadow.d/tickets-snapshot-push.sh tsp_ref_states.
// The hub lane bin/tickets-snapshot-push.sh keeps a local "no merged PR for
// this ref" answer, and the set of these rows per ref is its change mark: a
// new closed or merged row for the ref ends that answer. The lane reads it
// 1 time per repo per tick, in place of 1 GitHub read per branch.
//
// Bounds: more refs than the settings row pr_records.ref_read_max is
// 400 {error:"too_many"}, never a silent cut. The rows are capped at the
// pr_records.list_limit row (routes/pr-records.js listLimit); one row past it
// sets truncated:true, and the reader then treats the whole answer as a miss.
// A D1 error is a 503 through guarded (d1Guarded), never an empty 200.
//
// Index: idx_pr_records_repo_head (repo, head_ref), added by
// lib/core.d/bh-8973-ticket-status.js through ensureColumns, which guarded
// runs before the read. CROSS JOIN makes the short JSON list the outer loop,
// so each ref is one index probe. Test W6 (EXPLAIN at 20,000 rows).
import { json } from "../lib/http.js";
import { settingsRows } from "../lib/settings-cache.js";
import { REPO_RE, guarded, listLimit } from "./pr-records.js";

// The settings row pr_records.ref_read_max (seed schema.d/202611261140-bh-10217-
// pr-record-refs.sql). REF_READ_MAX_DEFAULT is its fallback when the row is
// absent or not an integer 1..REF_READ_MAX_CEIL.
export const REF_READ_MAX_KEY = "pr_records.ref_read_max";
export const REF_READ_MAX_DEFAULT = 50;
const REF_READ_MAX_CEIL = 1000;
const REF_LEN_MAX = 255;

export const REFS_SQL = `SELECT pr_records.number AS number, pr_records.state AS state,
  pr_records.head_ref AS head_ref, pr_records.merged_at AS merged_at
  FROM json_each(?2) AS r CROSS JOIN pr_records
    ON pr_records.repo = ?1 AND pr_records.head_ref = r.value
  WHERE pr_records.state IN ('closed', 'merged')
  ORDER BY pr_records.head_ref, pr_records.number
  LIMIT ?3`;

// The pr_records.ref_read_max row, or its fallback.
export async function refReadMax(env) {
  const row = (await settingsRows(env)).byKey.get(REF_READ_MAX_KEY);
  const v = row ? String(row.value).trim() : "";
  const n = /^\d{1,4}$/.test(v) ? Number(v) : NaN;
  return n >= 1 && n <= REF_READ_MAX_CEIL ? n : REF_READ_MAX_DEFAULT;
}

// The refs query value as an array of unique strings, or null when it is not
// a JSON array of 1 or more strings of 1..REF_LEN_MAX chars.
export function parseRefs(raw) {
  if (typeof raw !== "string" || raw === "") return null;
  let v;
  try { v = JSON.parse(raw); } catch { return null; }
  if (!Array.isArray(v) || v.length === 0) return null;
  if (!v.every((s) => typeof s === "string" && s.length >= 1 && s.length <= REF_LEN_MAX)) return null;
  return [...new Set(v)];
}

export const routes = [
  [
    "GET", "/api/pr-record-refs",
    guarded(async ({ env, url }) => {
      const repo = (url.searchParams.get("repo") || "").trim().toLowerCase();
      if (!REPO_RE.test(repo)) return json(400, { error: "invalid_field", field: "repo" });
      const refs = parseRefs(url.searchParams.get("refs"));
      if (!refs) return json(400, { error: "invalid_field", field: "refs" });
      const max = await refReadMax(env);
      if (refs.length > max) return json(400, { error: "too_many", field: "refs", max });
      const limit = await listLimit(env);
      const r = await env.DB.prepare(REFS_SQL).bind(repo, JSON.stringify(refs), limit + 1).all();
      const all = (r && r.results) || [];
      const rows = all.slice(0, limit).map((x) => ({
        number: x.number, state: x.state, head_ref: x.head_ref, merged_at: x.merged_at ?? null,
      }));
      return json(200, { rows, truncated: all.length > limit });
    }),
  ],
];
