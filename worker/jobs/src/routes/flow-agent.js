// flow-agent routes — BH-9924 (slice BH-9956): the D1 half of bin/flow-agent.sh.
//
//   POST /api/flow-agent/claim    {decision_key, project, ticket_key, code, action, episode, outcome?, before?, box?}
//   POST /api/flow-agent/record   {decision_key, outcome, after?, detail?}
//   GET  /api/flow-agent/count    ?project=&ticket=
//   PUT  /api/flow-agent/waiting  {project, rows:[{key, code, since, episode, evidence}]}
//
// Every route is behind the HARNESS_SECRET bearer (a gated family, registered
// by test/route-table.d/bh-9924-flow-agent.txt, never by an edit to index.js).
//
// CLAIM is the one dedup store: INSERT ... ON CONFLICT(decision_key) DO
// NOTHING. One change is 200 {claimed:true, id}. No change reads the row once
// and answers 409 {error:'duplicate', outcome}. The lane claims BEFORE every
// arm, so a second pass on the same decision never runs the arm again.
// RECORD is a CAS on outcome='claimed': 1 change is 200; an existing row in any
// other outcome is 409 {error:'not-claimed', outcome}; no row is 404.
// COUNT counts the done, failed and escalated rows of one ticket inside the
// window (settings row flow_agent.count_window_h).
// WAITING is one env.DB.batch of 2 statements (3 + 2 binds, json_each): upsert the rows,
// then delete the rows of THIS project that are not in the set. An empty set
// is a real empty set. `since` is kept while the code stays the same.
//
// Indexes (schema.d/202611242152-bh-9924-flow-agent.sql):
//   CLAIM_SQL, CLAIM_READ_SQL, RECORD_SQL  sqlite_autoindex_flow_actions_1 (decision_key)
//   COUNT_SQL                              idx_flow_actions_ticket_created
//   WAITING_UPSERT_SQL, WAITING_DELETE_SQL flow_waiting PK (project, ticket_key)
//
// Answers: 400 {error, field} on a bad input, before any statement; a D1
// failure is the d1Guarded 503 that names the table, never an empty 200.
// The panel routes are a separate family (flow-agent-panel.js, BH-9924.10).
import { json, d1Guarded } from "../lib/http.js";
import { settingsRows } from "../lib/settings-cache.js";

export const COUNT_WINDOW_H_DEFAULT = 24;   // settings row flow_agent.count_window_h
export const WAITING_MAX_DEFAULT = 500;     // settings row flow_agent.waiting_max
export const EVIDENCE_MAX_DEFAULT = 2000;   // settings row flow_agent.evidence_max_chars
                                            // (also the cut of before/after/detail text)

// The ordered cause codes (bin/lib/flow-agent/cause.sh FLOW_CODES), plus the
// three words the lane can also write: unknown, inputs_unreadable and held.
export const CODES = new Set([
  "answered_not_retriaged", "ready_not_queued", "row_for_archived_ticket",
  "waits_behind_green_pr", "waits_behind_dead_blocker", "parent_slices_not_filed",
  "dependency_not_done_but_on_staging", "pr_conflict", "pr_red_same_test_as_main",
  "unknown", "inputs_unreadable", "held",
]);
const CLAIM_OUTCOMES = new Set(["claimed", "would"]);
const RECORD_OUTCOMES = new Set(["done", "failed", "refused", "escalated"]);

const PROJECT_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;   // as routes/waiting.js
const KEY_RE = /^[A-Za-z0-9._#-]{1,64}$/;           // as routes/waiting.js
const DKEY_RE = /^[0-9a-f]{64}$/;
const WORD_RE = /^[a-z0-9_:.-]{1,64}$/;
// A format bound, not a knob (like the {0,63} of PROJECT_RE): an episode is an
// ISO time from triage_state or the board, or `none`. A longer one is refused.
const EPISODE_LEN_MAX = 200;

export const CLAIM_SQL =
  `INSERT INTO flow_actions (decision_key, project, ticket_key, code, action, episode, outcome, before_state, box, created_at, updated_at)
   VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10)
   ON CONFLICT(decision_key) DO NOTHING`;
export const CLAIM_READ_SQL = `SELECT id, outcome FROM flow_actions WHERE decision_key = ?1`;
export const RECORD_SQL =
  `UPDATE flow_actions SET outcome = ?2, after_state = ?3, detail = ?4, updated_at = ?5
    WHERE decision_key = ?1 AND outcome = 'claimed'`;
export const COUNT_SQL =
  `SELECT COUNT(*) AS n FROM flow_actions
    WHERE project = ?1 AND ticket_key = ?2 AND created_at >= ?3 AND outcome IN ('done','failed','escalated')`;
export const WAITING_UPSERT_SQL =
  `INSERT INTO flow_waiting (project, ticket_key, cause_code, since, episode, evidence, seen_at)
   SELECT ?1, json_extract(value, '$.key'), json_extract(value, '$.code'), json_extract(value, '$.since'),
          json_extract(value, '$.episode'), json_extract(value, '$.evidence'), ?3
     FROM json_each(?2) WHERE true
   ON CONFLICT(project, ticket_key) DO UPDATE SET
     cause_code = excluded.cause_code, episode = excluded.episode, evidence = excluded.evidence,
     seen_at = excluded.seen_at,
     since = CASE WHEN flow_waiting.cause_code = excluded.cause_code THEN flow_waiting.since ELSE excluded.since END`;
export const WAITING_DELETE_SQL =
  `DELETE FROM flow_waiting WHERE project = ?1
      AND ticket_key NOT IN (SELECT json_extract(value, '$.key') FROM json_each(?2))`;

// A whole-number settings row in [lo, hi], or `def` when absent or junk.
const intSettingOr = (byKey, key, def, lo, hi) => {
  const row = byKey.get(key);
  const v = row ? String(row.value).trim() : "";
  if (!/^\d+$/.test(v)) return def;
  const n = Number(v);
  return n >= lo && n <= hi ? n : def;
};
const bad = (field) => json(400, { error: "bad_request", field });
// Optional text: null when absent, cut to `max` (never refused), undefined when not a string.
const optText = (v, max) => (v === undefined || v === null ? null : typeof v === "string" ? v.slice(0, max) : undefined);
const textMaxOf = async (env) => intSettingOr((await settingsRows(env)).byKey, "flow_agent.evidence_max_chars", EVIDENCE_MAX_DEFAULT, 1, 100000);
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;
const isoMinusH = (iso, h) => new Date(Date.parse(iso) - h * 3600e3).toISOString().replace(/\.\d{3}Z$/, "Z");

// -> {claim} or {field}: the first bad field, named.
export function parseClaim(b, textMax = EVIDENCE_MAX_DEFAULT) {
  if (!b || typeof b !== "object") return { field: "body" };
  if (typeof b.decision_key !== "string" || !DKEY_RE.test(b.decision_key)) return { field: "decision_key" };
  if (typeof b.project !== "string" || !PROJECT_RE.test(b.project)) return { field: "project" };
  if (typeof b.ticket_key !== "string" || !KEY_RE.test(b.ticket_key)) return { field: "ticket_key" };
  if (typeof b.code !== "string" || !CODES.has(b.code)) return { field: "code" };
  if (typeof b.action !== "string" || !WORD_RE.test(b.action)) return { field: "action" };
  if (typeof b.episode !== "string" || b.episode === "" || b.episode.length > EPISODE_LEN_MAX) return { field: "episode" };
  const outcome = b.outcome === undefined ? "claimed" : b.outcome;
  if (!CLAIM_OUTCOMES.has(outcome)) return { field: "outcome" };
  const before = optText(b.before, textMax);
  if (before === undefined) return { field: "before" };
  if (b.box !== undefined && b.box !== null && (typeof b.box !== "string" || !KEY_RE.test(b.box))) return { field: "box" };
  return { claim: { ...b, outcome, before, box: b.box || null } };
}

// -> {rows} or {field}. `max` is flow_agent.waiting_max.
export function parseWaiting(b, max) {
  if (!b || typeof b !== "object") return { field: "body" };
  if (typeof b.project !== "string" || !PROJECT_RE.test(b.project)) return { field: "project" };
  if (!Array.isArray(b.rows)) return { field: "rows" };
  if (b.rows.length > max) return { field: "rows", error: "too_many" };
  const seen = new Set();
  const rows = [];
  for (let i = 0; i < b.rows.length; i++) {
    const r = b.rows[i];
    if (!r || typeof r !== "object") return { field: `rows[${i}]` };
    if (typeof r.key !== "string" || !KEY_RE.test(r.key) || seen.has(r.key)) return { field: `rows[${i}].key` };
    if (typeof r.code !== "string" || !CODES.has(r.code)) return { field: `rows[${i}].code` };
    if (typeof r.since !== "string" || !ISO_RE.test(r.since)) return { field: `rows[${i}].since` };
    if (typeof r.episode !== "string" || r.episode === "" || r.episode.length > EPISODE_LEN_MAX) return { field: `rows[${i}].episode` };
    if (r.evidence !== undefined && r.evidence !== null && typeof r.evidence !== "string") return { field: `rows[${i}].evidence` };
    seen.add(r.key);
    rows.push({ key: r.key, code: r.code, since: r.since, episode: r.episode, evidence: r.evidence ?? null });
  }
  return { project: b.project, rows };
}

export const routes = [
  [
    "POST", "/api/flow-agent/claim",
    async ({ env, t, body }) => {
      const shape = parseClaim(body);
      if (shape.field) return bad(shape.field);
      return d1Guarded("flow_actions", async () => {
        const c = parseClaim(body, await textMaxOf(env)).claim;
        const r = await env.DB.prepare(CLAIM_SQL)
          .bind(c.decision_key, c.project, c.ticket_key, c.code, c.action, c.episode, c.outcome, c.before, c.box, t)
          .run();
        if (((r && r.meta && r.meta.changes) || 0) === 1) {
          return json(200, { claimed: true, id: (r.meta && r.meta.last_row_id) ?? null, outcome: c.outcome });
        }
        const row = await env.DB.prepare(CLAIM_READ_SQL).bind(c.decision_key).first();
        return json(409, { error: "duplicate", outcome: row ? row.outcome : null });
      });
    },
  ],
  [
    "POST", "/api/flow-agent/record",
    async ({ env, t, body }) => {
      const b = body && typeof body === "object" ? body : {};
      if (typeof b.decision_key !== "string" || !DKEY_RE.test(b.decision_key)) return bad("decision_key");
      if (!RECORD_OUTCOMES.has(b.outcome)) return bad("outcome");
      if (optText(b.after, 0) === undefined) return bad("after");
      if (optText(b.detail, 0) === undefined) return bad("detail");
      return d1Guarded("flow_actions", async () => {
        const textMax = await textMaxOf(env);
        const after = optText(b.after, textMax);
        const detail = optText(b.detail, textMax);
        const r = await env.DB.prepare(RECORD_SQL).bind(b.decision_key, b.outcome, after, detail, t).run();
        if (((r && r.meta && r.meta.changes) || 0) === 1) return json(200, { recorded: true, outcome: b.outcome });
        const row = await env.DB.prepare(CLAIM_READ_SQL).bind(b.decision_key).first();
        if (!row) return json(404, { error: "no-claim" });
        return json(409, { error: "not-claimed", outcome: row.outcome });
      });
    },
  ],
  [
    "GET", "/api/flow-agent/count",
    async ({ env, t, url }) => {
      const project = url.searchParams.get("project");
      const ticket = url.searchParams.get("ticket");
      if (typeof project !== "string" || !PROJECT_RE.test(project)) return bad("project");
      if (typeof ticket !== "string" || !KEY_RE.test(ticket)) return bad("ticket");
      return d1Guarded("flow_actions", async () => {
        const { byKey } = await settingsRows(env);
        const windowH = intSettingOr(byKey, "flow_agent.count_window_h", COUNT_WINDOW_H_DEFAULT, 1, 8760);
        const since = isoMinusH(t, windowH);
        const row = await env.DB.prepare(COUNT_SQL).bind(project, ticket, since).first();
        const n = row && Number.isInteger(row.n) ? row.n : null;
        if (n === null) throw new Error("flow_actions count returned no row");
        return json(200, { count: n, window_h: windowH, since, as_of: t });
      });
    },
  ],
  [
    "PUT", "/api/flow-agent/waiting",
    async ({ env, t, body }) => {
      if (!body || typeof body !== "object" || typeof body.project !== "string" || !PROJECT_RE.test(body.project)) return bad("project");
      return d1Guarded("flow_waiting", async () => {
        const { byKey } = await settingsRows(env);
        const max = intSettingOr(byKey, "flow_agent.waiting_max", WAITING_MAX_DEFAULT, 1, 100000);
        const evMax = intSettingOr(byKey, "flow_agent.evidence_max_chars", EVIDENCE_MAX_DEFAULT, 1, 100000);
        const p = parseWaiting(body, max);
        if (p.field) return json(400, { error: p.error || "bad_request", field: p.field });
        const set = JSON.stringify(p.rows.map((r) => ({ ...r, evidence: r.evidence === null ? null : r.evidence.slice(0, evMax) })));
        const [up, del] = await env.DB.batch([
          env.DB.prepare(WAITING_UPSERT_SQL).bind(p.project, set, t),
          env.DB.prepare(WAITING_DELETE_SQL).bind(p.project, set),
        ]);
        const ch = (r) => (r && r.meta && r.meta.changes) || 0;
        return json(200, { upserted: ch(up), deleted: ch(del), rows: p.rows.length, as_of: t });
      });
    },
  ],
];
