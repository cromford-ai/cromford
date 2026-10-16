// triage-state routes — TRIAGE-STATE (the operator, 2026-09-28): the per-ticket triage
// state the pre-check reads before a tick spends a token.
//
// One table (worker/jobs/schema.sql, the TRIAGE-STATE block), three routes:
//   GET /api/triage-state/:project/:key   one row; 404 when there is none
//   GET /api/triage-state?project=P[&due=1][&limit=N]
//                                         the project's rows, ticket order;
//                                         due=1 = next_recheck_at <= now
//   PUT /api/triage-state                 one row ({project, ticket_key, ...})
//                                         or a batch ({project, rows:[...]})
//
// A PUT WRITES ONLY THE COLUMNS IT CARRIES. The pre-check writes the hash it
// observed and what it decided (input_hash, last_decision, last_mode) on every
// tick; the session's close writes the verdict. Neither may erase the other, so
// the upsert's SET names exactly the supplied columns. Every row of a batch is
// validated before the first write: a refused batch writes nothing.
//
// The shell side is triage_state_get / _list / _put in bin/lib/jobs/queue.sh;
// the reader and writer is bin/lib/triage-state.sh.
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable, laneName } from "../lib/core.js";

export const TRIAGE_VERDICTS = [
  "buildable", "needs_clarification", "waiting_client", "queued", "hold", "closed", "blocked", "triaged",
];
export const TRIAGE_WAITING_ON = ["client", "team", "none"];
export const TRIAGE_MODES = ["off", "shadow", "enforce"];
export const TRIAGE_BATCH_MAX = 200;
export const TRIAGE_LIST_MAX = 1000;

// The key is a filename on the box (state/triage-state/<p>/<key>.*) and a path
// segment here, so it is held to the shard key's character class.
const KEY_RE = /^[A-Za-z0-9._-]{1,64}$/;
const HASH_RE = /^[0-9a-f]{16,64}$/;
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/;

const given = (v) => v !== undefined && v !== null;

// The writable columns and how each is checked. `null` in the body clears a
// column only where clearing means something (reason, waiting_on); a verdict or
// a hash is never cleared by a PUT, it is replaced.
const FIELDS = {
  ticket_label: (v) => (typeof v === "string" && /^[A-Za-z0-9._#-]{1,64}$/.test(v) ? v : undefined),
  input_hash: (v) => (typeof v === "string" && HASH_RE.test(v) ? v : undefined),
  verdict: (v) => (TRIAGE_VERDICTS.includes(v) ? v : undefined),
  waiting_on: (v) => (TRIAGE_WAITING_ON.includes(v) ? v : undefined),
  verdict_hash: (v) => (typeof v === "string" && HASH_RE.test(v) ? v : undefined),
  triaged_at: (v) => (typeof v === "string" && ISO_RE.test(v) ? v : undefined),
  next_recheck_at: (v) => (typeof v === "string" && ISO_RE.test(v) ? v : undefined),
  reason: (v) => (typeof v === "string" ? v.slice(0, 500) : undefined),
  last_decision: (v) => (typeof v === "string" && v.length > 0 ? v.slice(0, 200) : undefined),
  last_mode: (v) => (TRIAGE_MODES.includes(v) ? v : undefined),
};

// validateRow -> {row: [[col, value], ...], key} or {error}
function validateRow(r, project) {
  if (!r || typeof r !== "object" || Array.isArray(r)) return { error: "each row must be an object" };
  const key = typeof r.ticket_key === "string" ? r.ticket_key : String(r.ticket_key ?? "");
  if (!KEY_RE.test(key)) return { error: "ticket_key must match [A-Za-z0-9._-]{1,64}" };
  const set = [];
  for (const [col, check] of Object.entries(FIELDS)) {
    if (!given(r[col])) continue;
    const v = check(r[col]);
    if (v === undefined) return { error: `${col} is malformed for ticket ${key}` };
    set.push([col, v]);
  }
  if (set.length === 0) return { error: `ticket ${key}: nothing to write` };
  return { key, set, project };
}

function upsertStmt(env, t, { project, key, set }) {
  const cols = set.map(([c]) => c);
  if (cols.includes("last_decision")) cols.push("last_decision_at");
  const vals = set.map(([, v]) => v);
  if (set.some(([c]) => c === "last_decision")) vals.push(t);
  // sql-ident-ok: cols are keys of the FIELDS constant; values are ?N text
  return env.DB.prepare(
    `INSERT INTO triage_state (project, ticket_key, updated_at, ${cols.join(", ")}) `
    + `VALUES (?1, ?2, ?3, ${cols.map((_, i) => `?${i + 4}`).join(", ")}) `
    + `ON CONFLICT(project, ticket_key) DO UPDATE SET updated_at=excluded.updated_at, `
    + cols.map((c) => `${c}=excluded.${c}`).join(", ")
  ).bind(project, key, t, ...vals);
}

export const routes = [
  [
    "GET", /^\/api\/triage-state\/([^/]+)\/([^/]+)$/,
    async ({ env, t, m }) => d1Guarded("triage_state", async () => {
      const project = laneName(decodeURIComponent(m[1]));
      const key = decodeURIComponent(m[2]);
      if (!project || !KEY_RE.test(key)) return json(400, { error: "project and ticket_key are malformed" });
      await ensureTable(env, "triage_state");
      const row = await env.DB.prepare("SELECT * FROM triage_state WHERE project=?1 AND ticket_key=?2")
        .bind(project, key).first();
      if (!row) return json(404, { error: "no triage_state row", project, ticket_key: key });
      return json(200, { triage_state: row, as_of: t });
    }),
  ],

  [
    "GET", "/api/triage-state",
    async ({ env, url, t }) => d1Guarded("triage_state", async () => {
      const project = laneName(url.searchParams.get("project"));
      if (!project) return json(400, { error: "project must match [A-Za-z0-9._-]{1,64}" });
      const rawLimit = url.searchParams.get("limit");
      let limit = TRIAGE_LIST_MAX;
      if (rawLimit !== null && rawLimit !== "") {
        limit = /^\d+$/.test(rawLimit) ? Number(rawLimit) : 0;
        if (limit < 1 || limit > TRIAGE_LIST_MAX) return json(400, { error: `limit must be an integer in [1, ${TRIAGE_LIST_MAX}]` });
      }
      const due = url.searchParams.get("due") === "1";
      await ensureTable(env, "triage_state");
      const where = due ? "project=?1 AND next_recheck_at IS NOT NULL AND next_recheck_at<=?2" : "project=?1";
      // sql-ident-ok: where is one of two literals; limit passes a digits regex and a range check
      const stmt = env.DB.prepare(`SELECT * FROM triage_state WHERE ${where} ORDER BY ticket_key ASC LIMIT ${limit + 1}`);
      const rows = ((due ? await stmt.bind(project, t).all() : await stmt.bind(project).all()).results) || [];
      const truncated = rows.length > limit;
      return json(200, { project, triage_state: rows.slice(0, limit), truncated, as_of: t });
    }),
  ],

  [
    "PUT", "/api/triage-state",
    async ({ env, t, body }) => d1Guarded("triage_state", async () => {
      const b = body && typeof body === "object" ? body : {};
      const project = laneName(b.project);
      if (!project) return json(400, { error: "project must match [A-Za-z0-9._-]{1,64}" });
      const raw = Array.isArray(b.rows) ? b.rows : [b];
      if (raw.length === 0) return json(400, { error: "rows[] is empty" });
      // Refused whole, never sliced: a batch cut at 200 is a tick whose tail
      // silently never recorded what it decided.
      if (raw.length > TRIAGE_BATCH_MAX) return json(413, { error: `at most ${TRIAGE_BATCH_MAX} rows per PUT` });
      const rows = [];
      for (const r of raw) {
        const v = validateRow(r, project);
        if (v.error) return json(400, { error: v.error });
        rows.push(v);
      }
      await ensureTable(env, "triage_state");
      await env.DB.batch(rows.map((r) => upsertStmt(env, t, r)));
      return json(200, { project, upserted: rows.length, as_of: t });
    }),
  ],
];
