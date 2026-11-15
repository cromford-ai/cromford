// preplan-retire route (BH-9672) — the pre-plan a plan thread gate refused.
//
// The gate (bin/lib/plan-thread.sh, call sites in bin/lib/rb/plan.sh and
// bin/lib/rb/review.sh) refuses a pre-plan that misses a newer comment. It
// used to remove only the hub plans/ dir, so a row in this table stayed and
// the next build adopted it again: BH-8841 ended PLAN_STALE four times on the
// same row. bin/lib/plan-stale-replan.sh:psr_retire_row calls this route.
//
// THE DELETE IS GUARDED BY THE REFUSED PLAN'S STAMP. thread_at_max is the
// stamp of the plan the gate refused. A row whose thread_at is newer is a
// pre-plan the hub's preplan tick published after it, and it survives. A row
// with no thread_at cannot say when it read the thread and goes. The guard is
// required: a request without it is 400, so this route never deletes blind.
// One statement on the primary key (sqlite_autoindex_preplans_1).

import { json } from "../lib/http.js";
import { ensureTable, ensureColumns, laneName } from "../lib/core.js";

export const PREPLAN_RETIRE_SQL =
  "DELETE FROM preplans WHERE project=?1 AND ticket_key=?2 AND (thread_at IS NULL OR thread_at <= ?3)";

const ISO_SECOND = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

export const routes = [
  [
    "POST", "/api/preplans/retire",
    async ({ env, body }) => {
      const project = laneName(body.project);
      const key = laneName(body.ticket_key || body.key);
      if (!project) return json(400, { error: "project is required and must match [A-Za-z0-9._-]{1,64}" });
      if (!key) return json(400, { error: "ticket_key is required and must match [A-Za-z0-9._-]{1,64}" });
      const max = String(body.thread_at_max || "");
      if (!ISO_SECOND.test(max)) return json(400, { error: "thread_at_max must be a whole-second UTC ISO stamp" });
      await ensureTable(env, "preplans");
      await ensureColumns(env, "preplans");
      const r = await env.DB.prepare(PREPLAN_RETIRE_SQL).bind(project, key, max).run();
      return json(200, { retired: Number(r?.meta?.changes) || 0 });
    },
  ],
];
