// landing-outcome route — BH-6745 (wave 2 of #6541): the result of a direct
// landing on its landing_decisions row (routes/landing-decisions.js).
//
// The writer is landing_direct in the conductor's READY arm, in optimistic
// mode only (bin/lib/mc/landing.sh _landing_outcome_put). The row is a RECORD:
// nothing reads it to decide a merge, so the bearer alone writes it. The
// columns outcome/outcome_at are ADDED_COLUMNS (lib/core.js), nullable and
// never backfilled: a NULL outcome is a decision with no direct attempt.
//
// INDEX. The UPDATE's WHERE is (repo, number, head, mode), the UNIQUE
// constraint's autoindex (test/landing-outcome.bh-6745.test.js W3). Retention
// is the table's own rule, landing_decisions.age.
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable, ensureColumns } from "../lib/core.js";
import { REPO_RE, prOf, shaOf } from "./verdicts.js";
import { LD_MODES } from "./landing-decisions.js";

// merged: mc_merge returned 0. 405/409/422/error: mc_merge refused. budget:
// the tick's direct budget was spent. lock: the project merge lock was held.
export const LD_OUTCOMES = ["merged", "405", "409", "422", "error", "budget", "lock"];

export const routes = [
  [
    "PUT", "/api/landing-decisions/outcome",
    (ctx) => d1Guarded("landing_decisions", async () => {
      const { env, t, body } = ctx;
      await ensureTable(env, "landing_decisions");
      await ensureColumns(env, "landing_decisions");
      const b = body || {};
      const repo = typeof b.repo === "string" ? b.repo.trim() : "";
      if (!REPO_RE.test(repo)) return json(400, { error: "repo must be owner/name" });
      const number = prOf(b.number);
      if (number === null) return json(400, { error: "number must be a positive integer" });
      const head = shaOf(b.head);
      if (!head) return json(400, { error: "head must be a full 40-hex commit sha" });
      if (!LD_MODES.includes(b.mode)) return json(400, { error: `mode must be one of ${LD_MODES.join(", ")}` });
      if (!LD_OUTCOMES.includes(b.outcome)) return json(400, { error: `outcome must be one of ${LD_OUTCOMES.join(", ")}` });
      const res = await env.DB.prepare(
        `UPDATE landing_decisions SET outcome = ?5, outcome_at = ?6
         WHERE repo = ?1 AND number = ?2 AND head = ?3 AND mode = ?4`
      ).bind(repo, number, head, b.mode, b.outcome, t).run();
      if (res.meta.changes === 1) return json(200, { ok: true });
      return json(404, { error: "no decision row" });
    }),
  ],
];
