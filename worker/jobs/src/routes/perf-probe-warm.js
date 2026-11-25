// perf probe warm-up watermark routes — BH-9792. bin/perf-probe-warm.sh (the
// post-deploy warm-up hub lane) reads the newest row of a project before it
// warms a GitHub deployment, and writes one row per deployment after
// (schema.d/202611250147-bh-9792-perf-probe-warm.sql). Client verbs:
// `jobs-client.sh perf-probe warm-get|warm-put`
// (bin/jobs-client.d/bh-9792-perf-probe-warm.sh).
//
// GET  /api/perf-probe/warm?project=<p>
//   200 {row: {project, deployment_id, outcome, routes, over, warmed_at}} for
//   the newest row by warmed_at, or {row: null}.
// POST /api/perf-probe/warm {project, deployment_id, outcome, routes, over}
//   INSERT OR IGNORE on (project, deployment_id), warmed_at = now. A repeat
//   keeps the first row. 200 {created: 1|0}.
// A bad field is 400 {error: <field>}.
// Note: docs/notes/2026-11-17-BH-9786-perf-probe.md (Warm-up and keep-warm).

import { json, d1Guarded } from "../lib/http.js";

// Input validation of one field, not a limit on work (the rule of
// perf-probe.js): the project rule and the run_key rule of the results route.
const PROJECT_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;
const DEPLOYMENT_RE = /^[A-Za-z0-9._:-]{1,80}$/;
const OUTCOMES = new Set(["warmed", "deploy-failed"]);

export const SQL = {
  latest: `SELECT project, deployment_id, outcome, routes, over, warmed_at
             FROM perf_probe_warm WHERE project=?1 ORDER BY warmed_at DESC LIMIT 1`,
  insert: `INSERT OR IGNORE INTO perf_probe_warm (project, deployment_id, outcome, routes, over, warmed_at)
           VALUES (?1,?2,?3,?4,?5,?6)`,
};

const bad = (field) => json(400, { error: field });
const okCount = (v) => v === undefined || (Number.isInteger(v) && v >= 0);

export const routes = [
  [
    "GET", "/api/perf-probe/warm",
    async ({ env, url }) => {
      const project = url.searchParams.get("project") || "";
      if (!PROJECT_RE.test(project)) return bad("project");
      return d1Guarded("perf_probe_warm", async () => {
        const row = await env.DB.prepare(SQL.latest).bind(project).first();
        return json(200, { row: row || null });
      });
    },
  ],
  [
    "POST", "/api/perf-probe/warm",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      if (typeof b.project !== "string" || !PROJECT_RE.test(b.project)) return bad("project");
      if (typeof b.deployment_id !== "string" || !DEPLOYMENT_RE.test(b.deployment_id)) return bad("deployment_id");
      if (!OUTCOMES.has(b.outcome)) return bad("outcome");
      if (!okCount(b.routes)) return bad("routes");
      if (!okCount(b.over)) return bad("over");
      return d1Guarded("perf_probe_warm", async () => {
        const res = await env.DB.prepare(SQL.insert)
          .bind(b.project, b.deployment_id, b.outcome, b.routes ?? 0, b.over ?? 0, t).run();
        return json(200, { created: Number(res?.meta?.changes || 0) > 0 ? 1 : 0 });
      });
    },
  ],
];
