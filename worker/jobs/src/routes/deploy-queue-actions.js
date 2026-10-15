// deploy-queue-actions routes — BH-2510: the Project page's QUEUES panel action
// on one deploy-queue row. BH-3150 shipped the stub; BH-3152 (BH-2510.2) ships
// RELEASE.
//
// RELEASE hands a claimed departure whose train died back to the queue: the row
// goes `claimed` -> `queued` with its claimant cleared, which is exactly the
// state `POST /api/deploy-queue/depart status=queued` leaves, so the next
// train's claim CAS (`status='queued'`) takes it again. Every release carries
// one RELEASED stage event naming who did it and why. The console reaches this
// through the coord proxy, which forwards {project, sha, action, reason} and
// stamps the actor itself.
//
// BH-3154 (BH-2510.4) adds HOLD (`queued` -> `held`) and UNHOLD (`held` ->
// `queued`), the same audited CAS with verdicts HELD / UNHELD. ACTIONS is a
// plain map, and every body check below runs for each key.

import { json } from "../lib/http.js";
import { laneName, str } from "../lib/core.js";
import { sqlIdent } from "../lib/sql-ident.js";

// Copied verbatim from routes/queue.js:22, not exported from there: the sha is
// normalised ONCE and IDENTICALLY at every door to deploy_queue (D17), or a
// hold or release would miss the row the claim took.
function deploySha(v) {
  const s = String(v === undefined || v === null ? "" : v).trim().toLowerCase();
  return /^[0-9a-f]{7,64}$/.test(s) ? s : "";
}

// One audited status flip, shared by every action: `from` -> `to` on an
// undeparted row, with one `verdict` stage event naming who did it and why.
// `from`/`to` come only from the ACTIONS table below, never from the body.
async function transition({ env, t, project, sha, reason, actor }, { name, from, to, verdict, decision }) {
  const row = await env.DB.prepare(
    "SELECT * FROM deploy_queue WHERE project=?1 AND sha=?2").bind(project, sha).first();
  if (!row) return json(404, { error: "nothing queued", project, sha });
  if (row.status !== from || row.departed_at) {
    return json(409, {
      error: `${name} refused: row is ${row.status}${row.departed_at ? ", departed" : ""}`,
      refused: true, scope: "deploy-queue", deploy: row,
    });
  }

  // ONE batch, which D1 runs as one transaction. The UPDATE is a CAS on the
  // row as it was read (a claim, a re-claim or a depart in between moves
  // updated_at or status). The event lands only when THAT UPDATE changed the
  // row (changes()=1) and the row is now the one it wrote: EXISTS alone would
  // also match a same-second write that won the race.
  const jobId = `deploy-queue:${project}/${sha}`;
  const detail = JSON.stringify({ reason, from, to });
  // The three status words go into the SQL text below: one that is not a plain
  // word throws here, before any write.
  for (const w of [from, to, verdict]) sqlIdent(w);
  const res = await env.DB.batch([
    // sql-ident-ok: from/to come from the ACTIONS literals, checked by sqlIdent above
    env.DB.prepare(
      `UPDATE deploy_queue SET status='${to}', claimed_by=NULL, reason=?3, updated_at=?4
       WHERE project=?1 AND sha=?2 AND status='${from}' AND departed_at IS NULL AND updated_at=?5`
    ).bind(project, sha, reason, t, row.updated_at),
    // sql-ident-ok: verdict/to come from the ACTIONS literals, checked by sqlIdent above
    env.DB.prepare(
      `INSERT INTO stage_events (job_id, stage, verdict, actor, detail, created_at)
       SELECT ?1, 'deploy-queue', '${verdict}', ?2, ?3, ?4
       WHERE changes()=1
         AND EXISTS (SELECT 1 FROM deploy_queue WHERE project=?5 AND sha=?6 AND status='${to}' AND updated_at=?4)`
    ).bind(jobId, actor, detail, t, project, sha),
  ]);

  const now = await env.DB.prepare(
    "SELECT * FROM deploy_queue WHERE project=?1 AND sha=?2").bind(project, sha).first();
  if (!res[0] || !res[0].meta || res[0].meta.changes === 0) {
    // Lost the CAS: nothing was written, the event included.
    return json(409, { error: "deploy row moved, reload", refused: true, scope: "deploy-queue", deploy: now });
  }
  return json(200, { decision, deploy: now, actor, reason, as_of: t });
}

// RELEASE: a claimed departure whose train died goes back to the queue.
const release = (a) => transition(a,
  { name: "release", from: "claimed", to: "queued", verdict: "RELEASED", decision: "released" });

// HOLD (BH-3154): a queued departure the train must not leave with. A held row
// is invisible to the claim (it takes only `queued`) and the enqueue answers it
// `duplicate` rather than re-opening it; bin/deploy-train.sh departs nothing
// while the project has one. All of that is the ROWS path: with
// `deploy_queue_rows` off a train reads the file dir, which cannot see a hold,
// so the hold is refused rather than recorded as a promise nothing keeps. The
// truth table is the box's (_flag_on_row, bin/lib/jobs/queue.sh): exactly
// 1|on|true|yes. A missing or empty row is refused too, because it means each
// box decides from its own DEPLOY_QUEUE_ROWS env, which this worker cannot see.
const ROWS_ON = new Set(["1", "on", "true", "yes"]);
async function hold(a) {
  const v = await a.env.DB.prepare(
    "SELECT value FROM settings WHERE key='deploy_queue_rows'").first("value");
  if (!ROWS_ON.has(v)) {
    return json(409, { error: "hold refused: deploy_queue_rows is not on, trains read the file dir", refused: true, scope: "deploy-queue" });
  }
  return transition(a, { name: "hold", from: "queued", to: "held", verdict: "HELD", decision: "held" });
}

// UNHOLD: never knob-gated, so a hold can always be undone.
const unhold = (a) => transition(a,
  { name: "unhold", from: "held", to: "queued", verdict: "UNHELD", decision: "unheld" });

const ACTIONS = { release, hold, unhold };

export const routes = [
  [
    "POST", "/api/deploy-queue/action",
    async ({ env, t, body }) => {
      // Every check runs before any DB call, and none has a fallback: a
      // status flip nobody can explain, or nobody can be named for, is not audited.
      const project = laneName(body.project);
      const sha = deploySha(body.sha);
      if (!project || !sha) return json(400, { error: "project and sha are required" });
      const action = String(body.action || "");
      if (!Object.hasOwn(ACTIONS, action)) return json(400, { error: "unknown action", action });
      const reason = (str(body.reason, 500) || "").trim();
      if (!reason) return json(400, { error: "reason required" });
      const actor = (str(body.actor, 128) || "").trim();
      if (!actor) return json(400, { error: "actor required" });
      return ACTIONS[action]({ env, t, project, sha, reason, actor });
    },
  ],
];
