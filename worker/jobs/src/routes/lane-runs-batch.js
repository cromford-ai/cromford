// lane-runs-batch route — many lane_runs rows in ONE statement (BH-6886).
//
// pl_dispatch (bin/lib/project-lanes.sh) enqueues a lane placed `fly` for
// every eligible project. One POST /api/lane-runs per project cost the hub one
// HTTP call and two jq forks per project per tick; lp_enqueue_batch
// (bin/lib/lane-placement.sh) sends this route one call per 500 projects.
//
//   POST /api/lane-runs/batch {lane, box?, rows: [{project, args}]}  1..500 rows
//   200 {lane, as_of, enqueued, already_live,
//        rows: [{project, status: "enqueued", id} | {project, status: "already_live"}]}
//
// The answer lists the rows in input order. A row conflicts only with a LIVE
// row (queued or claimed) of the same (lane, project): the partial unique index
// lane_runs_live (schema.d/0020) is the ON CONFLICT target, so a retried batch
// answers already_live for the rows it already wrote. Every row is validated
// before the statement runs, and one bad row refuses the whole batch with a
// 400 that names its index: nothing is written.
//
// The args rules are the same as POST /api/lane-runs (routes/lane-runs.js).
// They are copied, not imported, so this family does not edit that module.

import { d1Guarded, json } from "../lib/http.js";
import { laneName, str } from "../lib/core.js";

// lp_enqueue_batch's LP_BATCH_MAX is the same number.
export const BATCH_MAX = 500;
// The bound JSON array; D1 caps one bound string at 2 MB.
const BATCH_JSON_BYTES_MAX = 1000000;
const ARGS_MAX = 64;
const ARG_BYTES_MAX = 4096;
const ARGS_JSON_BYTES_MAX = 16384;
const CMD_RE = /^bin\/[A-Za-z0-9._/-]+$/;
const NAME_ERR = "must match [A-Za-z0-9._-]{1,64}";

// Binds: ?1 lane ?2 now ?3 box ?4 JSON array [{p, a}] (a = the args JSON text).
// `WHERE 1` keeps SQLite from reading ON as a join constraint of the SELECT.
// RETURNING lists the inserted rows only; a conflicting row returns nothing.
export const BATCH_SQL = `INSERT INTO lane_runs (lane, project, args_json, enqueued_at, enqueued_by, status)
  SELECT ?1, json_extract(j.value, '$.p'), json_extract(j.value, '$.a'), ?2, ?3, 'queued'
  FROM json_each(?4) AS j WHERE 1
  ON CONFLICT (lane, project) WHERE status IN ('queued','claimed') DO NOTHING
  RETURNING id, project`;

const bytes = (s) => new TextEncoder().encode(s).length;

// { v: <args JSON text> } or { err } — the rules of routes/lane-runs.js argsOf.
function argsOf(v) {
  if (!Array.isArray(v) || v.length < 1 || v.length > ARGS_MAX) {
    return { err: `args must be an array of 1..${ARGS_MAX} strings` };
  }
  if (!v.every((a) => typeof a === "string" && bytes(a) <= ARG_BYTES_MAX)) {
    return { err: `every arg must be a string of at most ${ARG_BYTES_MAX} bytes` };
  }
  if (!CMD_RE.test(v[0]) || v[0].split("/").includes("..")) {
    return { err: "args[0] must be a path under bin/ (^bin/[A-Za-z0-9._/-]+$, no '..')" };
  }
  const s = JSON.stringify(v);
  if (bytes(s) > ARGS_JSON_BYTES_MAX) return { err: `args is over ${ARGS_JSON_BYTES_MAX} bytes as JSON` };
  return { v: s };
}

export const routes = [
  [
    "POST", "/api/lane-runs/batch",
    ({ env, t, body }) => d1Guarded("lane_runs", async () => {
      const lane = laneName(body.lane);
      if (!lane) return json(400, { error: `lane is required and ${NAME_ERR}` });
      const rows = body.rows;
      if (!Array.isArray(rows) || rows.length < 1 || rows.length > BATCH_MAX) {
        return json(400, { error: `rows must be an array of 1..${BATCH_MAX} rows` });
      }
      const items = [];
      const seen = new Set();
      for (let i = 0; i < rows.length; i += 1) {
        const row = rows[i];
        const project = row && typeof row === "object" ? laneName(row.project) : "";
        if (!project) return json(400, { error: `rows[${i}]: project is required and ${NAME_ERR}` });
        if (seen.has(project)) return json(400, { error: `rows[${i}]: duplicate project ${project}` });
        seen.add(project);
        const a = argsOf(row.args);
        if (a.err) return json(400, { error: `rows[${i}]: ${a.err}` });
        items.push({ p: project, a: a.v });
      }
      const payload = JSON.stringify(items);
      if (bytes(payload) > BATCH_JSON_BYTES_MAX) {
        return json(400, { error: `rows are over ${BATCH_JSON_BYTES_MAX} bytes as JSON` });
      }
      const res = await env.DB.prepare(BATCH_SQL).bind(lane, t, str(body.box, 64), payload).all();
      const ids = new Map((res.results || []).map((r) => [r.project, Number(r.id)]));
      const out = items.map(({ p }) => (ids.has(p)
        ? { project: p, status: "enqueued", id: ids.get(p) }
        : { project: p, status: "already_live" }));
      return json(200, {
        lane, as_of: t, enqueued: ids.size, already_live: items.length - ids.size, rows: out,
      });
    }),
  ],
];
