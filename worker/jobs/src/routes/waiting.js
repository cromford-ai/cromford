// waiting routes — BH-9116: the D1 half of the console's "To do (waiting)"
// view (KANBAN tab, /p/<project> QUEUES).
//
//   POST /api/waiting/state   {tickets:[{project, key, id?}]}
//
// The console sends the open tickets of the hub's ticket snapshot; this answers
// the raw rows the classifier (console-ui/src/lib/waiting.js) needs to name why
// each one is not in flight. READ-ONLY: no statement here writes.
//
// ONE env.DB.batch of six statements. ?1 is a JSON array of the projects and ?2
// a JSON array of the keys and ids, each bound once and expanded by json_each,
// so the bind count stays at four whatever the ticket count (D1 refuses more
// than 100 binds). Every statement filters on the project, so a row of project
// B never answers for project A, and each is served by an index:
//   S1 triage_state        PK (project, ticket_key)
//   S2 build_queue         PK (project, ticket_key)
//   S3 build_queue         idx_build_queue_status (status, project, enqueued_at)
//   S4 jobs + heartbeats   idx_jobs_project_status / _ticket; job_heartbeats PK
//   S5 jobs                idx_jobs_project_status_created / _ticket_created
//   S6 ticket_edges        idx_ticket_edges_child (project, child)
// No correlated subquery: the json_each lists are constant per statement.
//
// The knobs are settings rows, read through the per-isolate snapshot:
//   waiting.stale_claim_min     (30)    a claim / heartbeat older is stale
//   waiting.max_tickets         (2000)  the most tickets one call reads
//   waiting.defer_lookback_min  (10080) how far back a parked job counts
//   waiting.reason_text_max     (200)   the most characters of a reason text
// More tickets than max_tickets: the first N are read and `truncated: true`.
// S3 reads at most max_tickets + 1 rows, oldest first; one more is
// `positions_truncated`. It orders on enqueued_at alone, not on (project,
// enqueued_at): with the project first the planner takes the primary key and
// reads every row of the project, and the queued rows are a few percent of it.
//
// jobs.meta never leaves the worker whole: only its `reason` (or `note`) text,
// cut to waiting.reason_text_max characters, comes back as `reason`.
//
// Answers: 200 {triage, queue, positions, live_jobs, parked_jobs, edges, knobs,
// truncated, positions_truncated, as_of}; 400 {error, field} on a bad body; a
// D1 failure is the d1Guarded 503 naming the table, never an empty 200.
import { json, d1Guarded } from "../lib/http.js";
import { settingsRows } from "../lib/settings-cache.js";

export const STALE_CLAIM_MIN_DEFAULT = 30;       // settings row waiting.stale_claim_min
export const MAX_TICKETS_DEFAULT = 2000;         // settings row waiting.max_tickets
export const DEFER_LOOKBACK_MIN_DEFAULT = 10080; // settings row waiting.defer_lookback_min
export const REASON_TEXT_MAX_DEFAULT = 200;      // settings row waiting.reason_text_max

const PROJECT_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const KEY_RE = /^[A-Za-z0-9._#-]{1,64}$/;

const P = "project IN (SELECT value FROM json_each(?1))";
const K = "IN (SELECT value FROM json_each(?2))";

export const TRIAGE_SQL =
  `SELECT project, ticket_key, ticket_label, input_hash, verdict, waiting_on, verdict_hash, triaged_at, reason, updated_at
     FROM triage_state WHERE ${P} AND ticket_key ${K}`;
export const QUEUE_SQL =
  `SELECT project, ticket_key, status, claimed_by, claimed_at, enqueued_at, finished_at, reason, machine, updated_at
     FROM build_queue WHERE ${P} AND ticket_key ${K}`;
export const POSITIONS_SQL =
  `SELECT project, ticket_key, enqueued_at FROM build_queue
    WHERE status IN ('queued','ready') AND ${P} ORDER BY enqueued_at, ticket_key LIMIT ?2`;
export const LIVE_JOBS_SQL =
  `SELECT j.id, j.project, j.ticket_id, j.status, j.updated_at, h.beat_at
     FROM jobs j LEFT JOIN job_heartbeats h ON h.job_id = j.id
    WHERE j.${P} AND j.status = 'running' AND j.ticket_id ${K}`;
export const PARKED_JOBS_SQL =
  `SELECT id, project, ticket_id, status, updated_at, meta FROM jobs
    WHERE ${P} AND status IN ('parked','budget_stopped') AND ticket_id ${K} AND created_at >= ?3
    ORDER BY updated_at DESC`;
export const EDGES_SQL =
  `SELECT project, parent, child, kind FROM ticket_edges WHERE ${P} AND child ${K} AND kind = 'hard'`;

// A whole-number settings row in [lo, hi], or `def` when absent or junk.
const intSettingOr = (byKey, key, def, lo, hi) => {
  const row = byKey.get(key);
  const v = row ? String(row.value).trim() : "";
  if (!/^\d+$/.test(v)) return def;
  const n = Number(v);
  return n >= lo && n <= hi ? n : def;
};

const isoMinus = (iso, min) => new Date(Date.parse(iso) - min * 60000).toISOString().replace(/\.\d{3}Z$/, "Z");

// meta -> its reason/note text (<= max chars), or null. Nothing else of meta.
export function metaReason(meta, max = REASON_TEXT_MAX_DEFAULT) {
  if (typeof meta !== "string" || meta === "") return null;
  let m;
  try { m = JSON.parse(meta); } catch { return null; }
  if (!m || typeof m !== "object") return null;
  const r = typeof m.reason === "string" && m.reason.trim() ? m.reason : (typeof m.note === "string" && m.note.trim() ? m.note : null);
  return r === null ? null : r.slice(0, max);
}

// -> {tickets} or {field}: the first bad field, named.
export function parseTickets(body) {
  const list = body && body.tickets;
  if (!Array.isArray(list)) return { field: "tickets" };
  const out = [];
  for (let i = 0; i < list.length; i++) {
    const x = list[i];
    if (!x || typeof x !== "object") return { field: `tickets[${i}]` };
    if (typeof x.project !== "string" || !PROJECT_RE.test(x.project)) return { field: `tickets[${i}].project` };
    if (typeof x.key !== "string" || !KEY_RE.test(x.key)) return { field: `tickets[${i}].key` };
    const id = x.id === undefined || x.id === null || x.id === "" ? null : x.id;
    if (id !== null && (typeof id !== "string" || !KEY_RE.test(id))) return { field: `tickets[${i}].id` };
    out.push({ project: x.project, key: x.key, id });
  }
  return { tickets: out };
}

export const routes = [
  [
    "POST", "/api/waiting/state",
    async ({ env, t, body }) => {
      const parsed = parseTickets(body);
      if (parsed.field) return json(400, { error: "bad_request", field: parsed.field });
      return d1Guarded("waiting", async () => {
        const { byKey } = await settingsRows(env);
        const knobs = {
          stale_claim_min: intSettingOr(byKey, "waiting.stale_claim_min", STALE_CLAIM_MIN_DEFAULT, 1, 10080),
          max_tickets: intSettingOr(byKey, "waiting.max_tickets", MAX_TICKETS_DEFAULT, 1, 100000),
          defer_lookback_min: intSettingOr(byKey, "waiting.defer_lookback_min", DEFER_LOOKBACK_MIN_DEFAULT, 1, 525600),
          reason_text_max: intSettingOr(byKey, "waiting.reason_text_max", REASON_TEXT_MAX_DEFAULT, 1, 4000),
        };
        const truncated = parsed.tickets.length > knobs.max_tickets;
        const tickets = truncated ? parsed.tickets.slice(0, knobs.max_tickets) : parsed.tickets;
        const base = { knobs, truncated, positions_truncated: false, as_of: t };
        if (tickets.length === 0) {
          return json(200, { triage: [], queue: [], positions: [], live_jobs: [], parked_jobs: [], edges: [], ...base });
        }
        const projects = JSON.stringify([...new Set(tickets.map((x) => x.project))]);
        const keys = JSON.stringify([...new Set(tickets.flatMap((x) => (x.id === null ? [x.key] : [x.key, x.id])))]);
        const since = isoMinus(t, knobs.defer_lookback_min);
        const [s1, s2, s3, s4, s5, s6] = await env.DB.batch([
          env.DB.prepare(TRIAGE_SQL).bind(projects, keys),
          env.DB.prepare(QUEUE_SQL).bind(projects, keys),
          env.DB.prepare(POSITIONS_SQL).bind(projects, knobs.max_tickets + 1),
          env.DB.prepare(LIVE_JOBS_SQL).bind(projects, keys),
          env.DB.prepare(PARKED_JOBS_SQL).bind(projects, keys, since),
          env.DB.prepare(EDGES_SQL).bind(projects, keys),
        ]);
        const rows = (r) => (r && r.results) || [];
        let positions = rows(s3);
        const positionsTruncated = positions.length > knobs.max_tickets;
        if (positionsTruncated) positions = positions.slice(0, knobs.max_tickets);
        const cut = (r) => ({ ...r, reason: typeof r.reason === "string" ? r.reason.slice(0, knobs.reason_text_max) : r.reason });
        return json(200, {
          triage: rows(s1),
          queue: rows(s2).map(cut),
          positions,
          live_jobs: rows(s4),
          parked_jobs: rows(s5).map(({ meta, ...j }) => ({ ...j, reason: metaReason(meta, knobs.reason_text_max) })),
          edges: rows(s6),
          ...base,
          positions_truncated: positionsTruncated,
        });
      });
    },
  ],
];
