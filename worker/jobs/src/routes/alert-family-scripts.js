// alert-family-scripts routes — BH-2575 (BH-2544.3): the operator's read/write
// surface over the alert_family_scripts table (worker/jobs/schema.sql, the
// BH-2568 block), so the family→script mapping changes with no deploy.
//
//   GET /api/alert-family-scripts        every row, enabled and disabled,
//                                        ORDER BY priority, id — uncapped: an
//                                        operator-edited registry of tens of rows,
//                                        and a cap would hide rows from its reader
//   PUT /api/alert-family-scripts/<id>   upsert one row, stamped updated_at + actor
//
// Bearer comes from index.js: both verbs sit in ROUTES, never OPEN_ROUTES.
//
// A WHOLE-ROW PUT, the route-rules convention: a field absent from the body
// takes the schema default, on an update too. The id is the PATH only (a body
// id is ignored) and is never normalised.
//
// 400, NEVER A CLAMP. A later sibling EXECUTES bin/alert-verify/<verify>.sh, so
// `verify` is held to the id class (no dot, slash or shell metacharacter), and
// every field is validated before the DB is touched: an invalid request writes
// nothing. The line_regex gate is `new RegExp` — a syntax gate only; the
// runtime matcher is Python.
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable, strictInt } from "../lib/core.js";
import { ALERT_ACTOR_RE } from "./alerts.js";

export const AFS_ID_RE = /^[a-z0-9-]{1,48}$/;
export const AFS_MATCH_KINDS = ["akey_prefix", "line_regex"];
export const AFS_ON_CLEAR = ["settle", "model"];
export const AFS_ON_REPRO = ["model", "park"];
const MATCH_MAX = 1024;
const NOTE_MAX = 500;
const COLS = "id, match_kind, match, verify, on_clear, on_repro, enabled, priority, note, actor, updated_at";

// The row a PUT would write, or { error } naming the first bad field.
function validate(id, body) {
  if (!AFS_ID_RE.test(id)) return { error: "id must match ^[a-z0-9-]{1,48}$" };
  if (!AFS_MATCH_KINDS.includes(body.match_kind)) return { error: `match_kind must be one of ${AFS_MATCH_KINDS.join(", ")}` };
  const match = body.match;
  if (typeof match !== "string" || match.trim() === "" || match.length > MATCH_MAX) {
    return { error: `match must be a non-empty string of at most ${MATCH_MAX} chars` };
  }
  if (body.match_kind === "line_regex") {
    try { new RegExp(match); } catch (e) {
      return { error: `match is not a valid regex: ${String((e && e.message) || e).slice(0, 120)}` };
    }
  }
  let verify = null;
  if (body.verify !== undefined && body.verify !== null) {
    if (typeof body.verify !== "string" || !AFS_ID_RE.test(body.verify)) {
      return { error: "verify must be null or match ^[a-z0-9-]{1,48}$ (a basename under bin/alert-verify/)" };
    }
    verify = body.verify;
  }
  const onClear = body.on_clear === undefined ? "settle" : body.on_clear;
  if (!AFS_ON_CLEAR.includes(onClear)) return { error: `on_clear must be one of ${AFS_ON_CLEAR.join(", ")}` };
  const onRepro = body.on_repro === undefined ? "model" : body.on_repro;
  if (!AFS_ON_REPRO.includes(onRepro)) return { error: `on_repro must be one of ${AFS_ON_REPRO.join(", ")}` };
  const enabled = body.enabled === undefined ? 1 : strictInt(body.enabled);
  if (enabled !== 0 && enabled !== 1) return { error: "enabled must be 0 or 1" };
  const priority = body.priority === undefined ? 100 : strictInt(body.priority);
  if (priority === null) return { error: "priority must be an integer" };
  let note = null;
  if (body.note !== undefined && body.note !== null) {
    if (typeof body.note !== "string" || body.note.length > NOTE_MAX) return { error: `note must be null or a string of at most ${NOTE_MAX} chars` };
    note = body.note;
  }
  const actor = body.actor;
  if (typeof actor !== "string" || !ALERT_ACTOR_RE.test(actor)) return { error: "actor must match ^[A-Za-z0-9._@-]{1,96}$" };
  return { row: [id, body.match_kind, match, verify, onClear, onRepro, enabled, priority, note, actor] };
}

export const routes = [
  [
    "GET", "/api/alert-family-scripts",
    async ({ env, t }) => d1Guarded("alert_family_scripts", async () => {
      await ensureTable(env, "alert_family_scripts");
      // sql-ident-ok: COLS is a module constant
      const r = await env.DB.prepare(`SELECT ${COLS} FROM alert_family_scripts ORDER BY priority ASC, id ASC`).all();
      return json(200, { rows: r.results || [], as_of: t });
    }),
  ],
  [
    "PUT", /^\/api\/alert-family-scripts\/([^/]+)$/,
    async ({ env, t, body, m }) => {
      let id;
      try { id = decodeURIComponent(m[1]); } catch { return json(400, { error: "id must match ^[a-z0-9-]{1,48}$" }); }
      const v = validate(id, body || {});
      if (v.error) return json(400, { error: v.error });
      return d1Guarded("alert_family_scripts", async () => {
        await ensureTable(env, "alert_family_scripts");
        // sql-ident-ok: COLS is a module constant
        await env.DB.prepare(
          `INSERT INTO alert_family_scripts (${COLS}) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
           ON CONFLICT(id) DO UPDATE SET match_kind=excluded.match_kind, match=excluded.match, verify=excluded.verify,
             on_clear=excluded.on_clear, on_repro=excluded.on_repro, enabled=excluded.enabled, priority=excluded.priority,
             note=excluded.note, actor=excluded.actor, updated_at=excluded.updated_at`
        ).bind(...v.row, t).run();
        // sql-ident-ok: COLS is a module constant
        const row = await env.DB.prepare(`SELECT ${COLS} FROM alert_family_scripts WHERE id=?1`).bind(id).first();
        return json(200, { row, as_of: t });
      });
    },
  ],
];
