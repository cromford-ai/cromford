// onboarding-runner routes — BH-7934.2 (#7949): the hub runner's reads and
// writes on an onboarding run. Tables: worker/jobs/schema.d/*-bh-7934-
// onboarding-runs.sql. Writer and reader: bin/onboard-run.sh (the onboard-run
// hub lane). Both routes sit behind the main bearer; no coord-writes row
// names them, so the console cannot send a beat.
// test/route-table.d/bh-7934-onboarding-runner.txt pins this route list.
//
// GET /api/onboarding/runs?state=<s>&limit=<n> | ?project=<p>&limit=<n>
//   Exactly one filter, else 400 filter_required. limit is an integer in
//   1..onboarding.list_limit_max (settings row, fallback LIST_MAX_DEF), 1 when
//   absent. By state: oldest update first (the runner's queued poll and stale
//   check). By project: newest first. 200 {runs:[...]}, run columns only: the
//   runner reads the inputs from GET /api/onboarding/runs/:id.
//
// POST /api/onboarding/runs/:id/beat
//   {claim:true}: queued -> running in one conditional UPDATE. 200
//   {id, state:"running", claimed:true}; 404 not_found; 409 cancelled or
//   not_queued (a second runner lost the claim).
//   {station, state, log_excerpt?, error_code?}: one step moves. running from
//   queued or running; done and failed from running. A done step is never
//   re-opened (a retry starts at the failed station). failed sets the run
//   failed and every later queued step skipped; done of `ready` sets the run
//   done. log_excerpt keeps its LAST onboarding.log_excerpt_max_bytes bytes
//   (fallback EXCERPT_MAX_DEF), cut on a UTF-8 character boundary. error_code
//   only with failed, default station_failed.
//   Every write is guarded by "the run is running" inside ONE batch, and the
//   run write is last, so a cancel that lands between the read and the write
//   wins: the batch changes nothing and the answer is 409.
//   200 {id, run_state, station, step_state}; 400 invalid_field / unknown_station;
//   404 not_found; 409 cancelled / not_running / bad_transition.
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";
import { ONBOARDING_STATIONS } from "./onboarding.js";
import { intSetting } from "./retention.js";

// Fallbacks for the settings rows of the same name
// (schema.d/*-bh-7949-onboarding-runner-settings.sql).
const LIST_MAX_DEF = 20;       // onboarding.list_limit_max
const EXCERPT_MAX_DEF = 4096;  // onboarding.log_excerpt_max_bytes

const RUN_STATES = ["queued", "running", "failed", "done", "cancelled"];
const STEP_STATES = ["running", "done", "failed"];
const STATIONS = [...ONBOARDING_STATIONS, "tracker"];
const PROJECT_RE = /^[a-z0-9][a-z0-9-]{0,39}$/;
const CODE_RE = /^[a-z0-9_]{1,40}$/;
// A step may move to the key from the states it lists.
const FROM = { running: ["queued", "running"], done: ["running"], failed: ["running"] };

const COLS = "id, project, repo, state, station, created_at, updated_at, finished_at";
export const LIST_BY_STATE_SQL = `SELECT ${COLS} FROM onboarding_runs WHERE state = ?1 ORDER BY updated_at LIMIT ?2`;
export const LIST_BY_PROJECT_SQL = `SELECT ${COLS} FROM onboarding_runs WHERE project = ?1 ORDER BY created_at DESC LIMIT ?2`;
const RUNNING = "EXISTS (SELECT 1 FROM onboarding_runs WHERE id = ?1 AND state = 'running')";
export const RUN_SKIP_SQL =
  `UPDATE onboarding_steps SET state = 'skipped' WHERE run_id = ?1 AND ord > ?2 AND state = 'queued' AND ${RUNNING}`;

// The last `max` bytes of `s`, starting on a character boundary.
export function tailBytes(s, max) {
  const enc = new TextEncoder().encode(s);
  if (enc.length <= max) return s;
  let start = enc.length - max;
  while (start < enc.length && (enc[start] & 0xc0) === 0x80) start++;
  return new TextDecoder().decode(enc.subarray(start));
}

const bad = (field) => json(400, { error: "invalid_field", field });
const guarded = (fn) => (ctx) =>
  d1Guarded("onboarding_runs", async () => {
    await ensureTable(ctx.env, "onboarding_runs");
    await ensureTable(ctx.env, "onboarding_steps");
    return fn(ctx);
  });

async function claim(env, id, t) {
  const [upd, back] = await env.DB.batch([
    env.DB.prepare("UPDATE onboarding_runs SET state = 'running', updated_at = ?2 WHERE id = ?1 AND state = 'queued'").bind(id, t),
    env.DB.prepare("SELECT state FROM onboarding_runs WHERE id = ?1").bind(id),
  ]);
  if (Number((upd && upd.meta && upd.meta.changes) || 0) === 1) return json(200, { id, state: "running", claimed: true });
  const row = back && back.results && back.results[0];
  if (!row) return json(404, { error: "not_found" });
  return json(409, { error: row.state === "cancelled" ? "cancelled" : "not_queued", state: row.state });
}

// 409 for a run that is not running, null when it is.
function notRunning(r) {
  if (!r) return json(404, { error: "not_found" });
  if (r.state === "cancelled") return json(409, { error: "cancelled" });
  if (r.state !== "running") return json(409, { error: "not_running", state: r.state });
  return null;
}

async function stepBeat(env, id, body, t) {
  const { station, state } = body;
  if (typeof station !== "string" || !STATIONS.includes(station)) return bad("station");
  if (!STEP_STATES.includes(state)) return bad("state");
  const hasCode = body.error_code !== undefined && body.error_code !== null;
  if (hasCode && (state !== "failed" || typeof body.error_code !== "string" || !CODE_RE.test(body.error_code))) return bad("error_code");
  const hasLog = body.log_excerpt !== undefined && body.log_excerpt !== null;
  if (hasLog && typeof body.log_excerpt !== "string") return bad("log_excerpt");

  const [runs, steps] = await env.DB.batch([
    env.DB.prepare("SELECT id, state FROM onboarding_runs WHERE id = ?1").bind(id),
    env.DB.prepare("SELECT state, ord FROM onboarding_steps WHERE run_id = ?1 AND station = ?2").bind(id, station),
  ]);
  const refused = notRunning(runs && runs.results && runs.results[0]);
  if (refused) return refused;
  const s = steps && steps.results && steps.results[0];
  if (!s) return json(400, { error: "unknown_station", station });
  if (!FROM[state].includes(s.state)) return json(409, { error: "bad_transition", from: s.state, to: state });

  let excerpt = null;
  if (hasLog) {
    const { byKey } = await settingsRows(env);
    excerpt = tailBytes(body.log_excerpt, intSetting(byKey, "onboarding.log_excerpt_max_bytes", EXCERPT_MAX_DEF, 1, 65536));
  }
  const stmts = [];
  // ?1 run id, ?2 station, ?3 now, then the state's own binds.
  if (state === "running") {
    // sql-ident-ok: RUNNING is a literal EXISTS clause defined in this file with ?1 binds
    stmts.push(env.DB.prepare(
      `UPDATE onboarding_steps SET state = 'running', started_at = ?3, finished_at = NULL, error_code = NULL
       WHERE run_id = ?1 AND station = ?2 AND state IN ('queued','running') AND ${RUNNING}`
    ).bind(id, station, t));
  } else {
    // sql-ident-ok: RUNNING is a literal EXISTS clause defined in this file with ?1 binds
    stmts.push(env.DB.prepare(
      `UPDATE onboarding_steps SET state = ?4, finished_at = ?3, log_excerpt = ?5, error_code = ?6
       WHERE run_id = ?1 AND station = ?2 AND state = 'running' AND ${RUNNING}`
    ).bind(id, station, t, state, excerpt, state === "failed" ? (hasCode ? body.error_code : "station_failed") : null));
  }
  if (state === "failed") stmts.push(env.DB.prepare(RUN_SKIP_SQL).bind(id, s.ord));
  const runState = state === "failed" ? "failed" : state === "done" && station === "ready" ? "done" : "running";
  stmts.push(env.DB.prepare(
    `UPDATE onboarding_runs SET station = ?2, updated_at = ?3, state = ?4,
       finished_at = CASE WHEN ?4 IN ('failed','done') THEN ?3 ELSE finished_at END
     WHERE id = ?1 AND state = 'running'`
  ).bind(id, station, t, runState));
  const res = await env.DB.batch(stmts);
  const last = res[res.length - 1];
  if (Number((last && last.meta && last.meta.changes) || 0) !== 1) {
    // A cancel (or another writer) won between the read and the write; the
    // same guard kept every statement of the batch from writing.
    const r = await env.DB.prepare("SELECT id, state FROM onboarding_runs WHERE id = ?1").bind(id).first();
    return notRunning(r) || json(409, { error: "not_running" });
  }
  return json(200, { id, run_state: runState, station, step_state: state });
}

export const routes = [
  [
    "GET", "/api/onboarding/runs",
    guarded(async ({ env, url }) => {
      const q = url.searchParams;
      const state = q.get("state");
      const project = q.get("project");
      if ((state === null) === (project === null)) return json(400, { error: "filter_required" });
      if (state !== null && !RUN_STATES.includes(state)) return bad("state");
      if (project !== null && !PROJECT_RE.test(project)) return bad("project");
      const { byKey } = await settingsRows(env);
      const max = intSetting(byKey, "onboarding.list_limit_max", LIST_MAX_DEF, 1, 1000);
      const raw = q.get("limit");
      const limit = raw === null ? 1 : /^\d+$/.test(raw) ? Number(raw) : NaN;
      if (!(limit >= 1 && limit <= max)) return bad("limit");
      const sql = state !== null ? LIST_BY_STATE_SQL : LIST_BY_PROJECT_SQL;
      const res = await env.DB.prepare(sql).bind(state !== null ? state : project, limit).all();
      return json(200, { runs: res.results || [] });
    }),
  ],
  [
    "POST", /^\/api\/onboarding\/runs\/(ob_[0-9a-f]{20})\/beat$/,
    guarded(async ({ env, t, body, m }) => {
      if (!body || typeof body !== "object" || Array.isArray(body)) return json(400, { error: "invalid_body" });
      if ("claim" in body) return body.claim === true ? claim(env, m[1], t) : bad("claim");
      return stepBeat(env, m[1], body, t);
    }),
  ],
];
