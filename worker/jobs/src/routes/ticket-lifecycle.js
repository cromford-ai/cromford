// ticket-lifecycle routes — BH-8731 (lifecycle 1/6): where each ticket is in
// its life, and how it got there.
//
//   POST /api/lifecycle/transition   move one ticket's phase (one event per move)
//   GET  /api/lifecycle/stuck        rows older than lifecycle.stuck.<phase>_min
//   GET  /api/lifecycle/history      one ticket's events, newest first
//
// THE PHASE lives on the ticket's build_queue row (columns phase, phase_at,
// phase_actor, question: core.d/bh-8731-lifecycle.js). THE HISTORY is
// ticket_events (schema.d/*-bh-8731-ticket-events.sql). The legal moves and
// their owners are lib/lifecycle.js.
//
// TRANSITION. Body {project, ticket_key, to_phase, actor, reason, pr?,
// question?}. A bad field is 400 {error: <field>}. No build_queue row is 404
// no_row: a lifecycle call never creates queue work. An illegal move, or a
// legal one from an actor that does not own it, is 409 {error, current, to,
// allowed | owners} and writes nothing. An accepted move is ONE env.DB.batch
// (one D1 transaction): the ticket_events INSERT ... SELECT and the
// build_queue UPDATE carry the same `phase IS <the phase read>` guard, so they
// write together or not at all. 0 rows inserted = another writer moved the
// phase between the read and the batch: 409 stale {current}, nothing written.
// `question` is accepted only with to_phase plan_blocked; every other move
// clears it to NULL.
//
// STUCK. One statement per phase that has a threshold, all in one batch. A
// settings row `lifecycle.stuck.<phase>_min` that is a whole number >= 0 wins;
// any other value is the code default (lib/lifecycle.js STUCK_DEFAULT_MIN). A
// phase with neither is not reported; merged and closed never are. Each phase
// reads lifecycle.stuck.limit + 1 rows, oldest first, so `truncated` is
// measured. The settings come from the per-isolate snapshot (BH-5781), so a
// row change needs no deploy.
//
// THE READS (BH-6730). test/ticket-lifecycle.bh-8731.test.js L8 EXPLAINs these
// exact texts at 10 000 tickets and 200 000 events. `+project` keeps the
// planner on idx_build_queue_phase_at.
//
// D1 has no RLS. Every route sits behind the HARNESS_SECRET bearer (this
// family is not in OPEN_FAMILIES). The actor is the body's word: it is a
// correctness guard between lanes that share one bearer, not a security
// boundary.

import { json, d1Guarded } from "../lib/http.js";
import { ensureColumns, ensureTable } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";
import {
  LIFECYCLE_PHASES, LIFECYCLE_TERMINAL, LIFECYCLE_ACTORS, lifecycleCheck, STUCK_DEFAULT_MIN,
} from "../lib/lifecycle.js";

const TABLE = "ticket_events";
const PROJECT_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const KEY_RE = /^[A-Za-z0-9._-]{1,64}$/;
// Input validation bounds, as TEXT_MAX in unblock-decisions.js.
const REASON_MAX = 500;
const QUESTION_MAX = 2000;
// The code fallbacks of the settings rows lifecycle.stuck.limit and
// lifecycle.history.limit (schema.d/*-bh-8731-ticket-events.sql seeds both).
const STUCK_LIMIT_DEFAULT = 200;
const HISTORY_LIMIT_DEFAULT = 200;
const PHASES = new Set(LIFECYCLE_PHASES);

const READ_SQL = "SELECT phase FROM build_queue WHERE project = ?1 AND ticket_key = ?2";
// ?1 project ?2 ticket_key ?3 to ?4 actor ?5 reason ?6 pr ?7 at ?8 the phase read
export const EVENT_SQL =
  `INSERT INTO ticket_events (project, ticket_key, from_phase, to_phase, actor, reason, pr, at)
   SELECT ?1, ?2, phase, ?3, ?4, ?5, ?6, ?7 FROM build_queue
    WHERE project = ?1 AND ticket_key = ?2 AND phase IS ?8`;
// ?1 project ?2 ticket_key ?3 to ?4 actor ?5 at ?6 the phase read ?7 question
export const PHASE_SQL =
  `UPDATE build_queue SET phase = ?3, phase_at = ?5, phase_actor = ?4, question = ?7, updated_at = ?5
    WHERE project = ?1 AND ticket_key = ?2 AND phase IS ?6`;
const STUCK_COLS = "SELECT project, ticket_key, phase, phase_at, phase_actor, question FROM build_queue";
// ?1 phase ?2 cutoff ?3 limit
export const STUCK_SQL = `${STUCK_COLS} WHERE phase = ?1 AND phase_at < ?2 ORDER BY phase_at LIMIT ?3`;
// ?1 phase ?2 cutoff ?3 project ?4 limit
export const STUCK_PROJECT_SQL = `${STUCK_COLS} WHERE phase = ?1 AND phase_at < ?2 AND +project = ?3 ORDER BY phase_at LIMIT ?4`;
// ?1 project ?2 ticket_key ?3 limit
export const HISTORY_SQL =
  "SELECT id, from_phase, to_phase, actor, reason, pr, at FROM ticket_events WHERE project = ?1 AND ticket_key = ?2 ORDER BY id DESC LIMIT ?3";

const bad = (field) => json(400, { error: field });
const changesOf = (res) => Number((res && res.meta && res.meta.changes) || 0);
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

// A settings row that is a whole number >= min, else null (never clamped).
function wholeRow(byKey, key, min) {
  const row = byKey.get(key);
  const v = row ? String(row.value).trim() : "";
  if (!/^\d+$/.test(v)) return null;
  const n = Number(v);
  return Number.isSafeInteger(n) && n >= min ? n : null;
}

// phase -> minutes, for every non-terminal phase that has a row or a default.
export function stuckThresholds(byKey) {
  const out = {};
  for (const phase of LIFECYCLE_PHASES) {
    if (LIFECYCLE_TERMINAL.has(phase)) continue;
    const n = wholeRow(byKey, `lifecycle.stuck.${phase}_min`, 0) ?? STUCK_DEFAULT_MIN[phase];
    if (n !== undefined) out[phase] = n;
  }
  return out;
}

export const routes = [
  // ── POST /api/lifecycle/transition — move one ticket's phase ───────────────
  [
    "POST", "/api/lifecycle/transition",
    async ({ env, t, body }) => {
      const b = isObj(body) ? body : {};
      if (typeof b.project !== "string" || !PROJECT_RE.test(b.project)) return bad("project");
      if (typeof b.ticket_key !== "string" || !KEY_RE.test(b.ticket_key)) return bad("ticket_key");
      if (!PHASES.has(b.to_phase)) return bad("to_phase");
      if (!LIFECYCLE_ACTORS.has(b.actor)) return bad("actor");
      if (typeof b.reason !== "string" || b.reason.trim() === "" || b.reason.length > REASON_MAX) return bad("reason");
      const pr = b.pr ?? null;
      if (pr !== null && !(Number.isSafeInteger(pr) && pr > 0)) return bad("pr");
      const question = b.question ?? null;
      if (question !== null && (typeof question !== "string" || question.length > QUESTION_MAX
        || b.to_phase !== "plan_blocked")) return bad("question");
      const { project, ticket_key: key, to_phase: to, actor } = b;
      return d1Guarded(TABLE, async () => {
        await Promise.all([ensureColumns(env, "build_queue"), ensureTable(env, TABLE)]);
        const row = await env.DB.prepare(READ_SQL).bind(project, key).first();
        if (!row) return json(404, { error: "no_row", project, ticket_key: key });
        const from = row.phase ?? null;
        const chk = lifecycleCheck(from ?? "", to, actor);
        if (!chk.ok) {
          const { ok: _ok, ...why } = chk;
          return json(409, { ...why, current: from, to });
        }
        const [ins] = await env.DB.batch([
          env.DB.prepare(EVENT_SQL).bind(project, key, to, actor, b.reason, pr, t, from),
          env.DB.prepare(PHASE_SQL).bind(project, key, to, actor, t, from, question),
        ]);
        if (changesOf(ins) !== 1) {
          const now = await env.DB.prepare(READ_SQL).bind(project, key).first();
          return json(409, { error: "stale", current: now ? now.phase ?? null : null, to });
        }
        return json(200, {
          ok: true, project, ticket_key: key, from, to,
          event_id: Number(ins.meta.last_row_id), phase_at: t,
        });
      });
    },
  ],

  // ── GET /api/lifecycle/stuck?project= — rows past their phase threshold ────
  [
    "GET", "/api/lifecycle/stuck",
    async ({ env, t, url }) => {
      const project = url.searchParams.get("project");
      if (project !== null && !PROJECT_RE.test(project)) return bad("project");
      return d1Guarded("build_queue", async () => {
        const [{ byKey }] = await Promise.all([settingsRows(env), ensureColumns(env, "build_queue")]);
        const thresholds = stuckThresholds(byKey);
        const limit = wholeRow(byKey, "lifecycle.stuck.limit", 1) ?? STUCK_LIMIT_DEFAULT;
        const nowMs = Date.parse(t);
        const phases = Object.keys(thresholds);
        const stmts = phases.map((ph) => {
          const cutoff = iso(nowMs - thresholds[ph] * 60000);
          return project === null
            ? env.DB.prepare(STUCK_SQL).bind(ph, cutoff, limit + 1)
            : env.DB.prepare(STUCK_PROJECT_SQL).bind(ph, cutoff, project, limit + 1);
        });
        const res = stmts.length ? await env.DB.batch(stmts) : [];
        const rows = [];
        const truncated = {};
        phases.forEach((ph, i) => {
          const got = (res[i] && res[i].results) || [];
          truncated[ph] = got.length > limit;
          for (const r of got.slice(0, limit)) {
            rows.push({ ...r, age_min: Math.floor((nowMs - Date.parse(r.phase_at)) / 60000), threshold_min: thresholds[ph] });
          }
        });
        return json(200, { rows, thresholds, truncated, limit, as_of: t });
      });
    },
  ],

  // ── GET /api/lifecycle/history?project=&ticket_key= — one ticket's events ──
  [
    "GET", "/api/lifecycle/history",
    async ({ env, t, url }) => {
      const project = url.searchParams.get("project");
      const key = url.searchParams.get("ticket_key");
      if (project === null || !PROJECT_RE.test(project)) return bad("project");
      if (key === null || !KEY_RE.test(key)) return bad("ticket_key");
      return d1Guarded(TABLE, async () => {
        const [{ byKey }] = await Promise.all([settingsRows(env), ensureTable(env, TABLE)]);
        const limit = wholeRow(byKey, "lifecycle.history.limit", 1) ?? HISTORY_LIMIT_DEFAULT;
        const { results } = await env.DB.prepare(HISTORY_SQL).bind(project, key, limit + 1).all();
        const got = results || [];
        return json(200, { events: got.slice(0, limit), truncated: got.length > limit, limit, as_of: t });
      });
    },
  ],
];
