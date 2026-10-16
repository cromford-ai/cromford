// queue routes — the build queue: enqueue, list, claim, patch.
//
// Moved out of the one flat `if (path === … && req.method === …)` chain in
// src/index.js by BH-1195. Every handler body below is the chain's body
// VERBATIM — same SQL, same validation, same status codes, same response keys —
// so this file changed where the code lives and nothing about what it answers.
// src/index.js holds the ordered table that decides which of these runs.

import { json } from "../lib/http.js";
import {
  ageSeconds, QUEUE_TRANSITIONS, checkTransition, ensureColumns, intOrNull, isoPlusSeconds,
  str, laneName,
} from "../lib/core.js";

// A merge sha, NORMALISED ONCE, here (D17). `deploy_queue` is keyed on
// (project, sha), so a value that differs only in case or whitespace is a
// SECOND row for one commit — which is a second departure, a second hook and a
// second Vercel build. Both writers send 40 hex (bin/deploy-request.sh gets the
// merge sha, the train's self-source gets `git rev-parse`); the 7-64 range
// admits a short sha typed by hand at the client. Anything else is a 400 rather
// than a stored value nothing will ever match.
function deploySha(v) {
  const s = String(v === undefined || v === null ? "" : v).trim().toLowerCase();
  return /^[0-9a-f]{7,64}$/.test(s) ? s : "";
}

// queueWake <key> <event> — one `queue` wake for bin/wake-loop.sh (BH-4059),
// deduped on idx_wakes_dedupe(repo,kind,key,minute) with the webhook's minute
// bucket. Never throws: the caller's write is the thing that matters, and the
// fly lanes' own cron ticks are the backstop for a wake that did not land.
export async function queueWake(env, key, event, t) {
  try {
    await env.DB.prepare(
      `INSERT INTO wakes (repo, kind, key, event, minute, at)
       VALUES ('harness/build-queue', 'queue', ?1, ?2, ?3, ?4)
       ON CONFLICT(repo, kind, key, minute) DO NOTHING`
    ).bind(key, event, t.slice(0, 16) + ":00Z", t).run();
  } catch (e) {
    console.error("queue wake insert failed", key, String((e && e.message) || e).slice(0, 300));
  }
}

export const routes = [
  // ── THE PRE-CLAIM BUILD QUEUE (2026-09-10) ─────────────────────────────
  // Everything above models a job from the moment a box CLAIMS it. These four
  // routes model the wait BEFORE that, which until now was
  // state/build-queue/<project>/<KEY>.json on a box and could only be read by
  // ssh-ing into the box. See the `build_queue` comment in schema.sql.
  //
  // THE FILE STAYS THE FALLBACK during the transition: producers write both,
  // readers ask here first. An unreachable worker leaves every box queueing
  // and draining exactly as it does today.

  // Enqueue. IDEMPOTENT ON (project, KEY) — the same identity a filename gave
  // it — because run-build.sh, the fly requeue and a triage relaunch all
  // enqueue the same key and a second entry is a second build.
  [
    "POST", "/api/queue",
    async ({ env, path, t, body }) => {
      const project = laneName(body.project);
      const key = laneName(body.key || body.ticket_key);
      if (!project) return json(400, { error: "project is required and must match [A-Za-z0-9._-]{1,64}" });
      if (!key) return json(400, { error: "key is required and must match [A-Za-z0-9._-]{1,64}" });
      const target = String(body.target || "local") === "fly" ? "fly" : "local";
      // BH-1033: an enqueue may name `ready` (a ticket the board says is
      // buildable, which no dispatcher may claim) and NOTHING ELSE. Anything
      // else — absent, a typo, a status only PATCH should reach — is `queued`,
      // which is byte-for-byte what every caller of this route got before.
      const wanted = String(body.status || "") === "ready" ? "ready" : "queued";
      const existing = await env.DB.prepare(
        "SELECT * FROM build_queue WHERE project=?1 AND ticket_key=?2").bind(project, key).first();
      // Waiting OR in flight is the same answer to the caller: this build is
      // already accounted for. `claimed` matters most — re-enqueueing a key
      // mid-build is exactly what spawned a second TK-70 after the reap.
      //
      // A `ready` PUT MAY ONLY CREATE A ROW OR REUSE A `dropped` ONE (BH-1033).
      // It is refused over every other status, and each refusal is a different
      // row somebody else owns:
      //   ready   — the stale-owed sweep re-offers the same key every run, and a
      //             row it re-wrote would lose the enqueued_at its 24h cooldown
      //             is judged on.
      //   queued/claimed — a launch already happened; knocking it back to ready
      //             is how one ticket gets built twice.
      //   done/failed — THE TERMINAL LEDGER. This upsert blanks reason,
      //             finished_at and target and bumps attempt, and the hourly
      //             sweep calls it for every stale key — including the `failed`
      //             row bin/fly-pool.sh parks with `died N times …` that
      //             bin/blocked-resolver.sh intakes BY THAT REASON, and the
      //             `done` row whose RESULT line the same lane reads out of the
      //             reason column. A re-offer must not erase a finished build;
      //             the READY-QUEUE.log line carries it exactly as it does today.
      // A DROPPED row is the one reuse: its line was consumed, nothing ran.
      //
      // A ready row must NEVER refuse a real BUILD enqueue, though:
      // bin/orphan-reconcile.sh and every launch path call this route with no
      // status, and answering `duplicate` there would leave a ticket that is
      // merely READY unbuildable for as long as its row sits — the starvation
      // this table exists to end, reintroduced one layer up. A build enqueue
      // PROMOTES the row to `queued`, which is what launching it means, and a
      // terminal row is re-queueable as a build exactly as it was before.
      if (existing && (existing.status === "queued" || existing.status === "claimed"
                       || (wanted === "ready" && existing.status !== "dropped"))) {
        return json(200, {
          queued: existing, duplicate: true,
          reason: `${project}/${key} is already ${existing.status}${existing.claimed_by ? ` on ${existing.claimed_by}` : ""}`,
        });
      }
      // A caller-supplied attempt wins (the fly requeue counts its own); with
      // none, a re-queue of a finished row continues its count rather than
      // restarting it, so "this ticket has died twice" survives the round trip.
      // OFFERING IS NOT ATTEMPTING (BH-1033): a `ready` put is the board saying
      // a ticket is buildable, and the only row it can land on is a `dropped`
      // one whose line was consumed without a build. Counting that as an
      // attempt would walk a ticket that never failed toward its retry cap.
      let attempt = intOrNull(body.attempt);
      if (attempt === null) {
        attempt = existing ? (Number(existing.attempt) || 0) + (wanted === "ready" ? 0 : 1) : 0;
      }
      const meta = body.meta === undefined || body.meta === null
        ? null
        : (typeof body.meta === "string" ? body.meta : JSON.stringify(body.meta)).slice(0, 4000);
      // BH-1026.0: the re-queue clears `machine` with the rest of the last
      // attempt's state. This upsert lands on a row that is terminal, dropped or
      // ready, and a terminal row carries the machine that RAN it — leaving that
      // id in place would hand the next claim (every local one sends none) a row
      // that says `claimed` while naming a machine from the attempt before. The
      // statement names the column, so the live table is widened first; the
      // INSERT half leaves it out and gets NULL from the CREATE.
      await ensureColumns(env, "build_queue");
      await env.DB.prepare(
        `INSERT INTO build_queue (project, ticket_key, ticket_id, status, target, attempt,
                                  requested_by, claimed_by, claimed_at, enqueued_at, finished_at,
                                  reason, meta, updated_at)
         VALUES (?1,?2,?3,?9,?4,?5,?6,NULL,NULL,?7,NULL,NULL,?8,?7)
         ON CONFLICT(project, ticket_key) DO UPDATE SET
           ticket_id=COALESCE(?3, build_queue.ticket_id), status=?9, target=?4, attempt=?5,
           requested_by=?6, claimed_by=NULL, claimed_at=NULL, machine=NULL, enqueued_at=?7,
           finished_at=NULL, reason=NULL, meta=?8, updated_at=?7`
      ).bind(project, key, str(body.ticket_id, 128), target, attempt,
             str(body.requested_by, 64), t, meta, wanted).run();
      // BH-4059: A FLY BUILD THAT CAN BE CLAIMED RINGS THE DOORBELL. One `queue`
      // wake, which bin/lib/wake-class-queue.sh turns into a fly-dispatch +
      // fly-pool-tick launch on the hub instead of waiting for their cron tick.
      // Only `queued` + `fly`: a `ready` row is one no dispatcher may claim and
      // a `local` row is never read by the fly lanes. The repo is a fixed
      // synthetic slug because the worker has no project→repo map; it can never
      // name a fleet repo. AFTER the build row and BEST EFFORT: the row above is
      // already committed and is what the dispatchers read, so a failed wake
      // costs one cron tick of latency and must never change this answer.
      if (wanted === "queued" && target === "fly") {
        await queueWake(env, `${project}:${key}`, "build_queue.insert", t);
      }
      // Answered from what was just written rather than read back: the enqueue
      // is on the launch path and every field of the row was decided here.
      return json(201, {
        queued: {
          project, ticket_key: key,
          ticket_id: str(body.ticket_id, 128) || (existing ? existing.ticket_id : null),
          status: wanted, target, attempt,
          requested_by: str(body.requested_by, 64),
          claimed_by: null, claimed_at: null, machine: null, enqueued_at: t, finished_at: null,
          reason: null, meta, updated_at: t,
        },
        duplicate: false, as_of: t,
      });
    },
  ],

  [
    "GET", "/api/queue",
    async ({ env, url, t }) => {
      const where = [], binds = [];
      for (const col of ["project", "status", "target"]) {
        const v = url.searchParams.get(col);
        if (v) { binds.push(v); where.push(`${col}=?${binds.length}`); }
      }
      // ?key= — "what is the status of THIS build", which the fly dispatcher's
      // drain needs per file to tell "never enqueued" (pull it, as today) from
      // "already claimed or finished" (drop it). Without that distinction a
      // stale box file is pulled after its build was reaped and the pool spawns
      // a second machine for the key.
      const key = url.searchParams.get("key");
      if (key) { binds.push(key); where.push(`ticket_key=?${binds.length}`); }
      // Math.max(1, …): SQLite reads LIMIT -1 as UNBOUNDED, so a negative or
      // junk ?limit= would return the whole table rather than nothing.
      // ?reason_deferred=1 — the rows whose terminal reason says the build STOOD
      // DOWN rather than finished: bin/run-build.sh's BUILD_DEFERRED, and the
      // "REFUSED <scope> ::" a concurrency rule hands back before a job row even
      // exists. bin/jobs-watchdog.sh sweeps exactly these and re-queues them, so
      // it must be able to ASK for them: the page is ordered oldest-first and
      // capped, and once the table holds more than a page of finished builds an
      // unfiltered scan would never reach today's deferral. The class is defined
      // here, in one place, rather than in each caller's grep.
      if (url.searchParams.get("reason_deferred")) {
        binds.push("BUILD_DEFERRED%", "%REFUSED%");
        where.push(`(reason LIKE ?${binds.length - 1} OR reason LIKE ?${binds.length})`);
      }
      const limit = Math.min(Math.max(1, Number(url.searchParams.get("limit")) || 200), 500);
      const sql = "SELECT * FROM build_queue"
        + (where.length ? ` WHERE ${where.join(" AND ")}` : "")
        + ` ORDER BY enqueued_at ASC LIMIT ${limit}`;
      const rows = await env.DB.prepare(sql).bind(...binds).all();
      let queue = rows.results || [];
      // ?stale_min=N — what the watchdog asks for: rows CLAIMED longer ago than
      // N minutes. The THRESHOLD is the caller's (the watchdog owns that policy
      // and its test drives it); the CLOCK is the server's, the only one every
      // box agrees on. Same split as GET /api/jobs?stale_min=.
      const staleMin = Number(url.searchParams.get("stale_min"));
      if (Number.isFinite(staleMin) && staleMin > 0) {
        queue = queue.filter((q) => q.status === "claimed"
          && q.claimed_at && ageSeconds(q.claimed_at, t) >= staleMin * 60);
      }
      return json(200, { queue, as_of: t });
    },
  ],

  // Claim-next. ONE CLAIMANT, and the guarantee is the compare-and-swap: the
  // read picks a candidate, the UPDATE only lands while the row is still
  // `queued`, and SQLite reports what it actually changed — so the second
  // dispatcher ticking in the same second learns it lost instead of building
  // the same ticket. `mv` gave the file queue this on ONE box and never
  // across two, which is the whole reason the hub had to hold the queue.
  //
  // An EMPTY queue is a 404: a real answer that bin/jobs-client.sh turns into
  // rc 2 without burning the daily unreachable-worker alert. "Nothing to
  // build" is the normal shape of a quiet project.
  [
    "POST", "/api/queue/claim",
    async ({ env, path, t, body }) => {
      const project = laneName(body.project);
      const box = laneName(body.box) || laneName(body.claimed_by);
      if (!project || !box) return json(400, { error: "project and box are required" });
      const key = body.key || body.ticket_key ? laneName(body.key || body.ticket_key) : "";
      const target = body.target ? String(body.target) : "";
      // BH-1026.0: WHICH machine took it, when the claimant is a Fly machine.
      // Optional, and absence is a SHAPE rather than a failure — every caller
      // that exists today sends no machine and gets today's SQL and today's
      // query order. The RESPONSE gains one key the moment the column exists,
      // because `queued` IS the row and the row is a `SELECT *`: a claim that
      // sent no machine answers `machine: null`. Every caller reads named
      // fields, so that is additive, but it is a change and it is stated here
      // rather than in a comment claiming the response is untouched.
      //
      // A STRING SHAPED LIKE AN ID, OR NOTHING — deliberately not `str()`.
      // `String()` turns {"a":1} into "[object Object]", [1,2] into "1,2" and 42
      // into "42", all inside any length bound, and a COERCED id is a WRONG id:
      // it names a machine that does not exist, or — worse, for the "1,2" shape
      // — one that does and is somebody else's. Same reason an over-long value
      // is refused rather than sliced to 64 (D11: never clamp explicit input).
      // The pattern is looser than a Fly id (14 hex) on purpose: we do not own
      // that format, so this is a shape check and not a charset registry.
      //
      // AN UNUSABLE `machine` DOES NOT REFUSE THE CLAIM, it records none. The
      // guarantee this column carries is "a claimed row never names the WRONG
      // machine", not "a claimed row always names one" — a row with no machine
      // reads exactly as every row a local build claims. The caller sees which
      // it got: the response echoes the value that was recorded, never the one
      // that was sent.
      const machine = typeof body.machine === "string"
        && /^[A-Za-z0-9._:-]{1,64}$/.test(body.machine) ? body.machine : null;
      // HOTFIX FIRST, then FIFO. Every unkeyed pick below orders by this rank
      // ahead of `enqueued_at`, so a hotfix enqueued into a busy queue does not
      // wait behind a morning's worth of routine tickets. Two details are load
      // bearing and neither is obvious:
      //   json_type(...)='true', not json_extract(...)=1, because json_extract
      //   returns the integer 1 for BOTH the JSON boolean true and the number
      //   1 — so `{"hotfix":1}` would jump the queue. Only the boolean counts,
      //   the same rule bin/lib/hotfix-lib.sh's hotfix_job_is documents.
      //   json_valid(meta), because json_type on a value that is not JSON
      //   raises SQLITE_ERROR: malformed JSON, and one hand-edited row would
      //   turn this route into a 500 for every project sharing the queue.
      const RANK = `CASE WHEN json_valid(meta)
                         THEN (CASE WHEN json_type(meta,'$.hotfix')='true' THEN 0 ELSE 1 END)
                         ELSE 1 END`;
      let row;
      if (key) {
        // The local launch path knows which build it is about to run: it wants
        // THIS row, and only while nobody else holds it.
        row = await env.DB.prepare(
          "SELECT * FROM build_queue WHERE project=?1 AND ticket_key=?2 AND status='queued'"
        ).bind(project, key).first();
      } else if (target) {
        // sql-ident-ok: RANK is a local literal CASE expression
        row = await env.DB.prepare(
          `SELECT * FROM build_queue WHERE project=?1 AND target=?2 AND status='queued'
           ORDER BY ${RANK}, enqueued_at ASC LIMIT 1`
        ).bind(project, target).first();
      } else {
        // sql-ident-ok: RANK is a local literal CASE expression
        row = await env.DB.prepare(
          `SELECT * FROM build_queue WHERE project=?1 AND status='queued'
           ORDER BY ${RANK}, enqueued_at ASC LIMIT 1`
        ).bind(project).first();
      }
      if (!row) return json(404, { error: "nothing queued", project, target: target || null });
      // LOSING A RACE FOR THE OLDEST ROW IS NOT "NOTHING TO DO". A caller that
      // asked for "the next build" and got a 409 skips a whole tick while other
      // work sits queued behind the row it lost. So an unkeyed claim walks on to
      // the next candidate; only a claim for a NAMED key refuses, because there
      // the caller wanted that row and no other. Bounded, because a caller
      // losing every race is a signal rather than a reason to loop.
      // BEFORE THE FIRST WRITE THAT NAMES THE COLUMN, and only then: a database
      // whose build_queue predates `machine` is widened here, so a machine the
      // caller DID send can never be dropped by a missing column. If the ALTER
      // fails the claim fails loudly rather than landing without it.
      if (machine) await ensureColumns(env, "build_queue");
      const skipped = [];
      for (let attempt = 0; attempt < 5; attempt++) {
        const took = await env.DB.prepare(
          machine
            ? "UPDATE build_queue SET status='claimed', claimed_by=?3, claimed_at=?4, machine=?5, updated_at=?4 WHERE project=?1 AND ticket_key=?2 AND status='queued'"
            : "UPDATE build_queue SET status='claimed', claimed_by=?3, claimed_at=?4, updated_at=?4 WHERE project=?1 AND ticket_key=?2 AND status='queued'"
        ).bind(project, row.ticket_key, box, t, ...(machine ? [machine] : [])).run();
        if (took.meta.changes) {
          return json(200, {
            queued: { ...row, status: "claimed", claimed_by: box, claimed_at: t, updated_at: t,
                      ...(machine ? { machine } : {}) },
            claimed: true, ...(skipped.length ? { skipped } : {}), as_of: t,
          });
        }
        skipped.push(row.ticket_key);
        if (key) {
          return json(409, {
            error: "another claimant took this build", refused: true, scope: "queue",
            reason: `another claimant took ${project}/${row.ticket_key} first`,
            queued: row,
          });
        }
        const holes = skipped.map((_, i) => `?${i + 2}`).join(",");
        // sql-ident-ok: holes and the target clause are ?N placeholders over bound keys; RANK is a local literal CASE expression
        row = await env.DB.prepare(
          `SELECT * FROM build_queue WHERE project=?1 AND status='queued'
             AND ticket_key NOT IN (${holes})${target ? ` AND target=?${skipped.length + 2}` : ""}
           ORDER BY ${RANK}, enqueued_at ASC LIMIT 1`
        ).bind(project, ...skipped, ...(target ? [target] : [])).first();
        if (!row) return json(404, { error: "nothing queued", project, target: target || null, skipped });
      }
      return json(409, {
        error: "lost every claim race", refused: true, scope: "queue",
        reason: `lost ${skipped.length} claim races in a row on ${project} — another claimant is draining this queue`,
        skipped,
      });
    },
  ],

  // Release / complete. Releasing clears the claimant — a row that still
  // names a box the next claim would read as in flight is how a failed push
  // parks a build forever.
  [
    "PATCH", "/api/queue",
    async ({ env, t, body }) => {
      const project = laneName(body.project);
      const key = laneName(body.key || body.ticket_key);
      if (!project || !key) return json(400, { error: "project and key are required" });
      const status = String(body.status || "").slice(0, 32);
      const cur = await env.DB.prepare(
        "SELECT * FROM build_queue WHERE project=?1 AND ticket_key=?2").bind(project, key).first();
      if (!cur) return json(404, { error: `nothing queued for ${project}/${key}` });
      const bad = checkTransition(QUEUE_TRANSITIONS, String(cur.status), status, "queue entry");
      if (bad) return json(409, { ...bad, project, key });
      const terminal = status === "done" || status === "failed";
      // BH-1026.0: A RELEASE CLEARS THE MACHINE WITH THE CLAIMANT. `machine`
      // names where a CLAIM is running; a row put back to `queued` is running
      // nowhere, and an id left behind on it survives into the next claim —
      // every claim that carries no machine (which is every local one) leaves
      // the dead machine's id on a row now held by somebody else. That is the
      // same wrong-id class the claim path refuses for a coerced value, arriving
      // through the release path instead: a reaper or a dispatcher acts on a
      // machine that is gone, or recycled to another build. The invariant this
      // restores is exact — a `claimed` row's machine is the machine of the
      // claim that set it, or none.
      //
      // A TERMINAL row KEEPS it: "which machine ran this build" is ledger, and
      // nothing re-claims a done/failed row without going back through
      // POST /api/queue, which clears the column on the way.
      //
      // The column is widened first, and only on the release path, so a PATCH
      // to done/failed is still today's exact statement.
      const releasing = status === "queued";
      if (releasing) await ensureColumns(env, "build_queue");
      // sql-ident-ok: the machine reset is a literal picked by releasing
      await env.DB.prepare(
        `UPDATE build_queue SET status=?3, reason=?4,
           claimed_by=CASE WHEN ?3='queued' THEN NULL ELSE claimed_by END,
           claimed_at=CASE WHEN ?3='queued' THEN NULL ELSE claimed_at END,
           ${releasing ? "machine=NULL," : ""}
           finished_at=CASE WHEN ?5=1 THEN ?6 ELSE NULL END,
           updated_at=?6
         WHERE project=?1 AND ticket_key=?2`
      ).bind(project, key, status, str(body.reason, 500), terminal ? 1 : 0, t).run();
      return json(200, {
        queued: {
          ...cur, status, reason: str(body.reason, 500),
          claimed_by: status === "queued" ? null : cur.claimed_by,
          claimed_at: status === "queued" ? null : cur.claimed_at,
          ...(releasing ? { machine: null } : {}),
          finished_at: terminal ? t : null, updated_at: t,
        },
        as_of: t,
      });
    },
  ],

  // ── THE DEPLOY QUEUE (BH-1026.1) ───────────────────────────────────────────
  // state/deploy-queue/<project>/<epoch>-<sha8> as ROWS. The file store is one
  // file per REQUEST holding "<merge-sha> <build-dir>"; this table is keyed on
  // (project, sha), because "deploy this commit" is a desired END STATE and
  // departing twice on one sha is a double-move.
  //
  // THE FILE DIR IS NOT GONE. bin/deploy-request.sh still writes it, and
  // bin/deploy-train.sh still reads it with `deploy_queue_rows` off, with the
  // worker unreachable, or when the list below does not answer. These routes
  // are inert until an operator flips that knob.

  // Enqueue. IDEMPOTENT on (project, sha), and the shape of the idempotency is
  // the one thing here that is NOT obvious: a `queued`, `claimed` or `held` row
  // answers `duplicate` and is not written (an in-flight departure is never
  // reset under the train carrying it, and a hold is never undone by an
  // enqueue), while a TERMINAL row is RE-OPENED.
  //
  // Re-open, not INSERT OR IGNORE, because of one real case:
  // bin/deploy-train.sh self-sources a departure exactly when a sha has already
  // departed `done` and production is STILL not serving it. Dropped as a
  // duplicate, the train would read an empty queue and production would stay
  // stale with no departure and no alert — the outage the self-source path
  // exists to end. worker/jobs/test/schema-deploy-queue.bh-1026.test.js pins
  // this contract against the shipped SQL.
  [
    "POST", "/api/deploy-queue",
    async ({ env, t, body }) => {
      const project = laneName(body.project);
      const sha = deploySha(body.sha);
      if (!project) return json(400, { error: "project is required and must match [A-Za-z0-9._-]{1,64}" });
      if (!sha) return json(400, { error: "sha is required and must match [0-9a-f]{7,64}" });
      const buildDir = str(body.build_dir, 500);
      const existing = await env.DB.prepare(
        "SELECT * FROM deploy_queue WHERE project=?1 AND sha=?2").bind(project, sha).first();
      // A `held` row (BH-3154) is a duplicate too: an operator took it out of
      // the train, and no merge, ADOPT or self-source may put it back.
      const dup = (row) => json(200, {
        deploy: row, duplicate: true,
        reason: `${project}@${sha.slice(0, 8)} is already ${row.status}${row.claimed_by ? ` on ${row.claimed_by}` : ""}`,
      });
      if (existing && ["queued", "claimed", "held"].includes(existing.status)) return dup(existing);
      // COALESCE on build_dir: a request that names one wins, a request that
      // names none keeps what the row already had. A self-sourced retry
      // therefore records `self-sourced`, which is what the file beside it says.
      const up = await env.DB.prepare(
        `INSERT INTO deploy_queue (project, sha, build_dir, status, claimed_by, reason,
                                   enqueued_at, departed_at, updated_at)
         VALUES (?1,?2,?3,'queued',NULL,NULL,?4,NULL,?4)
         ON CONFLICT(project, sha) DO UPDATE SET
           status='queued', build_dir=COALESCE(?3, deploy_queue.build_dir),
           claimed_by=NULL, reason=NULL, enqueued_at=?4, departed_at=NULL, updated_at=?4
         WHERE deploy_queue.status <> 'held'`
      ).bind(project, sha, buildDir, t).run();
      // A hold that landed between the SELECT above and this upsert: the
      // guard left the row alone, so answer it as the duplicate it now is.
      if (!up || !up.meta || up.meta.changes === 0) {
        const now = await env.DB.prepare(
          "SELECT * FROM deploy_queue WHERE project=?1 AND sha=?2").bind(project, sha).first();
        if (now && now.status === "held") return dup(now);
      }
      // Answered from what was just written: this call is on the merge path and
      // every field of the row was decided here.
      return json(201, {
        deploy: {
          project, sha, build_dir: buildDir || (existing ? existing.build_dir : null),
          status: "queued", claimed_by: null, reason: null,
          enqueued_at: t, departed_at: null, updated_at: t,
        },
        duplicate: false, as_of: t,
      });
    },
  ],

  [
    "GET", "/api/deploy-queue",
    async ({ env, url, t }) => {
      const where = [], binds = [];
      for (const col of ["project", "status", "sha"]) {
        const v = url.searchParams.get(col);
        if (v) { binds.push(col === "sha" ? deploySha(v) : v); where.push(`${col}=?${binds.length}`); }
      }
      // Math.max(1, …): SQLite reads LIMIT -1 as UNBOUNDED, so junk here would
      // return the whole table rather than a page.
      const limit = Math.min(Math.max(1, Number(url.searchParams.get("limit")) || 200), 500);
      // The sha tiebreak is not cosmetic: a batch of merges lands inside one
      // second routinely, and without it the batch order is whatever the file
      // system hands back.
      const sql = "SELECT * FROM deploy_queue"
        + (where.length ? ` WHERE ${where.join(" AND ")}` : "")
        + ` ORDER BY enqueued_at ASC, sha ASC LIMIT ${limit}`;
      const rows = await env.DB.prepare(sql).bind(...binds).all();
      let deploy_queue = rows.results || [];
      // ?stale_min=N — the rows a train can re-offer: CLAIMED longer ago than N
      // minutes and never departed. The THRESHOLD is the caller's
      // (DEPLOY_CLAIM_STALE_MIN is the train's own knob) and the CLOCK is the
      // server's, the only one every box agrees on. Same split as
      // GET /api/queue?stale_min=.
      const staleMin = Number(url.searchParams.get("stale_min"));
      if (Number.isFinite(staleMin) && staleMin > 0) {
        deploy_queue = deploy_queue.filter((d) => d.status === "claimed" && !d.departed_at
          && d.updated_at && ageSeconds(d.updated_at, t) >= staleMin * 60);
      }
      return json(200, { deploy_queue, as_of: t });
    },
  ],

  // Claim. ONE CLAIMANT PER SHA, and the guarantee is the compare-and-swap:
  // there is NO read before the write, the UPDATE only lands while the row is
  // still `queued` (or is a claim that went quiet), and SQLite reports what it
  // actually changed. The per-box `locks/deploy-train-<p>.lock` never guarded
  // anything across boxes; this does, and a lost race means a second train
  // fires no second deploy hook.
  //
  // `stale_min` re-offers a claim whose train died: the row is `claimed`,
  // `departed_at` is NULL, and nothing will ever close it. The cutoff is
  // computed from the server's own `t` so two boxes cannot disagree about it.
  [
    "POST", "/api/deploy-queue/claim",
    async ({ env, t, body }) => {
      const project = laneName(body.project);
      const sha = deploySha(body.sha);
      const box = laneName(body.box) || laneName(body.claimed_by);
      if (!project || !sha || !box) return json(400, { error: "project, sha and box are required" });
      // D11: junk is NOT clamped to a number. An unparseable stale_min means NO
      // cutoff — the plain `status='queued'` CAS — never some other threshold.
      const staleMin = Number(body.stale_min);
      const cutoff = Number.isFinite(staleMin) && staleMin > 0
        ? isoPlusSeconds(t, -staleMin * 60) : null;
      const took = await env.DB.prepare(
        `UPDATE deploy_queue SET status='claimed', claimed_by=?3, updated_at=?4
         WHERE project=?1 AND sha=?2
           AND (status='queued'
                OR (status='claimed' AND departed_at IS NULL
                    AND ?5 IS NOT NULL AND updated_at <= ?5))`
      ).bind(project, sha, box, t, cutoff).run();
      // Read AFTER the write, never before: the answer is what the table holds.
      const row = await env.DB.prepare(
        "SELECT * FROM deploy_queue WHERE project=?1 AND sha=?2").bind(project, sha).first();
      if (took.meta.changes) return json(200, { deploy: row, claimed: true, as_of: t });
      // NO ROW is a 404, which bin/jobs-client.sh turns into rc 2 without
      // burning the daily unreachable-worker alert: "nothing queued" is the
      // normal shape of a project that has not merged anything.
      if (!row) return json(404, { error: "nothing queued", project, sha });
      return json(409, {
        error: "another claimant took this departure", refused: true, scope: "deploy-queue",
        reason: `${project}@${sha.slice(0, 8)} is ${row.status}${row.claimed_by ? ` on ${row.claimed_by}` : ""}`,
        deploy: row,
      });
    },
  ],

  // Depart. `departed_at` is stamped ONLY here, and only from a row that is
  // still `claimed` — so a train that dies between the claim and the verify
  // leaves a row nothing has marked as delivered, and the age re-offer above
  // hands it to the next tick.
  //
  // `queued` is the RELEASE: a departure whose hook never arrived puts its
  // batch back exactly as the file store keeps its files today, with the
  // claimant cleared so the next train does not read the row as in flight.
  [
    "POST", "/api/deploy-queue/depart",
    async ({ env, t, body }) => {
      const project = laneName(body.project);
      const sha = deploySha(body.sha);
      const status = String(body.status || "");
      if (!project || !sha) return json(400, { error: "project and sha are required" });
      if (status !== "done" && status !== "failed" && status !== "queued") {
        return json(400, { error: "status must be one of done, failed, queued" });
      }
      const moved = await env.DB.prepare(
        `UPDATE deploy_queue SET status=?3,
           departed_at=CASE WHEN ?3='queued' THEN NULL ELSE ?4 END,
           claimed_by=CASE WHEN ?3='queued' THEN NULL ELSE claimed_by END,
           reason=?5, updated_at=?4
         WHERE project=?1 AND sha=?2 AND status='claimed'`
      ).bind(project, sha, status, t, str(body.reason, 500)).run();
      const row = await env.DB.prepare(
        "SELECT * FROM deploy_queue WHERE project=?1 AND sha=?2").bind(project, sha).first();
      if (moved.meta.changes) return json(200, { deploy: row, as_of: t });
      if (!row) return json(404, { error: "nothing queued", project, sha });
      return json(409, {
        error: `departure refused: row is ${row.status}, not claimed`,
        refused: true, scope: "deploy-queue", deploy: row,
      });
    },
  ],
];
