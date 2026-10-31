// pm routes — BH-7260 (BH-7244.2): the PM flesh-out ledger. Table:
// worker/jobs/schema.d/*-bh-7260-pm-runs.sql. Writer: bin/pm-flesh.sh (claim,
// result). Reader: bin/pm-flesh.sh, and the console's idea page
// (/roadmap/<p>/idea/<id>, the PM FLESH-OUT section) through the coord proxy,
// which forwards the GET only. test/route-table.d/bh-7260-pm.txt pins this
// route list.
//
// Every statement binds `project`. No route here calls fetch, or writes an
// idea, a ticket or a job.
//
// POST /api/pm/claim {project, idea_id, input_hash, model?, force?}
//   Every field is checked first (400 {error, field}). ONE batch: INSERT ...
//   ON CONFLICT (project, idea_id, input_hash) DO NOTHING, then the row.
//   claimed:true only when this call made the row. With force, a `claimed` or
//   `failed` row is claimed again (one CAS on status). An `answered` or `done`
//   row never is. 200 {run, claimed, already: !claimed}. The run carries
//   `result`, so an answered or done claim answers the stored flesh-out.
// POST /api/pm/result {project, id, status: answered|done|failed, result?, result_ref?, draft?, prd?, cost_usd?, error?}
//   Every field is checked first. answered needs `result`. A result over
//   pm.flesh_result_max_chars is 413, a prd over pm.flesh_prd_max_chars too.
//   prd is the drafted PRD; with no prd the stored one stays. error is cut to pm.error_max_chars.
//   The allowed moves are claimed -> answered, claimed -> failed,
//   answered -> done and answered -> failed. done with no `result` keeps the
//   stored one. ONE batch: the UPDATE (only from an allowed state), then the
//   row. 200 {run}, 404 no row in this project, 409 {run} another state.
// GET /api/pm/runs?project=&idea_id=
//   The newest pm.runs_shown runs (default 50), with no `result` column.
//   Without idea_id: ONE statement over the project. With idea_id: ONE batch
//   of 2, the idea's runs and `latest`, its newest answered or done run WITH
//   `result` and `prd`. 200 {project, runs, latest|null, as_of}.
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable, laneName } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";
import { intSetting } from "./retention.js";

// Format bounds, not knobs (BH-7945): the longest idea id (roadmap-ideas.js
// ID_MAX), run id, model id and link a well-formed request can carry.
const IDEA_ID_MAX = 80;
const RUN_ID_MAX = 120;
const MODEL_MAX = 200;
const REF_MAX = 500;
const HASH_RE = /^[0-9a-f]{64}$/;
const REF_RE = /^https?:\/\/\S+$/;
// status -> the states it may move from (POST /api/pm/result).
export const RESULT_FROM = { answered: ["claimed"], done: ["answered"], failed: ["claimed", "answered"] };
export const RESULT_STATUSES = Object.keys(RESULT_FROM);
export const DRAFTS = ["ok", "skipped", "failed", "unknown"];
// Knobs (BH-7945): each a settings row, key -> [lo, hi, fallback]. The literals
// are only the fallbacks for a missing or out-of-range row.
export const PM_RUN_LIMITS = {
  "pm.runs_shown": [1, 200, 50],                     // runs GET lists
  "pm.flesh_result_max_chars": [1024, 262144, 32768], // one result (bin/pm-flesh.sh reads the same row)
  "pm.flesh_prd_max_chars": [1024, 262144, 131072],   // one drafted PRD (bin/pm-flesh.sh reads the same row)
  "pm.error_max_chars": [1, 2000, 500],              // the error text of a failed run (BH-7261 row)
};
async function limits(env) {
  const { byKey } = await settingsRows(env);
  return Object.fromEntries(Object.entries(PM_RUN_LIMITS).map(([k, [lo, hi, def]]) => [k, intSetting(byKey, k, def, lo, hi)]));
}

const LIST_COLS = "id, project, idea_id, input_hash, status, model, result_ref, draft, cost_usd, error, created_at, updated_at";
const FULL_COLS = `${LIST_COLS}, result, prd`;
// The SQL texts are exported so the EXPLAIN test reads the exact text. rowid
// breaks a created_at tie inside the same index (no sort pass).
// sql-ident-ok: FULL_COLS is a module constant
export const KEY_ROW_SQL = `SELECT ${FULL_COLS} FROM pm_runs WHERE project = ?1 AND idea_id = ?2 AND input_hash = ?3`;
// sql-ident-ok: FULL_COLS is a module constant
export const ROW_SQL = `SELECT ${FULL_COLS} FROM pm_runs WHERE id = ?1 AND project = ?2`;
// Binds: ?1 id, ?2 project, ?3 idea_id, ?4 input_hash, ?5 model, ?6 t.
export const CLAIM_SQL = `INSERT INTO pm_runs (id, project, idea_id, input_hash, status, model, created_at, updated_at)
  VALUES (?1, ?2, ?3, ?4, 'claimed', ?5, ?6, ?6) ON CONFLICT (project, idea_id, input_hash) DO NOTHING`;
// Binds: ?1 project, ?2 idea_id, ?3 input_hash, ?4 model, ?5 t.
export const FORCE_SQL = `UPDATE pm_runs SET status = 'claimed', model = ?4, error = NULL, updated_at = ?5
  WHERE project = ?1 AND idea_id = ?2 AND input_hash = ?3 AND status IN ('claimed','failed')`;
// Binds: ?1 id, ?2 project, ?3 status, ?4 result (NULL keeps the stored one),
// ?5 result_ref, ?6 draft, ?7 cost_usd, ?8 error, ?9 t, ?10 the JSON array of
// the states this status may move from, ?11 prd (NULL keeps the stored one).
export const RESULT_SQL = `UPDATE pm_runs SET status = ?3, result = COALESCE(?4, result), result_ref = ?5, draft = ?6,
  cost_usd = ?7, error = ?8, updated_at = ?9, prd = COALESCE(?11, prd)
  WHERE id = ?1 AND project = ?2 AND status IN (SELECT value FROM json_each(?10))`;
// sql-ident-ok: LIST_COLS is a module constant
export const LIST_PROJECT_SQL = `SELECT ${LIST_COLS} FROM pm_runs WHERE project = ?1 ORDER BY created_at DESC, rowid DESC LIMIT ?2`;
// sql-ident-ok: LIST_COLS is a module constant
export const LIST_IDEA_SQL = `SELECT ${LIST_COLS} FROM pm_runs WHERE project = ?1 AND idea_id = ?2 ORDER BY created_at DESC, rowid DESC LIMIT ?3`;
// sql-ident-ok: FULL_COLS is a module constant
export const LATEST_SQL = `SELECT ${FULL_COLS} FROM pm_runs WHERE project = ?1 AND idea_id = ?2 AND status IN ('answered','done')
  ORDER BY created_at DESC, rowid DESC LIMIT 1`;

const bad = (field, error) => json(400, { error: `${field} ${error}`, field });
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const absent = (v) => v === undefined || v === null;
const ideaId = (v) => typeof v === "string" && v.length >= 1 && v.length <= IDEA_ID_MAX && !/[\u0000-\u001f\u007f]/.test(v);
const first = (res) => ((res && res.results) || [])[0] || null;

export const routes = [
  [
    "POST", "/api/pm/claim",
    ({ env, t, body }) => d1Guarded("pm_runs", async () => {
      const b = isObj(body) ? body : {};
      const project = typeof b.project === "string" ? laneName(b.project) : "";
      if (!project) return bad("project", "must match ^[A-Za-z0-9._-]{1,64}$");
      if (!ideaId(b.idea_id)) return bad("idea_id", `must be 1..${IDEA_ID_MAX} characters with no control character`);
      if (typeof b.input_hash !== "string" || !HASH_RE.test(b.input_hash)) return bad("input_hash", "must be 64 lowercase hex characters");
      if (!absent(b.model) && (typeof b.model !== "string" || b.model.length > MODEL_MAX)) {
        return bad("model", `must be a string of at most ${MODEL_MAX} characters`);
      }
      const model = absent(b.model) || b.model === "" ? null : b.model;
      const force = b.force === true || b.force === 1 || b.force === "1";
      await ensureTable(env, "pm_runs");
      const key = [project, b.idea_id, b.input_hash];
      const [ins, sel] = await env.DB.batch([
        env.DB.prepare(CLAIM_SQL).bind(crypto.randomUUID(), ...key, model, t),
        env.DB.prepare(KEY_ROW_SQL).bind(...key),
      ]);
      const row = first(sel);
      if (Number(ins.meta.changes) === 1) return json(200, { run: row, claimed: true, already: false });
      if (force && row && (row.status === "claimed" || row.status === "failed")) {
        const [upd, again] = await env.DB.batch([
          env.DB.prepare(FORCE_SQL).bind(...key, model, t),
          env.DB.prepare(KEY_ROW_SQL).bind(...key),
        ]);
        const claimed = Number(upd.meta.changes) === 1;
        return json(200, { run: first(again) || row, claimed, already: !claimed });
      }
      return json(200, { run: row, claimed: false, already: true });
    }),
  ],

  [
    "POST", "/api/pm/result",
    ({ env, t, body }) => d1Guarded("pm_runs", async () => {
      const b = isObj(body) ? body : {};
      const project = typeof b.project === "string" ? laneName(b.project) : "";
      if (!project) return bad("project", "must match ^[A-Za-z0-9._-]{1,64}$");
      if (typeof b.id !== "string" || b.id.length < 1 || b.id.length > RUN_ID_MAX) return bad("id", `must be 1..${RUN_ID_MAX} characters`);
      if (!RESULT_STATUSES.includes(b.status)) return bad("status", `must be one of ${RESULT_STATUSES.join("|")}`);
      if (!absent(b.result) && typeof b.result !== "string") return bad("result", "must be a string");
      const result = absent(b.result) || b.result === "" ? null : b.result;
      if (b.status === "answered" && result === null) return bad("result", "is required when status is answered");
      if (!absent(b.result_ref) && b.result_ref !== "" && (typeof b.result_ref !== "string" || b.result_ref.length > REF_MAX || !REF_RE.test(b.result_ref))) {
        return bad("result_ref", `must be an http(s) URL of at most ${REF_MAX} characters with no spaces`);
      }
      const ref = absent(b.result_ref) || b.result_ref === "" ? null : b.result_ref;
      if (!absent(b.draft) && !DRAFTS.includes(b.draft)) return bad("draft", `must be one of ${DRAFTS.join("|")}`);
      const draft = absent(b.draft) ? null : b.draft;
      if (!absent(b.prd) && typeof b.prd !== "string") return bad("prd", "must be a string");
      const prd = absent(b.prd) || b.prd === "" ? null : b.prd;
      if (!absent(b.cost_usd) && (typeof b.cost_usd !== "number" || !Number.isFinite(b.cost_usd) || b.cost_usd < 0)) {
        return bad("cost_usd", "must be a finite number of 0 or more");
      }
      const cost = absent(b.cost_usd) ? null : b.cost_usd;
      if (!absent(b.error) && typeof b.error !== "string") return bad("error", "must be a string");
      const lim = await limits(env);
      const max = lim["pm.flesh_result_max_chars"];
      if (result !== null && result.length > max) {
        return json(413, { error: `result must be at most ${max} characters (pm.flesh_result_max_chars)`, field: "result" });
      }
      const pmax = lim["pm.flesh_prd_max_chars"];
      if (prd !== null && prd.length > pmax) {
        return json(413, { error: `prd must be at most ${pmax} characters (pm.flesh_prd_max_chars)`, field: "prd" });
      }
      const error = absent(b.error) || b.error === "" ? null : b.error.slice(0, lim["pm.error_max_chars"]);
      await ensureTable(env, "pm_runs");
      const [upd, sel] = await env.DB.batch([
        env.DB.prepare(RESULT_SQL).bind(b.id, project, b.status, result, ref, draft, cost, error, t, JSON.stringify(RESULT_FROM[b.status]), prd),
        env.DB.prepare(ROW_SQL).bind(b.id, project),
      ]);
      const row = first(sel);
      if (!row) return json(404, { error: "run not found" });
      if (Number(upd.meta.changes) === 1) return json(200, { run: row });
      return json(409, { error: `run is ${row.status}; ${b.status} needs ${RESULT_FROM[b.status].join(" or ")}`, run: row });
    }),
  ],

  [
    "GET", "/api/pm/runs",
    ({ env, url, t }) => d1Guarded("pm_runs", async () => {
      const q = url.searchParams;
      const project = laneName(q.get("project"));
      if (!project) return bad("project", "is required and must match ^[A-Za-z0-9._-]{1,64}$");
      const idea = q.get("idea_id");
      if (idea !== null && !ideaId(idea)) return bad("idea_id", `must be 1..${IDEA_ID_MAX} characters with no control character`);
      const [lim] = await Promise.all([limits(env), ensureTable(env, "pm_runs")]);
      const n = lim["pm.runs_shown"];
      if (idea === null) {
        const res = await env.DB.prepare(LIST_PROJECT_SQL).bind(project, n).all();
        return json(200, { project, runs: res.results || [], latest: null, as_of: t });
      }
      const [list, latest] = await env.DB.batch([
        env.DB.prepare(LIST_IDEA_SQL).bind(project, idea, n),
        env.DB.prepare(LATEST_SQL).bind(project, idea),
      ]);
      return json(200, { project, idea_id: idea, runs: list.results || [], latest: first(latest), as_of: t });
    }),
  ],
];
