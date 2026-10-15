// conductor-state routes — the merge conductor's per-tick batch read (BH-4156).
//
// One GET answers the `pr_attempts` rows of up to 200 PRs of one repo. The
// conductor calls it once per repo per tick (`pr_attempt_batch`,
// bin/lib/jobs/conductor.sh) and answers `mc_attempt_has` / `mc_attempt_rows`
// for the PRs it covers from that answer, in place of one
// GET /api/pr-attempts per PR per line.
//
// COMPLETENESS IS EARNED (D12). The answer names the PRs it covers in
// `numbers`. A PR left out by ROW_CAP is NOT in `numbers`, `truncated` says so,
// and the client reads that PR per PR as before. A covered PR with no row is a
// measured "no attempts", which is why zero rows is a 200 and never a 404.

import { json } from "../lib/http.js";
import { ensureTable, strictInt } from "../lib/core.js";

// The protocol limits of this route, not business parameters: the request
// size (the client sends chunks of MAX_NUMBERS) and the answer size. The list
// binds as ONE json_each parameter, because D1 refuses a statement with more
// than 100 bound values.
const MAX_NUMBERS = 200;
const ROW_CAP = 5000;

// `numbers` is a comma list of strict positive integers, 1 to MAX_NUMBERS
// unique values. Anything else is null, and the handler answers 400 (D11:
// never clamp, never drop a bad element and answer for the rest).
function numbersOf(raw) {
  if (raw === null || raw === "") return null;
  const set = new Set();
  for (const part of raw.split(",")) {
    const n = strictInt(part);
    if (n === null || n < 1) return null;
    set.add(n);
  }
  if (set.size > MAX_NUMBERS) return null;
  return [...set].sort((a, b) => a - b);
}

export const routes = [
  [
    "GET", "/api/conductor-state",
    async ({ env, url, t }) => {
      await ensureTable(env, "pr_attempts");
      const repo = url.searchParams.get("repo");
      if (!repo) return json(400, { error: "repo is required" });
      const numbers = numbersOf(url.searchParams.get("numbers"));
      if (!numbers) {
        return json(400, { error: `numbers must be 1 to ${MAX_NUMBERS} positive integers, comma separated` });
      }
      const counts = await env.DB.prepare(
        `SELECT number, COUNT(*) AS n FROM pr_attempts
         WHERE repo=?1 AND number IN (SELECT value FROM json_each(?2)) GROUP BY number`
      ).bind(repo, JSON.stringify(numbers)).all();
      const per = new Map((counts.results || []).map((r) => [r.number, r.n]));
      const covered = [];
      let total = 0, truncated = false, withRows = 0;
      for (const n of numbers) {
        const k = per.get(n) || 0;
        if (total + k > ROW_CAP) { truncated = true; continue; }
        total += k;
        if (k > 0) withRows++;
        covered.push(n);
      }
      let attempts = [];
      if (withRows > 0) {
        const rows = await env.DB.prepare(
          `SELECT number, kind, sha, at FROM pr_attempts
           WHERE repo=?1 AND number IN (SELECT value FROM json_each(?2))
           ORDER BY number ASC, at DESC, rowid DESC`
        ).bind(repo, JSON.stringify(covered)).all();
        attempts = rows.results || [];
      }
      return json(200, { repo, numbers: covered, truncated, attempts, as_of: t });
    },
  ],
];
