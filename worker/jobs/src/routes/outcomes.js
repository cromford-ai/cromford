// outcomes routes — what a build actually produced.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import {
  intOrNull, str, ensureColumns,
} from "../lib/core.js";

export const routes = [
  [
    "POST", "/api/metrics/outcomes",
    async ({ env, t, body }) => {
      const rows = Array.isArray(body.rows) ? body.rows : (body.pr ? [body] : []);
      if (!rows.length) return json(400, { error: "rows[] or a single outcome row required" });
      if (rows.length > 2000) return json(400, { error: "at most 2000 rows per request" });
      await ensureColumns(env, "outcome_metrics");
      const stmts = [];
      for (const r of rows) {
        const repo = str(r.repo, 256);
        const pr = str(r.pr, 512);
        const outcome = str(r.outcome, 64);
        if (!repo || !pr || !outcome) continue;
        // created_at is NOT touched on conflict: the first time we saw an
        // outcome is the fact, and a weekly re-scan that re-reports the same
        // revert must not make it look like it happened again this week.
        // repairs (SDLC item 3) is COALESCEd for the same reason auth_account is
        // on pr_costs: a client that has not synced bin/ omits it and binds
        // NULL, and an old client must never blank a count a newer one wrote.
        stmts.push(env.DB.prepare(
          `INSERT INTO outcome_metrics (repo, pr, outcome, day, evidence, repairs, created_at)
           VALUES (?1,?2,?3,?4,?5,?6,?7)
           ON CONFLICT(repo, pr, outcome) DO UPDATE SET
             day=COALESCE(?4, day), evidence=COALESCE(?5, evidence),
             repairs=COALESCE(?6, repairs)`
        ).bind(repo, pr, outcome, str(r.day, 10), str(r.evidence, 2000),
               intOrNull(r.repairs), t));
      }
      if (!stmts.length) return json(400, { error: "no row carried repo, pr and outcome" });
      await env.DB.batch(stmts);
      return json(200, { upserted: stmts.length, as_of: t });
    },
  ],

  [
    "GET", "/api/metrics/outcomes",
    async ({ env, url, t }) => {
      const lim = Math.min(Math.max(Number(url.searchParams.get("limit")) || 200, 1), 1000);
      // sql-ident-ok: lim is a Number clamped to 1..1000
      const rows = await env.DB.prepare(
        `SELECT * FROM outcome_metrics ORDER BY created_at DESC LIMIT ${lim}`
      ).all();
      return json(200, { outcomes: rows.results || [], as_of: t });
    },
  ],
];
