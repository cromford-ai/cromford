// job-abandon routes — BH-2406: an operator ends a job for good.
//
// `abandoned` is terminal (JOB_TRANSITIONS in ../lib/core.js) and this is the
// ONLY way into it: PATCH /api/jobs/:id refuses the status, so every abandoned
// row carries one ABANDONED stage event naming who did it and why. The console
// reaches this through the coord proxy, which stamps the actor itself.
//
// What the state MEANS to the rest of the fleet is read off the ticket's
// NEWEST build row (bin/lib/jobs/jobs.sh job_ticket_abandoned): the resume pass
// does not relaunch the build dir, the pool does not requeue the key, and the
// blocked-resolver takes no rung on it. A later attempt on the same ticket
// opens a newer row and is offered normally.
//
// It does not stop a process that is still running and it does not close a
// PR. A live build that later tries to close its row gets a 409 (terminal),
// which job_lane_close already treats as fail-open.

import { json } from "../lib/http.js";
import { JOB_TRANSITIONS, checkTransition, putClaim, str } from "../lib/core.js";

export const routes = [
  [
    "POST", /^\/api\/jobs\/([^/]+)\/abandon$/,
    async ({ env, t, body, m: abandonMatch }) => {
      const id = decodeURIComponent(abandonMatch[1]);
      const job = await env.DB.prepare("SELECT * FROM jobs WHERE id=?1").bind(id).first();
      if (!job) return json(404, { error: "no such job" });
      // No fallback for either: an abandon nobody can explain, or nobody can
      // be named for, is not an audited one.
      const reason = (str(body.reason, 512) || "").trim();
      if (!reason) return json(400, { error: "reason required" });
      const actor = (str(body.actor, 128) || "").trim();
      if (!actor) return json(400, { error: "actor required" });

      const prev = String(job.status);
      if (prev === "abandoned") {
        return json(200, { job_id: id, decision: "already", already: true, status: prev, reason: "already abandoned", as_of: t });
      }
      const bad = checkTransition(JOB_TRANSITIONS, prev, "abandoned", "job");
      if (bad) return json(409, { ...bad, job_id: id, refused: true });

      // ONE batch, which D1 runs as one transaction. The status write is a
      // compare-and-set on the status read above; the event and the queue close
      // only land when that write did (same row, status abandoned, stamped t),
      // so a lost CAS writes nothing at all.
      const landed = "EXISTS (SELECT 1 FROM jobs WHERE id=?5 AND status='abandoned' AND updated_at=?2)";
      const stmts = [
        env.DB.prepare("UPDATE jobs SET status='abandoned', updated_at=?1 WHERE id=?2 AND status=?3")
          .bind(t, id, prev),
        env.DB.prepare(
          `INSERT INTO stage_events (job_id, stage, verdict, actor, detail, created_at)
           SELECT ?1, ?2, 'ABANDONED', ?3, ?4, ?5
           WHERE EXISTS (SELECT 1 FROM jobs WHERE id=?1 AND status='abandoned' AND updated_at=?5)
             AND NOT EXISTS (SELECT 1 FROM stage_events WHERE job_id=?1 AND verdict='ABANDONED')`
        ).bind(id, job.stage, actor, reason, t),
      ];
      // The ticket's waiting queue rows close with it, so nothing dispatches
      // the key again. A `claimed` row is left alone: the pool has a machine on
      // it and owns that row's close (bin/fly-pool.sh QROW). And only when this
      // is the ticket's NEWEST build row, because abandoning an old attempt must
      // not cancel a newer one's queue entry. Only a build row is an attempt:
      // triage, lead-review, orc and migration rows share the ticket key, and a
      // newer one of those must not keep the queue row alive.
      if (job.ticket_id) {
        const qreason = `ABANDONED by ${actor} from job ${id}: ${reason}`.slice(0, 512);
        // sql-ident-ok: landed is a local literal EXISTS clause with ?N binds
        stmts.push(env.DB.prepare(
          `UPDATE build_queue SET status='failed', reason=?1, finished_at=?2, updated_at=?2
           WHERE project=?3 AND ticket_key=?4 AND status IN ('ready','queued')
             AND ${landed}
             AND NOT EXISTS (SELECT 1 FROM jobs WHERE project=?3 AND ticket_id=?4 AND kind='build'
                               AND created_at > (SELECT created_at FROM jobs WHERE id=?5))`
        ).bind(qreason, t, job.project, job.ticket_id, id));
      }
      const res = await env.DB.batch(stmts);

      if (!res[0] || !res[0].meta || res[0].meta.changes === 0) {
        // Someone else moved the row between the read and the batch. If that
        // someone abandoned it, the caller's intent already holds.
        const now = await env.DB.prepare("SELECT status FROM jobs WHERE id=?1").bind(id).first();
        if (now && String(now.status) === "abandoned") {
          return json(200, { job_id: id, decision: "already", already: true, status: "abandoned", reason: "already abandoned", as_of: t });
        }
        return json(409, { error: "job status moved, reload", job_id: id, refused: true, status: now ? now.status : null });
      }

      // The claim's reason is what the Job screen shows next to the status. Best
      // effort: the audited event above is already committed either way.
      try {
        await putClaim(env, id, { reason: `abandoned by ${actor}: ${reason}` }, t);
      } catch { /* the event carries the record */ }

      return json(200, {
        job_id: id, decision: "abandoned", reason, actor, previous_status: prev,
        queue_rows_closed: (res[2] && res[2].meta && res[2].meta.changes) || 0, as_of: t,
      });
    },
  ],
];
