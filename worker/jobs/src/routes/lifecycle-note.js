// lifecycle-note routes — BH-9160 (the rest of BH-8734): one ticket_events row
// that moves no phase.
//
//   POST /api/lifecycle/note   {project, ticket_key, actor, reason, pr?}
//
// A NEW family (test/route-table.d/bh-9160-lifecycle-note.txt), beside
// ticket-lifecycle.js, which owns the phase moves. The note appends ONE
// ticket_events row and leaves the build_queue row alone: from_phase is the
// row's phase and to_phase is the same phase, or `none` when the row has no
// phase yet. The actor is one of lib/lifecycle.js LIFECYCLE_ACTORS or
// `watchdog`, an actor that owns no phase move, so a note is never read as one.
// bin/jobs-watchdog.sh writes it when it holds a review row the call guard
// refused on its head (comment 6502199389 on #8734).
//
// The same (project, ticket_key, actor, reason) is written once: a repeat is
// 200 {duplicate: true} and writes nothing. No build_queue row is 404 no_row:
// a note never creates queue work. A bad field is 400 {error: <field>}, with
// the transition route's validation bounds.
//
// THE READS (BH-6730). NOTE_SQL reads build_queue on its (project, ticket_key)
// key and the NOT EXISTS reads one ticket's events on
// idx_ticket_events_project_ticket_id; test/lifecycle-note.bh-9160.test.js N8
// EXPLAINs it at 10 000 queue rows and 200 000 events. No new table: the rows
// are ticket_events, kept by the existing retention rule ticket_events.age.
//
// D1 has no RLS. The route sits behind the HARNESS_SECRET bearer (this family
// is not in OPEN_FAMILIES).

import { json, d1Guarded } from "../lib/http.js";
import { ensureColumns, ensureTable } from "../lib/core.js";
import { LIFECYCLE_ACTORS } from "../lib/lifecycle.js";

const TABLE = "ticket_events";
const PROJECT_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const KEY_RE = /^[A-Za-z0-9._-]{1,64}$/;
// Input validation bound, as REASON_MAX in ticket-lifecycle.js.
const REASON_MAX = 500;

const READ_SQL = "SELECT phase FROM build_queue WHERE project = ?1 AND ticket_key = ?2";
// ?1 project ?2 ticket_key ?3 actor ?4 reason ?5 pr ?6 at
export const NOTE_SQL =
  `INSERT INTO ticket_events (project, ticket_key, from_phase, to_phase, actor, reason, pr, at)
   SELECT ?1, ?2, phase, COALESCE(phase, 'none'), ?3, ?4, ?5, ?6 FROM build_queue
    WHERE project = ?1 AND ticket_key = ?2
      AND NOT EXISTS (SELECT 1 FROM ticket_events
                       WHERE project = ?1 AND ticket_key = ?2 AND actor = ?3 AND reason = ?4)`;

// Read at call time, so an actor a later slice adds to LIFECYCLE_ACTORS may note too.
const noteActor = (a) => a === "watchdog" || LIFECYCLE_ACTORS.has(a);
const bad = (field) => json(400, { error: field });
const changesOf = (res) => Number((res && res.meta && res.meta.changes) || 0);
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

export const routes = [
  [
    "POST", "/api/lifecycle/note",
    async ({ env, t, body }) => {
      const b = isObj(body) ? body : {};
      if (typeof b.project !== "string" || !PROJECT_RE.test(b.project)) return bad("project");
      if (typeof b.ticket_key !== "string" || !KEY_RE.test(b.ticket_key)) return bad("ticket_key");
      if (!noteActor(b.actor)) return bad("actor");
      if (typeof b.reason !== "string" || b.reason.trim() === "" || b.reason.length > REASON_MAX) return bad("reason");
      const pr = b.pr ?? null;
      if (pr !== null && !(Number.isSafeInteger(pr) && pr > 0)) return bad("pr");
      const { project, ticket_key: key, actor } = b;
      return d1Guarded(TABLE, async () => {
        await Promise.all([ensureColumns(env, "build_queue"), ensureTable(env, TABLE)]);
        const ins = await env.DB.prepare(NOTE_SQL).bind(project, key, actor, b.reason, pr, t).run();
        if (changesOf(ins) === 1) {
          return json(200, { ok: true, project, ticket_key: key, duplicate: false, event_id: Number(ins.meta.last_row_id), at: t });
        }
        const row = await env.DB.prepare(READ_SQL).bind(project, key).first();
        if (!row) return json(404, { error: "no_row", project, ticket_key: key });
        return json(200, { ok: true, project, ticket_key: key, duplicate: true, at: t });
      });
    },
  ],
];
