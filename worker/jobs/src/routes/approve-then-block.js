// approve-then-block route — BH-9501 (BH-9441.4): the share of PRs where the
// lead review blocked after an in-build APPROVE, over the `days` days that end
// at the end of `day`. Read by bin/daily-digest.sh (step 7e) into the digest's
// "Lead review after in-build APPROVE" line.
//
// NEW family (test/route-table.d/bh-9501-approve-then-block.txt).
//   GET /api/metrics/approve-then-block?day=YYYY-MM-DD[&days=1..60]
//     -> 200 {ok:true, day, from, to, days, cohort, blocked, share, repos:[{repo, cohort, blocked, share}]}
//        share is null when the cohort is 0.
//     -> 400 {error} on a bad day or days, before any read.
// Read-only. The gate columns are added columns (lib/core.d/0000-added-columns.js),
// so ensureTable + ensureColumns run before the read. A thrown read is not
// caught into a 200. The definition and the SQL are in lib/approve-then-block.js.

import { json, overloadGuardedRoute } from "../lib/http.js";
import { ensureColumns, ensureTable } from "../lib/core.js";
import { parseParams, approveBlockSql, foldApproveBlock } from "../lib/approve-then-block.js";

export const routes = [
  [
    "GET", "/api/metrics/approve-then-block",
    overloadGuardedRoute("pr_state_events", async ({ env, url, t }) => {
      const p = parseParams(url.searchParams, t);
      if (p.error) return json(400, { error: p.error });
      await ensureTable(env, "pr_state_events");
      await ensureColumns(env, "pr_state_events");
      const res = await env.DB.prepare(approveBlockSql()).bind(p.from, p.to).all();
      const fold = foldApproveBlock(res.results || []);
      return json(200, { ok: true, day: p.win.day, from: p.from, to: p.to, days: p.days, ...fold });
    }),
  ],
];
