// pm-brief routes — BH-7261 (BH-7244.3): the PM agent's weekly grooming brief.
// Tables: worker/jobs/schema.d/*-bh-7261-pm-briefs.sql. Writer: bin/pm-groom.sh
// (claim, create, fail, sent). Reader: the console's /roadmap/<p>?view=brief
// (GET, and decide through the coord proxy, which stamps the actor).
// test/route-table.d/bh-7261-pm-brief.txt pins this route list.
//
// Every statement binds `project`. No route here calls fetch or GitHub, or
// writes roadmap_links, roadmap_waves or jobs: an approve moves an idea's lane
// and nothing else.
//
// POST /api/pm/briefs/claim {project, week, input_fp?, model?, force?}
//   ONE batch: INSERT ... ON CONFLICT(project, week) DO NOTHING, then the row.
//   claimed:true only when this call made the row. With force, a `claimed` or
//   `failed` row is claimed again (a CAS on status); a `ready` row never is.
//   200 {brief, claimed}.
// POST /api/pm/briefs {project, week, body, moves:[{idea_id, from_col, to_col, reason?, evidence}]}
//   Every field is checked first (400 {error, field}). The row must be
//   `claimed` (404 none, 409 otherwise). ONE batch: the UPDATE to `ready`
//   (sent_mc=1 in the same statement), then one INSERT per move that runs only
//   while the brief is ready. 201 {brief, moves}.
// POST /api/pm/briefs/fail {project, week, error}    claimed -> failed.
// POST /api/pm/briefs/sent {project, week, channel:"tg"}   ready -> sent_tg=1.
//   Both: 200 {brief}, 404 no row, 409 the row is in another state.
// GET /api/pm/briefs?project=&week=
//   ONE batch of 3: the brief (that week, or the newest), its moves (with the
//   idea's title and current lane), and the last pm.weeks_shown weeks (default 12). 200 {project, week,
//   brief|null, moves, weeks, as_of}.
// POST /api/pm/moves/decide {project, move_id, decision: approve|reject, actor}
//   The move is read in this project (404 none, 409 {move} when it is not
//   `proposed`). Approve is ONE batch whose writes all test
//   `status = 'proposed'` on the move and `lane = from_col` on the idea: the
//   event (it reads the old lane, so it runs first), the idea update, the move
//   (approved when the event exists, else stale), the brief's decided_at, and
//   the read-back. A D1 batch is one transaction, so a second approve changes
//   nothing. 200 {move, idea, applied}.
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable, laneName } from "../lib/core.js";
import { ensureRoadmapTables, IDEA_LANES } from "./roadmap-ideas.js";

const WEEK_RE = /^\d{4}-W\d{2}$/;
// Format bounds, not knobs (BH-7945): the longest id, input fingerprint, model
// id and actor name a well-formed request can carry. No setting tunes them.
const ID_MAX = 120;
const FP_MAX = 128;
const MODEL_MAX = 200;
const ACTOR_MAX = 120;
// Knobs (BH-7945): settings row pm.moves_max (1..200) caps the moves of one
// brief, pm.weeks_shown (1..104) the weeks GET lists. The literals are only the
// fallbacks for a missing or out-of-range row.
export const MOVES_MAX_DEFAULT = 50;
const WEEKS_SHOWN_DEFAULT = 12;
export const MOVES_MAX_SQL = `SELECT CAST(value AS INTEGER) AS n FROM settings
  WHERE key = 'pm.moves_max' AND CAST(value AS INTEGER) BETWEEN 1 AND 200`;
// The write limits, each a settings row (BH-7945): key -> [lo, hi, fallback].
// bin/pm-groom.sh cuts its reasons with the same pm.reason_max_chars row, so
// the lane and the worker cannot disagree.
export const PM_LIMITS = {
  "pm.reason_max_chars": [1, 2000, 500],   // a move's reason
  "pm.evidence_max": [1, 100, 20],         // evidence ids per move
  "pm.body_max_chars": [1024, 1048576, 65536], // the brief body, as JSON text
  "pm.error_max_chars": [1, 2000, 500],    // the error text of a failed brief
};
// sql-ident-ok: the IN list is built from the PM_LIMITS module constant
export const PM_LIMITS_SQL = `SELECT key, value FROM settings WHERE key IN (${Object.keys(PM_LIMITS).map((k) => `'${k}'`).join(",")})`;
// pmLimits(env) -> { key: n }. A missing row, or one that is not an integer in
// lo..hi, is the fallback.
export async function pmLimits(env) {
  const got = {};
  for (const r of (await env.DB.prepare(PM_LIMITS_SQL).all()).results || []) got[r.key] = r.value;
  const out = {};
  for (const [k, [lo, hi, def]] of Object.entries(PM_LIMITS)) {
    const v = String(got[k] ?? "");
    out[k] = /^\d+$/.test(v) && Number(v) >= lo && Number(v) <= hi ? Number(v) : def;
  }
  return out;
}
export const DECISIONS = ["approve", "reject"];

const BRIEF_COLS = "id, project, week, status, input_fp, model, body, sent_mc, sent_tg, error, created_at, updated_at, decided_at";
// sql-ident-ok: BRIEF_COLS is a module constant
export const BRIEF_WEEK_SQL = `SELECT ${BRIEF_COLS} FROM pm_briefs WHERE project = ?1 AND week = ?2`;
// sql-ident-ok: BRIEF_COLS is a module constant
export const BRIEF_NEWEST_SQL = `SELECT ${BRIEF_COLS} FROM pm_briefs WHERE project = ?1 ORDER BY week DESC LIMIT 1`;
export const WEEKS_SQL = `SELECT id, week, status FROM pm_briefs WHERE project = ?1 ORDER BY week DESC
  LIMIT COALESCE((SELECT CAST(value AS INTEGER) FROM settings
    WHERE key = 'pm.weeks_shown' AND CAST(value AS INTEGER) BETWEEN 1 AND 104), ${WEEKS_SHOWN_DEFAULT})`;
const MOVE_COLS = `m.id, m.brief_id, m.project, m.idea_id, m.from_col, m.to_col, m.status, m.reason, m.evidence,
  m.decided_by, m.decided_at, m.created_at, i.title AS title, i.lane AS idea_lane`;
// The idea join is on its primary key and in the same project.
const MOVES_FROM = "FROM pm_moves m LEFT JOIN roadmap_ideas i ON i.id = m.idea_id AND i.project = m.project";
// sql-ident-ok: MOVE_COLS and MOVES_FROM are module constants
export const MOVES_WEEK_SQL = `SELECT ${MOVE_COLS} ${MOVES_FROM}
  WHERE m.brief_id = (SELECT id FROM pm_briefs WHERE project = ?1 AND week = ?2) AND m.project = ?1 ORDER BY m.id`;
// sql-ident-ok: MOVE_COLS and MOVES_FROM are module constants
export const MOVES_NEWEST_SQL = `SELECT ${MOVE_COLS} ${MOVES_FROM}
  WHERE m.brief_id = (SELECT id FROM pm_briefs WHERE project = ?1 ORDER BY week DESC LIMIT 1) AND m.project = ?1 ORDER BY m.id`;
// sql-ident-ok: MOVE_COLS and MOVES_FROM are module constants
export const MOVE_ROW_SQL = `SELECT ${MOVE_COLS} ${MOVES_FROM} WHERE m.id = ?1 AND m.project = ?2`;
// Binds: ?1 brief id, ?2 project, ?3 t. The brief is decided once no move is left proposed.
export const BRIEF_DECIDED_SQL = `UPDATE pm_briefs SET decided_at = ?3
  WHERE id = ?1 AND project = ?2 AND decided_at IS NULL
    AND NOT EXISTS (SELECT 1 FROM pm_moves WHERE brief_id = ?1 AND status = 'proposed')`;

// The approve batch. Binds: ?1 move id, ?2 project, ?3 idea id, ?4 from_col,
// ?5 to_col, ?6 actor, ?7 t, ?8 event reason (the idea update binds ?1..?7).
// Each write repeats both tests.
const PROPOSED = "EXISTS (SELECT 1 FROM pm_moves WHERE id = ?1 AND project = ?2 AND status = 'proposed')";
export const APPROVE_EVENT_SQL = `INSERT INTO roadmap_idea_events (idea_id, project, kind, from_lane, to_lane, actor, reason, detail, at)
  SELECT id, project, 'moved', lane, ?5, 'pm-brief', ?8, json_object('decided_by', ?6), ?7 FROM roadmap_ideas
  WHERE id = ?3 AND project = ?2 AND lane = ?4 AND ${PROPOSED}`;
export const APPROVE_IDEA_SQL = `UPDATE roadmap_ideas
  SET lane = ?5, version = version + 1, updated_at = ?7,
      discarded_at = CASE WHEN ?5 = 'discarded' THEN ?7 ELSE NULL END
  WHERE id = ?3 AND project = ?2 AND lane = ?4 AND ${PROPOSED}`;
export const APPROVE_MOVE_SQL = `UPDATE pm_moves
  SET status = CASE WHEN EXISTS (SELECT 1 FROM roadmap_idea_events
        WHERE idea_id = ?3 AND project = ?2 AND kind = 'moved' AND actor = 'pm-brief' AND reason = ?8 AND at = ?7)
      THEN 'approved' ELSE 'stale' END,
      decided_by = ?6, decided_at = ?7
  WHERE id = ?1 AND project = ?2 AND status = 'proposed'`;
// Binds: ?1 move id, ?2 project, ?3 actor, ?4 t.
export const REJECT_MOVE_SQL = `UPDATE pm_moves SET status = 'rejected', decided_by = ?3, decided_at = ?4
  WHERE id = ?1 AND project = ?2 AND status = 'proposed'`;

const ensurePmTables = (env) => Promise.all([ensureTable(env, "pm_briefs"), ensureTable(env, "pm_moves"), ensureRoadmapTables(env)]);
const bad = (field, error) => json(400, { error: `${field} ${error}`, field });
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const str = (v, max) => typeof v === "string" && v.length >= 1 && v.length <= max;
const optStr = (v, max) => v === undefined || v === null || (typeof v === "string" && v.length <= max);

function parseJson(text, fallback) {
  if (typeof text !== "string") return fallback;
  try { return JSON.parse(text); } catch { return fallback; }
}
const briefOut = (r) => (r ? { ...r, body: parseJson(r.body, null) } : null);
const moveOut = (r) => (r ? { ...r, evidence: parseJson(r.evidence, []) } : null);

// The project and week every brief write carries -> { p, w } or a 400 answer.
function projectWeek(b) {
  const p = typeof b.project === "string" ? laneName(b.project) : "";
  if (!p) return { res: bad("project", "must match ^[A-Za-z0-9._-]{1,64}$") };
  if (typeof b.week !== "string" || !WEEK_RE.test(b.week)) return { res: bad("week", "must be an ISO week like 2026-W43") };
  return { p, w: b.week };
}

// validateMoves(raw, max) -> { moves } or { error }. It never trims or clamps.
// max is the pm.moves_max knob (MOVES_MAX_SQL); lim is pmLimits() (the fallbacks when absent).
export function validateMoves(raw, max = MOVES_MAX_DEFAULT, lim = {}) {
  const REASON_MAX = lim["pm.reason_max_chars"] ?? PM_LIMITS["pm.reason_max_chars"][2];
  const EVIDENCE_MAX = lim["pm.evidence_max"] ?? PM_LIMITS["pm.evidence_max"][2];
  if (!Array.isArray(raw)) return { error: "must be an array" };
  if (raw.length > max) return { error: `holds at most ${max} moves` };
  const moves = [];
  for (const [i, m] of raw.entries()) {
    const at = `[${i}]`;
    if (!isObj(m)) return { error: `${at} must be an object` };
    if (!str(m.idea_id, ID_MAX)) return { error: `${at}.idea_id must be 1..${ID_MAX} characters` };
    if (!IDEA_LANES.includes(m.from_col) || !IDEA_LANES.includes(m.to_col)) {
      return { error: `${at} from_col and to_col must be one of ${IDEA_LANES.join("|")}` };
    }
    if (m.from_col === m.to_col) return { error: `${at} from_col and to_col must differ` };
    if (!optStr(m.reason, REASON_MAX)) return { error: `${at}.reason must be a string of at most ${REASON_MAX} characters` };
    const ev = m.evidence;
    if (!Array.isArray(ev) || ev.length < 1 || ev.length > EVIDENCE_MAX || !ev.every((x) => str(x, ID_MAX))) {
      return { error: `${at}.evidence must be 1..${EVIDENCE_MAX} evidence id strings` };
    }
    moves.push({ idea_id: m.idea_id, from_col: m.from_col, to_col: m.to_col, reason: m.reason || null, evidence: ev });
  }
  return { moves };
}

// A brief status write: claimed -> failed, or ready -> sent_tg = 1.
async function statusWrite(env, t, body, { from, set, binds }) {
  const pw = projectWeek(isObj(body) ? body : {});
  if (pw.res) return pw.res;
  await ensurePmTables(env);
  const [upd, sel] = await env.DB.batch([
    // sql-ident-ok: `set` is one of two module literals
    env.DB.prepare(`UPDATE pm_briefs SET ${set}, updated_at = ?3 WHERE project = ?1 AND week = ?2 AND status = '${from}'`)
      .bind(pw.p, pw.w, t, ...binds),
    env.DB.prepare(BRIEF_WEEK_SQL).bind(pw.p, pw.w),
  ]);
  const row = (sel.results || [])[0] || null;
  if (!row) return json(404, { error: "brief not found" });
  if (Number(upd.meta.changes) === 1) return json(200, { brief: briefOut(row) });
  return json(409, { error: `brief is ${row.status}, not ${from}`, brief: briefOut(row) });
}

export const routes = [
  [
    "POST", "/api/pm/briefs/claim",
    ({ env, t, body }) => d1Guarded("pm_briefs", async () => {
      const b = isObj(body) ? body : {};
      const pw = projectWeek(b);
      if (pw.res) return pw.res;
      if (!optStr(b.input_fp, FP_MAX)) return bad("input_fp", `must be a string of at most ${FP_MAX} characters`);
      if (!optStr(b.model, MODEL_MAX)) return bad("model", `must be a string of at most ${MODEL_MAX} characters`);
      const force = b.force === true || b.force === 1 || b.force === "1";
      await ensurePmTables(env);
      const id = crypto.randomUUID();
      const [ins, sel] = await env.DB.batch([
        env.DB.prepare(`INSERT INTO pm_briefs (id, project, week, status, input_fp, model, created_at, updated_at)
          VALUES (?1, ?2, ?3, 'claimed', ?4, ?5, ?6, ?6) ON CONFLICT (project, week) DO NOTHING`)
          .bind(id, pw.p, pw.w, b.input_fp || null, b.model || null, t),
        env.DB.prepare(BRIEF_WEEK_SQL).bind(pw.p, pw.w),
      ]);
      let row = (sel.results || [])[0] || null;
      if (Number(ins.meta.changes) === 1) return json(200, { brief: briefOut(row), claimed: true });
      if (force && row && (row.status === "claimed" || row.status === "failed")) {
        const [upd, again] = await env.DB.batch([
          env.DB.prepare(`UPDATE pm_briefs SET status = 'claimed', input_fp = ?3, model = ?4, error = NULL, updated_at = ?5
            WHERE id = ?1 AND project = ?2 AND status IN ('claimed','failed')`)
            .bind(row.id, pw.p, b.input_fp || null, b.model || null, t),
          env.DB.prepare(BRIEF_WEEK_SQL).bind(pw.p, pw.w),
        ]);
        row = (again.results || [])[0] || row;
        return json(200, { brief: briefOut(row), claimed: Number(upd.meta.changes) === 1 });
      }
      return json(200, { brief: briefOut(row), claimed: false });
    }),
  ],

  [
    "POST", "/api/pm/briefs",
    ({ env, t, body }) => d1Guarded("pm_briefs", async () => {
      const b = isObj(body) ? body : {};
      const pw = projectWeek(b);
      if (pw.res) return pw.res;
      if (!isObj(b.body) || typeof b.body.summary !== "string") return bad("body", "must be an object with a summary string");
      const text = JSON.stringify(b.body);
      await ensurePmTables(env);
      const [knob, lim] = await Promise.all([env.DB.prepare(MOVES_MAX_SQL).first(), pmLimits(env)]);
      const BODY_MAX = lim["pm.body_max_chars"];
      if (text.length > BODY_MAX) return bad("body", `must be at most ${BODY_MAX} characters of JSON`);
      const v = validateMoves(b.moves, knob ? Number(knob.n) : MOVES_MAX_DEFAULT, lim);
      if (v.error) return bad("moves", v.error);
      const cur = await env.DB.prepare(BRIEF_WEEK_SQL).bind(pw.p, pw.w).first();
      if (!cur) return json(409, { error: "no claimed brief for this project and week" });
      if (cur.status !== "claimed") return json(409, { error: `brief is ${cur.status}, not claimed`, brief: briefOut(cur) });
      // Move ids are the brief id plus the position, so a replay inserts nothing new.
      const moveId = (i) => `${cur.id}.m${String(i).padStart(2, "0")}`;
      const stmts = [
        env.DB.prepare(`UPDATE pm_briefs SET body = ?3, status = 'ready', sent_mc = 1, error = NULL, updated_at = ?4
          WHERE id = ?1 AND project = ?2 AND status = 'claimed'`).bind(cur.id, pw.p, text, t),
        ...v.moves.map((m, i) => env.DB.prepare(`INSERT INTO pm_moves (id, brief_id, project, idea_id, from_col, to_col, status, reason, evidence, created_at)
          SELECT ?1, id, project, ?3, ?4, ?5, 'proposed', ?6, ?7, ?8 FROM pm_briefs WHERE id = ?2 AND project = ?9 AND status = 'ready'
          ON CONFLICT (id) DO NOTHING`).bind(moveId(i), cur.id, m.idea_id, m.from_col, m.to_col, m.reason, JSON.stringify(m.evidence), t, pw.p)),
        env.DB.prepare(BRIEF_WEEK_SQL).bind(pw.p, pw.w),
        env.DB.prepare(MOVES_WEEK_SQL).bind(pw.p, pw.w),
      ];
      const res = await env.DB.batch(stmts);
      const brief = briefOut((res[res.length - 2].results || [])[0] || null);
      const moves = (res[res.length - 1].results || []).map(moveOut);
      if (Number(res[0].meta.changes) === 1) return json(201, { brief, moves });
      return json(409, { error: `brief is ${brief ? brief.status : "gone"}, not claimed`, brief });
    }),
  ],

  [
    "POST", "/api/pm/briefs/fail",
    ({ env, t, body }) => d1Guarded("pm_briefs", async () => {
      const e = isObj(body) ? body.error : undefined;
      const ERROR_MAX = (await pmLimits(env))["pm.error_max_chars"];
      if (!str(e, ERROR_MAX)) return bad("error", `must be 1..${ERROR_MAX} characters`);
      return statusWrite(env, t, body, { from: "claimed", set: "status = 'failed', error = ?4", binds: [e] });
    }),
  ],

  [
    "POST", "/api/pm/briefs/sent",
    ({ env, t, body }) => {
      if (!isObj(body) || body.channel !== "tg") return bad("channel", "must be tg");
      return d1Guarded("pm_briefs", () => statusWrite(env, t, body, { from: "ready", set: "sent_tg = 1", binds: [] }));
    },
  ],

  [
    "GET", "/api/pm/briefs",
    ({ env, url, t }) => d1Guarded("pm_briefs", async () => {
      const q = url.searchParams;
      const project = laneName(q.get("project"));
      if (!project) return bad("project", "is required and must match ^[A-Za-z0-9._-]{1,64}$");
      const week = q.get("week");
      if (week !== null && !WEEK_RE.test(week)) return bad("week", "must be an ISO week like 2026-W43");
      await ensurePmTables(env);
      const [briefRes, movesRes, weeksRes] = await env.DB.batch(week === null
        ? [env.DB.prepare(BRIEF_NEWEST_SQL).bind(project), env.DB.prepare(MOVES_NEWEST_SQL).bind(project), env.DB.prepare(WEEKS_SQL).bind(project)]
        : [env.DB.prepare(BRIEF_WEEK_SQL).bind(project, week), env.DB.prepare(MOVES_WEEK_SQL).bind(project, week), env.DB.prepare(WEEKS_SQL).bind(project)]);
      const brief = briefOut((briefRes.results || [])[0] || null);
      return json(200, {
        project,
        week: week !== null ? week : brief ? brief.week : null,
        brief,
        moves: (movesRes.results || []).map(moveOut),
        weeks: weeksRes.results || [],
        as_of: t,
      });
    }),
  ],

  [
    "POST", "/api/pm/moves/decide",
    ({ env, t, body }) => d1Guarded("pm_moves", async () => {
      const b = isObj(body) ? body : {};
      const project = typeof b.project === "string" ? laneName(b.project) : "";
      if (!project) return bad("project", "must match ^[A-Za-z0-9._-]{1,64}$");
      if (!str(b.move_id, ID_MAX * 2)) return bad("move_id", `must be 1..${ID_MAX * 2} characters`);
      if (!DECISIONS.includes(b.decision)) return bad("decision", `must be one of ${DECISIONS.join("|")}`);
      const actor = typeof b.actor === "string" ? b.actor.trim() : "";
      if (actor.length < 1 || actor.length > ACTOR_MAX) return bad("actor", `must be 1..${ACTOR_MAX} characters`);
      await ensurePmTables(env);
      const move = await env.DB.prepare(MOVE_ROW_SQL).bind(b.move_id, project).first();
      if (!move) return json(404, { error: "move not found" });
      if (move.status !== "proposed") return json(409, { error: "move already decided", move: moveOut(move) });

      const ideaSel = env.DB.prepare("SELECT * FROM roadmap_ideas WHERE id = ?1 AND project = ?2").bind(move.idea_id, project);
      let res;
      if (b.decision === "reject") {
        res = await env.DB.batch([
          env.DB.prepare(REJECT_MOVE_SQL).bind(move.id, project, actor, t),
          env.DB.prepare(BRIEF_DECIDED_SQL).bind(move.brief_id, project, t),
          env.DB.prepare(MOVE_ROW_SQL).bind(move.id, project),
          ideaSel,
        ]);
      } else {
        const reason = `pm-brief move ${move.id}`;
        const a = [move.id, project, move.idea_id, move.from_col, move.to_col, actor, t, reason];
        res = await env.DB.batch([
          env.DB.prepare(APPROVE_EVENT_SQL).bind(...a),
          env.DB.prepare(APPROVE_IDEA_SQL).bind(...a.slice(0, 7)),
          env.DB.prepare(APPROVE_MOVE_SQL).bind(...a),
          env.DB.prepare(BRIEF_DECIDED_SQL).bind(move.brief_id, project, t),
          env.DB.prepare(MOVE_ROW_SQL).bind(move.id, project),
          ideaSel,
        ]);
      }
      const after = moveOut((res[res.length - 2].results || [])[0] || null);
      const idea = (res[res.length - 1].results || [])[0] || null;
      const moveWrite = res[b.decision === "reject" ? 0 : 2];
      // Another decision won between the read and the batch.
      if (Number(moveWrite.meta.changes) !== 1) return json(409, { error: "move already decided", move: after });
      return json(200, { move: after, idea, applied: after.status === "approved" });
    }),
  ],
];
