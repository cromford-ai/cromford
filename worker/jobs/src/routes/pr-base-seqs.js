// pr-base-seqs routes — BH-10215: the base sequence of each (repo, base
// branch). Table: worker/jobs/schema.d/202611261121-bh-10215-pr-base-seqs.sql.
// Writer: the push webhook (src/lib/pr-base-seq.js through
// src/lib/pr-record-intake.js). Reader: bin/lib/pr-record-serve.sh
// (_prrs_base_seqs), once per conductor tick per repo.
// test/route-table.d/bh-10215-pr-base-seqs.txt pins this route list.
// Bearer-gated, like /api/pr-records.
//
// GET /api/pr-base-seqs?repo=<owner/name>
//   200 {rows: [{base_ref, seq, pushed_at}]}. The repo is lowercased; a repo
//   that fails the pr-records repo rule is a 400 {error:"invalid_field",
//   field:"repo"}. No row for a branch means no push was seen (or retention
//   deleted it): the reader treats that as a miss, never as "not moved".
//   ONE statement, the primary key prefix (test W10 of
//   test/pr-base-seq.bh-10215.test.js), at most the pr_base_seqs.read_limit
//   settings row of rows.
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";
import { REPO_RE } from "./pr-records.js";
import { READ_SQL } from "../lib/pr-base-seq.js";

// The settings row pr_base_seqs.read_limit (seed schema.d/202611261121-
// bh-10215-pr-base-seqs.sql); this is its fallback when the row is absent or
// not an integer 1..READ_LIMIT_MAX.
const READ_LIMIT_KEY = "pr_base_seqs.read_limit";
const READ_LIMIT_DEFAULT = 500;
const READ_LIMIT_MAX = 5000;

export async function readLimit(env) {
  const row = (await settingsRows(env)).byKey.get(READ_LIMIT_KEY);
  const v = row ? String(row.value).trim() : "";
  const n = /^\d{1,4}$/.test(v) ? Number(v) : NaN;
  return n >= 1 && n <= READ_LIMIT_MAX ? n : READ_LIMIT_DEFAULT;
}

export const routes = [
  [
    "GET", "/api/pr-base-seqs",
    ({ env, url }) => d1Guarded("pr_base_seqs", async () => {
      const repo = (url.searchParams.get("repo") || "").trim().toLowerCase();
      if (!REPO_RE.test(repo)) return json(400, { error: "invalid_field", field: "repo" });
      await ensureTable(env, "pr_base_seqs");
      const res = await env.DB.prepare(READ_SQL).bind(repo, await readLimit(env)).all();
      return json(200, { rows: (res && res.results) || [] });
    }),
  ],
];
