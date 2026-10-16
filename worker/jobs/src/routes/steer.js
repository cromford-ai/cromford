// steer routes — BH-5839 (Mission Control step-in): the ticket page's "Step in"
// composer. One steer_notes row per message, in one of three modes:
//
//   now     the build reads it at its next step boundary. bin/agent-call.sh
//           calls POST /api/steer/take before every model call CC() makes for
//           a build, so a note sent now is in the prompt of the next stage the
//           build starts. The take only claims it (status taken). The call's
//           exit settles it (POST /api/steer/settle): rc 0 makes it read, any
//           other exit gives it back as pending for the next step.
//           Only a RUNNING BUILD job can take one: a note sent anywhere else
//           would go nowhere, so it is refused, not stored.
//   ticket  the hub posts it as one issue comment (bin/lib/steer-deliver.sh,
//           GET /outbox, POST /:id/claim, then POST /:id/delivered). Later
//           stages read the thread.
//   hold    the hub holds the ticket with the note as the reason, and the job it
//           was sent to stops at its next step boundary (take answers `hold`).
//
// Every send and every read is also a stage_events row on the job, so the
// job's own log says when a person stepped in and when the build saw it.

import { json } from "../lib/http.js";
import { ensureTable, laneName, strictInt } from "../lib/core.js";

export const STEER_MODES = ["now", "ticket", "hold"];
export const STEER_TEXT_MAX = 4000;
// A hold note is the hold REASON (bin/lib/ticket-hold-cmd.sh caps it at 500).
// A longer one is refused here, never cut there.
export const STEER_HOLD_TEXT_MAX = 500;
// The settings rows `steer.attempts_max` (1..10) and `steer.outbox_limit`
// (1..100), seeded by schema.d/0020-bh-5839-steer-notes.sql. These two
// constants are the documented fallback for a row that is absent or bad.
export const STEER_ATTEMPTS_MAX = 3;
export const STEER_OUTBOX_LIMIT = 10;
// steer.take_lease_s (60..86400) and steer.deliver_lease_s (60..3600): how long
// a taken "now" note, or a claimed outbox note, stays with the box that took
// it before it is offered again. A box that died without settling or
// reporting gives its notes back this way.
export const STEER_TAKE_LEASE_S = 7200;
export const STEER_DELIVER_LEASE_S = 300;
const SETTLE_IDS_MAX = 100;
const LIST_MAX = 100;
const TICKET_RE = /^[A-Za-z][A-Za-z0-9]*-[1-9][0-9]{0,8}$/;

const noteOut = (r) => ({
  id: Number(r.id), project: r.project, ticket: r.ticket, job_id: r.job_id ?? null, mode: r.mode,
  text: r.text, actor: r.actor, status: r.status, attempts: Number(r.attempts || 0), detail: r.detail ?? null,
  build_read_at: r.build_read_at ?? null, delivered_at: r.delivered_at ?? null,
  created_at: r.created_at, updated_at: r.updated_at,
});

// A settings row as an integer in lo..hi, or the fallback.
async function setting(env, key, lo, hi, fallback) {
  const v = await env.DB.prepare("SELECT value FROM settings WHERE key = ?1").bind(key).first("value");
  const n = typeof v === "string" && /^\d+$/.test(v.trim()) ? Number(v.trim()) : NaN;
  return Number.isInteger(n) && n >= lo && n <= hi ? n : fallback;
}

// The ISO second `s` seconds before `t`, in nowIso's shape, so the text
// comparison with updated_at is a time comparison.
const before = (t, s) => new Date(Date.parse(t) - s * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");

const event = (env, jobId, verdict, actor, detail, t) => env.DB.prepare(
  `INSERT INTO stage_events (job_id, stage, verdict, actor, detail, created_at) VALUES (?1, 'steer', ?2, ?3, ?4, ?5)`
).bind(jobId, verdict, actor, detail, t).run();

export const routes = [
  [
    "POST", "/api/steer",
    async ({ env, t, body }) => {
      const project = laneName(body.project);
      if (!project) return json(400, { error: "project must match [A-Za-z0-9._-]{1,64}" });
      const ticket = typeof body.ticket === "string" && TICKET_RE.test(body.ticket) ? body.ticket : "";
      if (!ticket) return json(400, { error: "ticket must be a key like BH-5839" });
      const mode = STEER_MODES.includes(body.mode) ? body.mode : "";
      if (!mode) return json(400, { error: `mode must be one of ${STEER_MODES.join(", ")}` });
      const text = typeof body.text === "string" ? body.text.trim() : "";
      if (!text) return json(400, { error: "text required" });
      if (text.length > STEER_TEXT_MAX) return json(400, { error: `text is over ${STEER_TEXT_MAX} characters` });
      if (mode === "hold" && text.length > STEER_HOLD_TEXT_MAX) {
        return json(400, { error: `a hold note is over ${STEER_HOLD_TEXT_MAX} characters; it is the hold reason` });
      }
      const actor = typeof body.actor === "string" ? body.actor.trim().slice(0, 128) : "";
      if (!actor) return json(400, { error: "actor required" });

      let jobId = null;
      if (body.job_id !== undefined && body.job_id !== null && body.job_id !== "") {
        jobId = String(body.job_id).slice(0, 200);
        const job = await env.DB.prepare("SELECT id, project, ticket_id, kind, status FROM jobs WHERE id=?1").bind(jobId).first();
        if (!job) return json(404, { error: "no such job" });
        if (job.project !== project || job.ticket_id !== ticket) {
          return json(409, { error: `job ${jobId} is ${job.project} ${job.ticket_id}, not ${project} ${ticket}` });
        }
        if (mode === "now" && (job.kind !== "build" || job.status !== "running")) {
          return json(409, { error: `job ${jobId} is a ${job.status} ${job.kind} job; only a running build reads a note now` });
        }
      } else if (mode === "now") {
        return json(400, { error: "job_id required: a note sent now goes to one running build" });
      }

      await ensureTable(env, "steer_notes");
      const row = await env.DB.prepare(
        `INSERT INTO steer_notes (project, ticket, job_id, mode, text, actor, status, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'pending', ?7, ?7) RETURNING *`
      ).bind(project, ticket, jobId, mode, text, actor, t).first();
      if (jobId) await event(env, jobId, "SENT", actor, `${mode} note #${row.id}`, t);
      return json(201, { note: noteOut(row) });
    },
  ],

  [
    "GET", "/api/steer",
    async ({ env, t, url }) => {
      const project = laneName(url.searchParams.get("project"));
      const ticket = url.searchParams.get("ticket") || "";
      if (!project || !TICKET_RE.test(ticket)) return json(400, { error: "project and ticket required" });
      await ensureTable(env, "steer_notes");
      // sql-ident-ok: LIST_MAX is a module number const
      const rows = await env.DB.prepare(
        `SELECT * FROM steer_notes WHERE project=?1 AND ticket=?2 ORDER BY id DESC LIMIT ${LIST_MAX}`
      ).bind(project, ticket).all();
      return json(200, { notes: (rows.results || []).map(noteOut), as_of: t });
    },
  ],

  // The step boundary. The first hold note sent to this job is handed over
  // once. A hold is checked FIRST: a call that takes a hold refuses its stage,
  // so it takes no "now" note, and those stay pending for the job that resumes.
  // Without a hold, each pending "now" note of the job is claimed once (the
  // UPDATE's WHERE is the claim, so two readers never both get it) as taken,
  // not read: POST /api/steer/settle says whether the call ran. A taken note
  // whose box never settled is taken again after steer.take_lease_s. A hold
  // sent to an earlier job of the ticket does not stop a later one; the hold
  // LABEL keeps that one from starting at all.
  [
    "POST", "/api/steer/take",
    async ({ env, t, body }) => {
      const jobId = typeof body.job_id === "string" && body.job_id ? body.job_id.slice(0, 200) : "";
      if (!jobId) return json(400, { error: "job_id required" });
      await ensureTable(env, "steer_notes");
      const hold = await env.DB.prepare(
        `UPDATE steer_notes SET build_read_at=?2, updated_at=?2
          WHERE id = (SELECT id FROM steer_notes WHERE job_id=?1 AND mode='hold' AND build_read_at IS NULL ORDER BY id LIMIT 1)
          RETURNING *`
      ).bind(jobId, t).first();
      if (hold) {
        await event(env, jobId, "HOLD", "build", `hold note #${hold.id}: stopped at the step boundary`, t);
        return json(200, { notes: [], hold: noteOut(hold), as_of: t });
      }
      const lease = await setting(env, "steer.take_lease_s", 60, 86400, STEER_TAKE_LEASE_S);
      const now = await env.DB.prepare(
        `UPDATE steer_notes SET status='taken', updated_at=?2
          WHERE job_id=?1 AND mode='now' AND (status='pending' OR (status='taken' AND updated_at < ?3)) RETURNING *`
      ).bind(jobId, t, before(t, lease)).all();
      const notes = (now.results || []).map(noteOut).sort((a, b) => a.id - b.id);
      return json(200, { notes, hold: null, as_of: t });
    },
  ],

  // The call's exit. read: true when the call that took the notes ran (rc 0),
  // so the build read them; build_read_at is the take time, when that step
  // started with them in its prompt, and each read is a stage event. read:
  // false gives them back as pending, so the next step boundary takes them.
  // Only notes this job has taken move.
  [
    "POST", "/api/steer/settle",
    async ({ env, t, body }) => {
      const jobId = typeof body.job_id === "string" && body.job_id ? body.job_id.slice(0, 200) : "";
      if (!jobId) return json(400, { error: "job_id required" });
      const ids = Array.isArray(body.ids) ? body.ids : [];
      if (!ids.length || ids.length > SETTLE_IDS_MAX || !ids.every((i) => Number.isInteger(i) && i > 0)) {
        return json(400, { error: `ids must be 1..${SETTLE_IDS_MAX} note ids` });
      }
      if (typeof body.read !== "boolean") return json(400, { error: "read must be true or false" });
      await ensureTable(env, "steer_notes");
      const marks = ids.map((_, i) => `?${i + 3}`).join(",");
      const sql = body.read
        ? `UPDATE steer_notes SET status='read', build_read_at=updated_at, updated_at=?2
            WHERE job_id=?1 AND mode='now' AND status='taken' AND id IN (${marks}) RETURNING *`
        : `UPDATE steer_notes SET status='pending', updated_at=?2
            WHERE job_id=?1 AND mode='now' AND status='taken' AND id IN (${marks}) RETURNING *`;
      const rows = await env.DB.prepare(sql).bind(jobId, t, ...ids).all();
      const notes = (rows.results || []).map(noteOut).sort((a, b) => a.id - b.id);
      if (body.read) for (const n of notes) await event(env, jobId, "READ", "build", `now note #${n.id}`, t);
      return json(200, { notes, as_of: t });
    },
  ],

  [
    "GET", "/api/steer/outbox",
    async ({ env, t, url }) => {
      const asked = strictInt(url.searchParams.get("limit"));
      const limit = asked === null
        ? await setting(env, "steer.outbox_limit", 1, LIST_MAX, STEER_OUTBOX_LIMIT)
        : Math.min(Math.max(asked, 1), LIST_MAX);
      const lease = await setting(env, "steer.deliver_lease_s", 60, 3600, STEER_DELIVER_LEASE_S);
      await ensureTable(env, "steer_notes");
      const rows = await env.DB.prepare(
        `SELECT * FROM steer_notes WHERE mode IN ('ticket','hold')
            AND (status='pending' OR (status='delivering' AND updated_at < ?2)) ORDER BY id LIMIT ?1`
      ).bind(limit, before(t, lease)).all();
      return json(200, { notes: (rows.results || []).map(noteOut), as_of: t });
    },
  ],

  // The hub's claim, before it posts anything. One UPDATE, so of two boxes
  // that read the same outbox page only one gets 200 and posts. A claim whose
  // box never reported is offered again after steer.deliver_lease_s; the hub
  // finds its own comment by the note's marker then, and does not post twice.
  [
    "POST", /^\/api\/steer\/([0-9]{1,12})\/claim$/,
    async ({ env, t, m }) => {
      const id = Number(m[1]);
      await ensureTable(env, "steer_notes");
      const lease = await setting(env, "steer.deliver_lease_s", 60, 3600, STEER_DELIVER_LEASE_S);
      const row = await env.DB.prepare(
        `UPDATE steer_notes SET status='delivering', updated_at=?2
          WHERE id=?1 AND mode IN ('ticket','hold')
            AND (status='pending' OR (status='delivering' AND updated_at < ?3)) RETURNING *`
      ).bind(id, t, before(t, lease)).first();
      if (row) return json(200, { note: noteOut(row) });
      const cur = await env.DB.prepare("SELECT * FROM steer_notes WHERE id=?1").bind(id).first();
      if (!cur) return json(404, { error: "no such note" });
      return json(409, { error: `note ${id} is ${cur.status}`, note: noteOut(cur) });
    },
  ],

  // The hub's report on a note it claimed. ok: the comment (or the hold)
  // answered, so the note is delivered. Not ok: one more attempt is counted and
  // the note goes back to the outbox, until the steer.attempts_max row
  // (fallback STEER_ATTEMPTS_MAX) makes it failed. An unclaimed or finished
  // note is 409.
  [
    "POST", /^\/api\/steer\/([0-9]{1,12})\/delivered$/,
    async ({ env, t, body, m }) => {
      const id = Number(m[1]);
      await ensureTable(env, "steer_notes");
      const cap = await setting(env, "steer.attempts_max", 1, 10, STEER_ATTEMPTS_MAX);
      const detail = typeof body.detail === "string" && body.detail ? body.detail.slice(0, 500) : null;
      const row = body.ok === true
        ? await env.DB.prepare(
          `UPDATE steer_notes SET status='delivered', delivered_at=?2, detail=?3, updated_at=?2
            WHERE id=?1 AND status='delivering' AND mode IN ('ticket','hold') RETURNING *`
        ).bind(id, t, detail).first()
        : await env.DB.prepare(
          `UPDATE steer_notes SET attempts=attempts+1, detail=?3, updated_at=?2,
                  status=CASE WHEN attempts+1 >= ?4 THEN 'failed' ELSE 'pending' END
            WHERE id=?1 AND status='delivering' AND mode IN ('ticket','hold') RETURNING *`
        ).bind(id, t, detail, cap).first();
      if (row) return json(200, { note: noteOut(row) });
      const cur = await env.DB.prepare("SELECT * FROM steer_notes WHERE id=?1").bind(id).first();
      if (!cur) return json(404, { error: "no such note" });
      return json(409, { error: `note ${id} is ${cur.status}`, note: noteOut(cur) });
    },
  ],
];
