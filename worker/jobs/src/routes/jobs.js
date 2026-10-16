// jobs routes — the job rows themselves: list, claim, patch.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import {
  OPEN_STATUS, resolveLane, decorateJob, JOBS_SELECT, JOB_TRANSITIONS,
  checkTransition, checkPause, checkRules, putClaim, ensureColumns, jobId,
} from "../lib/core.js";

export const routes = [
  // ── Jobs ───────────────────────────────────────────────────────────────
  [
    "GET", "/api/jobs",
    async ({ env, url, t }) => {
      const where = [], binds = [];
      // ticket_id + kind (BH-2406): bin/lib/jobs/jobs.sh job_ticket_abandoned
      // asks for one ticket's newest BUILD row (triage, lead-review, orc and
      // migration rows share the ticket key). Additive; an unknown param was
      // always ignored.
      for (const col of ["project", "status", "box", "ticket_id", "kind"]) {
        const v = url.searchParams.get(col);
        if (v) { binds.push(v); where.push(`j.${col}=?${binds.length}`); }
      }
      // A positive integer: `limit=-1` used to build `LIMIT -1`, which is no limit at all.
      const limit = Math.min(Math.max(Math.floor(Number(url.searchParams.get("limit"))) || 100, 1), 500);
      const sql = `${JOBS_SELECT}${where.length ? " WHERE " + where.join(" AND ") : ""}`
        + ` ORDER BY j.created_at DESC LIMIT ${limit}`;
      const rows = await env.DB.prepare(sql).bind(...binds).all();
      let jobs = (rows.results || []).map((r) => decorateJob(r, t));
      // ?stale_min=N — what the watchdog asks for: open rows whose last sign of
      // life is older than N minutes. The THRESHOLD is the caller's (the
      // watchdog owns the policy and its test drives it); the CLOCK is the
      // server's, which is the only clock every box agrees on.
      const staleMin = Number(url.searchParams.get("stale_min"));
      if (Number.isFinite(staleMin) && staleMin > 0) {
        jobs = jobs.filter((j) => j.status === OPEN_STATUS
          && j.activity_age_s !== null && j.activity_age_s >= staleMin * 60);
      }
      return json(200, { jobs, as_of: t });
    },
  ],

  [
    "POST", "/api/jobs",
    async ({ env, path, t, body }) => {
      await ensureColumns(env, "jobs");
      const project = String(body.project || "").trim();
      const kind = String(body.kind || "").trim();
      const box = String(body.box || "").trim();
      if (!project || !kind || !box) return json(400, { error: "project, kind and box are required" });
      const ticket = body.ticket_id ? String(body.ticket_id).slice(0, 128) : null;
      const stage = String(body.stage || "plan").slice(0, 64);
      // ── BH-482.3: the board's own clock ──────────────────────────────────
      // `issue_created_at` is the instant the ticket appeared on the board, as
      // the caller read it off the issue. Accepted ONLY in the exact shape
      // bin/jobs-client.sh sends (seconds, Z) and never coerced into it: a
      // reshaped stamp is a measurement of something nobody recorded. Never a
      // 400 either — a claim refused over telemetry is a build that does not
      // run.
      const issueCreatedAt = typeof body.issue_created_at === "string"
        && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(body.issue_created_at)
        ? body.issue_created_at
        : null;
      const claimLane = body.lane ? String(body.lane) : `${stage}/${project}/*`;

      // ── Phase 7: PAUSE FLAGS ARE AUTHORITATIVE AT CLAIM TIME ─────────────
      // FIRST, before the double-build guard and before the concurrency rules:
      // a pause is not "how many of these may run", it is "none of this runs
      // here right now", and it must also stop a due retry being picked up.
      // Phase 3 put pause flags in rows and had each box reconcile a FILE from
      // them — which only reached boxes that ran flag_sync and only the readers
      // that test that particular file. A fly builder boots, claims and builds
      // without reconciling anything. Checking here puts every box in the fleet
      // through one answer.
      // The FILE stays the fallback (bin/jobs-client.sh `flag_active` is
      // untouched), so a worker outage leaves every box deciding exactly as it
      // does today, and an empty pause_flags table refuses nothing at all.
      const paused = await checkPause(env, { project, box, lane: claimLane });
      if (paused) {
        return json(409, { error: "refused: paused", refused: true, ...paused });
      }

      // THE DOUBLE-BUILD GUARD. An open job for the same project+ticket+kind on
      // ANOTHER box means work is already in flight somewhere the caller cannot
      // see — 409 with the existing row and let the caller decide (default:
      // stop and log). The SAME box re-claiming is a resume (RESUME_BUILD, a
      // relaunched pipeline), which must stay idempotent, so it gets its row
      // back with 200 instead of being locked out of its own work.
      // Ticketless jobs (a triage tick) are not guarded: they are serialized by
      // the per-project flock and would otherwise all collide on one key.
      if (ticket) {
        const open = await env.DB.prepare(
          "SELECT * FROM jobs WHERE project=?1 AND ticket_id=?2 AND kind=?3 AND status=?4 ORDER BY created_at DESC"
        ).bind(project, ticket, kind, OPEN_STATUS).first();
        if (open) {
          if (open.box === box) return json(200, { job: open, resumed: true });
          return json(409, { error: "already in flight on another box", job: open });
        }
      }

      const lane = claimLane;
      const id = String(body.id || jobId(kind, project, ticket, Date.now()));

      // ── Phase 7: a claim may not resurrect a finished row ────────────────
      // The INSERT below is ON CONFLICT(id) DO UPDATE SET status='running', so
      // a caller that supplies an id already carrying a terminal status would
      // walk `done` straight back to `running` — the one transition the graph
      // names explicitly. Only checked when the caller NAMED an id: a generated
      // one carries Date.now() and cannot collide, and every claim paying for a
      // lookup it can never need is a cost on the hot path for nothing.
      if (body.id) {
        const existing = await env.DB.prepare("SELECT status FROM jobs WHERE id=?1").bind(id).first();
        if (existing) {
          const bad = checkTransition(JOB_TRANSITIONS, String(existing.status), OPEN_STATUS, "job");
          if (bad) return json(409, { ...bad, refused: true, scope: "transition", job_id: id,
            reason: bad.reason || `job ${id} is ${existing.status} and cannot be re-claimed` });
        }
      }

      // ── Phase 6: the rules decide, atomically with the claim ──────────────
      // The guard above is the one rule that was ever written in code. These
      // are rows, so "same repo, one build" or "this box, two at a time" is an
      // UPDATE rather than a deploy, and the check happens HERE — inside the
      // claim, against state every box shares, rather than in each box's own
      // files where in-flight work elsewhere is invisible.
      // No row for a scope means unlimited: deleting this table returns the
      // fleet to phase-5 behaviour exactly.
      const refusal = await checkRules(env, { project, ticket, kind, box, lane, id });
      if (refusal) {
        return json(409, {
          error: "refused by a concurrency rule",
          refused: true,
          ...refusal,
        });
      }

      // ── Phase 6: a due retry is picked up, never started fresh ────────────
      // The watchdog queues a retry; it never runs one. The lane's own next
      // cron tick lands here and TAKES OVER the queued row — same job id, same
      // ticket, attempts+1 — so a retried piece of work is one row with a
      // history rather than a second row nobody can tie to the first.
      const retryRow = await env.DB.prepare(
        `SELECT j.*, c.attempts AS attempts, c.max_attempts AS max_attempts,
                c.next_attempt_at AS next_attempt_at, c.lane AS lane
           FROM jobs j LEFT JOIN job_claims c ON c.job_id = j.id
          WHERE j.status='queued_for_retry' AND j.project=?1 AND j.kind=?2
            AND ((?3 IS NULL AND j.ticket_id IS NULL) OR j.ticket_id=?3)
          ORDER BY j.created_at ASC LIMIT 1`
      ).bind(project, kind, ticket).first();
      if (retryRow) {
        const due = !retryRow.next_attempt_at || Date.parse(retryRow.next_attempt_at) <= Date.parse(t);
        if (!due) {
          // Refusing is the point of a backoff. Starting fresh work while a
          // retry of the SAME work is scheduled is how a backoff becomes a
          // second attempt that arrives early.
          return json(409, {
            error: "a retry of this work is scheduled",
            refused: true,
            scope: "retry",
            reason: `retry scheduled for ${retryRow.next_attempt_at} (attempt ${(Number(retryRow.attempts) || 1) + 1} of ${retryRow.max_attempts || "?"})`,
            job: retryRow,
          });
        }
        const attempts = (Number(retryRow.attempts) || 1) + 1;
        // COMPARE-AND-SWAP, not a plain write. Two boxes ticking in the same
        // second both see one due row; without the status in the WHERE clause
        // both would take it over and the retry would be the double build this
        // whole layer exists to stop. SQLite reports the rows it actually
        // changed, so the loser learns it lost and defers.
        const took = await env.DB.prepare(
          "UPDATE jobs SET status=?2, box=?3, stage=?4, updated_at=?5 WHERE id=?1 AND status='queued_for_retry'"
        ).bind(retryRow.id, OPEN_STATUS, box, stage, t).run();
        if (!took.meta.changes) {
          return json(409, {
            error: "another box took this retry",
            refused: true,
            scope: "retry",
            reason: `another box picked up the retry of ${retryRow.id} first`,
            job: retryRow,
          });
        }
        await putClaim(env, retryRow.id, {
          lane, attempts, next_attempt_at: null,
          reason: `attempt ${attempts} of ${retryRow.max_attempts || "?"}, picked up by ${box}`,
        }, t);
        await env.DB.prepare(
          `INSERT INTO stage_events (job_id, stage, verdict, actor, detail, created_at)
           VALUES (?1,?2,'RETRY_PICKUP',?3,?4,?5)`
        ).bind(retryRow.id, stage, box, `attempt ${attempts} of ${retryRow.max_attempts || "?"} on lane ${lane}`, t).run();
        const row = await env.DB.prepare("SELECT * FROM jobs WHERE id=?1").bind(retryRow.id).first();
        return json(200, { job: row, retry: true, attempts, lane });
      }

      let budget = Number(body.budget_usd);
      let budgetSource = "caller";
      if (!Number.isFinite(budget) || budget <= 0) {
        const r = await resolveLane(env, lane);
        budget = r.budget_usd;
        budgetSource = r.source;
      }
      const meta = body.meta === undefined || body.meta === null
        ? null
        : (typeof body.meta === "string" ? body.meta : JSON.stringify(body.meta)).slice(0, 8000);
      // ── BH-482.3: when this fleet FIRST put an agent on this ticket ───────
      // A rebuild or a takeover opens a second row against the same ticket, and
      // stamping it with its own instant would report the last attempt's wait
      // as the ticket's launch lead time — the same trap the PR attribution
      // above avoids by taking the earliest job. So the earliest build row for
      // (project, ticket) wins, and this claim's own instant only when it IS
      // the first. Ticketless work (a triage tick) has no ticket to have
      // waited, and pays for no read.
      let firstSpawnAt = null;
      if (kind === "build" && ticket) {
        try {
          const first = await env.DB.prepare(
            "SELECT MIN(created_at) AS first_spawn_at FROM jobs WHERE project=?1 AND ticket_id=?2 AND kind='build'"
          ).bind(project, ticket).first();
          firstSpawnAt = first?.first_spawn_at ?? t;
        } catch {
          // Telemetry never refuses a claim. NULL is the honest "unknown" — the
          // DORA read drops those rows on its IS NOT NULL filter, where falling
          // back to `t` would quietly report a rebuild as a ticket that waited
          // no time at all.
          firstSpawnAt = null;
        }
      }
      await env.DB.prepare(
        `INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, budget_usd, spent_usd, created_at, updated_at, meta, issue_created_at, first_spawn_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,0,?9,?9,?10,?11,?12)
         ON CONFLICT(id) DO UPDATE SET box=?5, stage=?6, status=?7, updated_at=?9`
      ).bind(id, project, ticket, kind, box, stage, OPEN_STATUS, budget, t, meta,
        issueCreatedAt, firstSpawnAt).run();
      // The claim's lane is recorded because both phase-6 tables key on it: a
      // lane rule cannot count peers it cannot see, and a retry policy cannot
      // resolve for a job whose lane was thrown away after budgeting.
      const claim = await putClaim(env, id, { lane }, t);
      const row = await env.DB.prepare("SELECT * FROM jobs WHERE id=?1").bind(id).first();
      return json(201, { job: row, lane, attempts: claim.attempts, budget_source: budgetSource });
    },
  ],

  [
    "PATCH", /^\/api\/jobs\/([^/]+)$/,
    async ({ env, t, body, m: jobMatch }) => {
      const id = decodeURIComponent(jobMatch[1]);
      const sets = [], binds = [];
      const set = (frag, val) => { binds.push(val); sets.push(frag.replace("?", `?${binds.length}`)); };
      if (body.stage) set("stage=?", String(body.stage).slice(0, 64));
      if (body.status) {
        // ── Phase 7: enforced transitions ──────────────────────────────────
        // Through phase 6 this accepted any string, so a stale client or a
        // replayed close could walk a finished job back to `running` — which
        // reopens a claim the double-build guard has already released. The
        // graph is in JOB_TRANSITIONS and it is the same one the spec doc
        // prints, so the two cannot drift.
        const status = String(body.status).slice(0, 32);
        // BH-2406: `abandoned` is reachable only through the audited
        // POST /api/jobs/:id/abandon, which records who and why. Taking it here
        // would be a second, silent way into a terminal state.
        if (status === "abandoned") {
          return json(409, { error: "abandon through POST /api/jobs/:id/abandon, which records who and why", job_id: id });
        }
        const cur = await env.DB.prepare("SELECT status FROM jobs WHERE id=?1").bind(id).first();
        if (!cur) return json(404, { error: "no such job" });
        const bad = checkTransition(JOB_TRANSITIONS, String(cur.status), status, "job");
        if (bad) return json(409, { ...bad, job_id: id });
        set("status=?", status);
      }
      if (body.budget_usd !== undefined && Number.isFinite(Number(body.budget_usd))) {
        set("budget_usd=?", Number(body.budget_usd));
      }
      // Absolute set OR increment. agent-call.sh knows only what THIS stage
      // cost, never the job total, so spend arrives as a delta and the sum is
      // computed here — a read-modify-write from the box would lose whichever
      // of two concurrent stages wrote second.
      if (body.spent_usd !== undefined && Number.isFinite(Number(body.spent_usd))) {
        set("spent_usd=?", Number(body.spent_usd));
      } else if (body.spend_delta !== undefined && Number.isFinite(Number(body.spend_delta))) {
        set("spent_usd=COALESCE(spent_usd,0)+?", Number(body.spend_delta));
      }
      if (body.meta !== undefined && body.meta !== null) {
        set("meta=?", (typeof body.meta === "string" ? body.meta : JSON.stringify(body.meta)).slice(0, 8000));
      }
      if (sets.length === 0) return json(400, { error: "nothing to update" });
      binds.push(t); sets.push(`updated_at=?${binds.length}`);
      binds.push(id);
      // sql-ident-ok: sets are literal col=? strings from the set() calls in this handler
      const r = await env.DB.prepare(`UPDATE jobs SET ${sets.join(", ")} WHERE id=?${binds.length}`)
        .bind(...binds).run();
      if (r.meta.changes === 0) return json(404, { error: "no such job" });
      const row = await env.DB.prepare("SELECT * FROM jobs WHERE id=?1").bind(id).first();
      return json(200, { job: row });
    },
  ],
];
