// onboarding actions — BH-7934.3: retry and cancel an onboarding run.
// Tables: worker/jobs/schema.d/202610220114-bh-7934-onboarding-runs.sql (the
// contract, src/routes/onboarding.js). Writer of these two: the console's setup
// line screen through the coord proxy (coord-writes.d/7934-onboarding.js).
// test/route-table.d/bh-7934-onboarding-actions.txt pins this route list.
//
// POST /api/onboarding/runs/:id/retry
//   Only from run state failed. ONE batch: the failed step -> queued
//   (retries+1, error_code NULL), every later skipped/queued step -> queued,
//   then the run -> queued (finished_at NULL). Done steps stay done. The step
//   statements run first, while the run is still failed, so their EXISTS guard
//   holds; when the run is not failed every statement changes 0 rows.
//   200 {id, state:"queued"}; 409 {error:"not_failed", state}; 404 not_found.
//
// POST /api/onboarding/runs/:id/cancel
//   From queued, running or failed. ONE batch: every step that is not done ->
//   skipped, then the run -> cancelled with finished_at.
//   200 {id, state:"cancelled"}; 409 {error:"already_terminal", state}; 404.
//
// GET /api/onboarding/projects/:project/latest
//   The project's newest run, for the link on the console's project page
//   (/p/:project) to this run's setup line. One read, served by
//   idx_onboarding_runs_project_created. 200 {run:{id, state, created_at}} or
//   200 {run:null} when the project has no run.
//
// The `actor` the coord proxy forwards is not stored: no column holds it.
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";

const RUN_FAILED = "EXISTS (SELECT 1 FROM onboarding_runs WHERE id = ?1 AND state = 'failed')";
const RUN_LIVE = "EXISTS (SELECT 1 FROM onboarding_runs WHERE id = ?1 AND state IN ('queued','running','failed'))";

export const RETRY_LATER_SQL =
  "UPDATE onboarding_steps SET state = 'queued' WHERE run_id = ?1 AND state IN ('skipped','queued')" +
  " AND ord > (SELECT ord FROM onboarding_steps WHERE run_id = ?1 AND state = 'failed' ORDER BY ord LIMIT 1)" +
  ` AND ${RUN_FAILED}`;
export const RETRY_FAILED_SQL =
  "UPDATE onboarding_steps SET state = 'queued', retries = retries + 1, error_code = NULL" +
  ` WHERE run_id = ?1 AND state = 'failed' AND ${RUN_FAILED}`;
export const RETRY_RUN_SQL =
  "UPDATE onboarding_runs SET state = 'queued', finished_at = NULL, updated_at = ?2 WHERE id = ?1 AND state = 'failed'";
export const CANCEL_STEPS_SQL =
  `UPDATE onboarding_steps SET state = 'skipped' WHERE run_id = ?1 AND state <> 'done' AND ${RUN_LIVE}`;
export const CANCEL_RUN_SQL =
  "UPDATE onboarding_runs SET state = 'cancelled', finished_at = ?2, updated_at = ?2 WHERE id = ?1 AND state IN ('queued','running','failed')";
export const STATE_SQL = "SELECT state FROM onboarding_runs WHERE id = ?1";
export const LATEST_SQL =
  "SELECT id, state, created_at FROM onboarding_runs WHERE project = ?1 ORDER BY created_at DESC LIMIT 1";

const guarded = (fn) => (ctx) =>
  d1Guarded("onboarding_runs", async () => {
    await ensureTable(ctx.env, "onboarding_runs");
    await ensureTable(ctx.env, "onboarding_steps");
    return fn(ctx);
  });

// The batch's last two answers are the run update and the state read back.
function answer(id, runRes, stateRes, okState, refusal) {
  if (Number((runRes && runRes.meta && runRes.meta.changes) || 0) === 1) return json(200, { id, state: okState });
  const row = stateRes && stateRes.results && stateRes.results[0];
  if (!row) return json(404, { error: "not_found" });
  return json(409, { error: refusal, state: row.state });
}

export const routes = [
  [
    "POST", /^\/api\/onboarding\/runs\/(ob_[0-9a-f]{20})\/retry$/,
    guarded(async ({ env, m, t }) => {
      const id = m[1];
      const res = await env.DB.batch([
        env.DB.prepare(RETRY_LATER_SQL).bind(id),
        env.DB.prepare(RETRY_FAILED_SQL).bind(id),
        env.DB.prepare(RETRY_RUN_SQL).bind(id, t),
        env.DB.prepare(STATE_SQL).bind(id),
      ]);
      return answer(id, res[2], res[3], "queued", "not_failed");
    }),
  ],
  [
    "POST", /^\/api\/onboarding\/runs\/(ob_[0-9a-f]{20})\/cancel$/,
    guarded(async ({ env, m, t }) => {
      const id = m[1];
      const res = await env.DB.batch([
        env.DB.prepare(CANCEL_STEPS_SQL).bind(id),
        env.DB.prepare(CANCEL_RUN_SQL).bind(id, t),
        env.DB.prepare(STATE_SQL).bind(id),
      ]);
      return answer(id, res[1], res[2], "cancelled", "already_terminal");
    }),
  ],
  [
    "GET", /^\/api\/onboarding\/projects\/([a-z0-9][a-z0-9-]{0,39})\/latest$/,
    guarded(async ({ env, m }) => {
      const r = await env.DB.prepare(LATEST_SQL).bind(m[1]).first();
      return json(200, { run: r || null });
    }),
  ],
];
