// docker-pool routes — the claim lease of a pull-mode Docker host (BH-7300,
// slice C0). A named box (a local Docker host, not a Fly machine) claims ONE
// queued target='fly' build_queue row by key, beats its lease, and releases
// it. A box that stops beating loses the row at the next sweep, minutes after
// lease_until, not after the watchdog's 6-hour stale-claim release. Contract
// and knobs: docs/notes/2026-10-17-BH-7300-docker-pool-lease.md. Shell client:
// bin/lib/docker-pool.sh.
//
// POST /api/docker-pool/claim {project, key, box}
//   The key is required: the hub pool's gates (HOLD, After:, spawn cap) run
//   before a key is named, so there is no "oldest row" claim here. kill=1 ->
//   409 killed; max 0 -> 409 off; both write nothing. Then the sweep runs, and
//   ONE batch claims the row (only while it is queued, target='fly', and the
//   box holds fewer than max active leases) and inserts the active lease.
//   200 {claimed:true, queued:{ticket_key, ticket_id, attempt}, lease_until}.
//   A refusal: 404 nothing queued, or 409 {refused:true, reason} with reason
//   not_pool | lost | full.
// POST /api/docker-pool/heartbeat {project, key, box}
//   Extends the box's live lease while the row is still claimed by the box at
//   the lease's claimed_at. 409 {error:'lost', reason} with reason no_lease |
//   expired | not_claimer | row_moved writes nothing. kill=1 ends the lease
//   `killed` and puts the row back on the queue, 409 killed.
// POST /api/docker-pool/release {project, key, box, status, reason?}
//   status=queued (the SIGTERM hand-off) requeues the row and ends the lease
//   `released`; status=done ends the lease `done` and leaves the row to the
//   build wrapper's queue_done. No live lease of this box: 409 lost.
// POST /api/docker-pool/sweep
//   At most SWEEP_CAP active leases past lease_until: each row still claimed
//   by its lease goes back on the queue, and each lease ends `expired`, in ONE
//   batch. {expired:[{project,key,box,requeued}], requeued, backlog}.
//
// The clock is the worker's `t`; a box never sends a time. `attempt` is never
// changed here, the same as the watchdog's queue_release.
import { d1Guarded, json } from "../lib/http.js";
import { isoPlusSeconds, laneName } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";

export const SWEEP_CAP = 50;
export const MAX_CONCURRENT_CAP = 64;
// The settings rows and their documented code fallbacks.
const MAX_KEY = "docker_pool.max_concurrent";
const KILL_KEY = "docker_pool.kill";
const LEASE = { key: "docker_pool.lease_s", def: 300, min: 60, max: 3600 };

// Exported so test/docker-pool.bh-7300.test.js explains the exact statements.
// ?1 project, ?2 key, ?3 box, ?4 t unless a statement says otherwise.
//
// ORPHAN_END (?1 project, ?2 key, ?3 t): an active lease on a row that is back
// on the queue (the watchdog's 360-min release) no longer holds anything. It
// ends here, before the claim, so the partial unique index never refuses the
// new lease.
export const ORPHAN_END_SQL = `UPDATE docker_pool_leases SET status='expired', ended_at=?3, end_reason='row was requeued outside the lease'
 WHERE project=?1 AND ticket_key=?2 AND status='active'
   AND EXISTS (SELECT 1 FROM build_queue b WHERE b.project=?1 AND b.ticket_key=?2 AND b.status='queued')`;
// ?5 max. The count is inside the CAS, so two claims by one box cannot both
// pass the cap. It is a scalar over idx_docker_pool_leases_box, run once.
export const CLAIM_SQL = `UPDATE build_queue SET status='claimed', claimed_by=?3, claimed_at=?4, updated_at=?4
 WHERE project=?1 AND ticket_key=?2 AND status='queued' AND target='fly'
   AND (SELECT COUNT(*) FROM docker_pool_leases WHERE box=?3 AND status='active') < ?5`;
// ?5 lease_until. Inserts only for the claim CLAIM_SQL just made (same box,
// same claimed_at) and only while no lease of the key is live.
export const LEASE_INSERT_SQL = `INSERT INTO docker_pool_leases (project, ticket_key, box, status, claimed_at, heartbeat_at, lease_until)
 SELECT project, ticket_key, ?3, 'active', ?4, ?4, ?5 FROM build_queue
 WHERE project=?1 AND ticket_key=?2 AND status='claimed' AND claimed_by=?3 AND claimed_at=?4
   AND NOT EXISTS (SELECT 1 FROM docker_pool_leases l WHERE l.project=?1 AND l.ticket_key=?2 AND l.status='active')`;
const ROW_SQL = "SELECT ticket_key, ticket_id, attempt, status, target FROM build_queue WHERE project=?1 AND ticket_key=?2";
// ?5 lease_until. lease_until == t is still live.
export const HEARTBEAT_SQL = `UPDATE docker_pool_leases SET heartbeat_at=?4, lease_until=?5
 WHERE project=?1 AND ticket_key=?2 AND box=?3 AND status='active' AND lease_until >= ?4
   AND EXISTS (SELECT 1 FROM build_queue b WHERE b.project=?1 AND b.ticket_key=?2 AND b.status='claimed'
               AND b.claimed_by=?3 AND b.claimed_at=docker_pool_leases.claimed_at)`;
const LIVE_LEASE_SQL = "SELECT box, lease_until FROM docker_pool_leases WHERE project=?1 AND ticket_key=?2 AND status='active'";
// ?4 reason, ?5 t. Requeues the row only while it is the claim of this box's
// live lease. Run BEFORE END_LEASE_SQL in the same batch.
export const REQUEUE_SQL = `UPDATE build_queue SET status='queued', claimed_by=NULL, claimed_at=NULL, reason=?4, updated_at=?5
 WHERE project=?1 AND ticket_key=?2 AND status='claimed' AND claimed_by=?3
   AND claimed_at=(SELECT l.claimed_at FROM docker_pool_leases l WHERE l.project=?1 AND l.ticket_key=?2 AND l.box=?3 AND l.status='active')`;
// ?4 the end status, ?5 t, ?6 reason.
export const END_LEASE_SQL = `UPDATE docker_pool_leases SET status=?4, ended_at=?5, end_reason=?6
 WHERE project=?1 AND ticket_key=?2 AND box=?3 AND status='active'`;
// ?1 t, ?2 limit.
export const SWEEP_SELECT_SQL = `SELECT id, project, ticket_key, box FROM docker_pool_leases
 WHERE status='active' AND lease_until < ?1 ORDER BY lease_until LIMIT ?2`;
// ?1 JSON ids, ?2 t. The requeue runs first: the lease still reads `active`.
// claimed_at binds it to the exact claim, so a newer claim of the same key by
// the same box is never touched by an old lease. Not correlated: the lease ids
// (at most SWEEP_CAP) drive primary-key probes of build_queue.
export const SWEEP_REQUEUE_SQL = `UPDATE build_queue SET status='queued', claimed_by=NULL, claimed_at=NULL,
   reason='docker-pool lease of ' || claimed_by || ' expired', updated_at=?2
 WHERE status='claimed' AND (project, ticket_key, claimed_by, claimed_at) IN (
   SELECT l.project, l.ticket_key, l.box, l.claimed_at FROM docker_pool_leases l
   WHERE l.id IN (SELECT value FROM json_each(?1)) AND l.status='active' AND l.lease_until < ?2)`;
export const SWEEP_END_SQL = `UPDATE docker_pool_leases SET status='expired', ended_at=?2, end_reason='lease expired'
 WHERE id IN (SELECT value FROM json_each(?1)) AND status='active' AND lease_until < ?2`;
// The leases this sweep ended, and whether each row went back on the queue.
export const SWEEP_READ_SQL = `SELECT l.project, l.ticket_key, l.box,
   CASE WHEN b.status='queued' AND b.updated_at=?2 AND b.reason='docker-pool lease of ' || l.box || ' expired' THEN 1 ELSE 0 END AS requeued
 FROM docker_pool_leases l LEFT JOIN build_queue b ON b.project=l.project AND b.ticket_key=l.ticket_key
 WHERE l.id IN (SELECT value FROM json_each(?1)) AND l.status='expired' AND l.ended_at=?2
 ORDER BY l.id`;

const changes = (r) => Number((r && r.meta && r.meta.changes) || 0);

// The max for this box: its own row when it exists, else the fleet row, else
// 0. A value that is not an integer in [0, 64] is 0 (off), never a guess.
export function maxConcurrent(byKey, box) {
  const row = byKey.get(`${MAX_KEY}.${box}`) || byKey.get(MAX_KEY);
  const s = row ? String(row.value).trim() : "";
  if (!/^\d+$/.test(s)) return 0;
  const n = Number(s);
  return n <= MAX_CONCURRENT_CAP ? n : 0;
}
const killed = (byKey) => { const r = byKey.get(KILL_KEY); return !!r && String(r.value).trim() === "1"; };
function leaseSeconds(byKey) {
  const r = byKey.get(LEASE.key);
  const s = r ? String(r.value).trim() : "";
  const n = /^\d+$/.test(s) ? Number(s) : NaN;
  return n >= LEASE.min && n <= LEASE.max ? n : LEASE.def;
}

// The validated {project, key, box}, or { error } for a 400.
function parse(raw) {
  const body = raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
  const project = laneName(body.project), key = laneName(body.key), box = laneName(body.box);
  if (!project || !key || !box) return { error: "project, key and box are required and must match [A-Za-z0-9._-]{1,64}" };
  return { project, key, box };
}

// One sweep pass: -> { expired, requeued, backlog }. Shared by the sweep route
// and the claim, which sweeps first so a dead lease frees its slot.
async function sweep(env, t) {
  const due = (await env.DB.prepare(SWEEP_SELECT_SQL).bind(t, SWEEP_CAP).all()).results || [];
  if (due.length === 0) return { expired: [], requeued: 0, backlog: false };
  const ids = JSON.stringify(due.map((r) => r.id));
  const [rq, , rd] = await env.DB.batch([
    env.DB.prepare(SWEEP_REQUEUE_SQL).bind(ids, t),
    env.DB.prepare(SWEEP_END_SQL).bind(ids, t),
    env.DB.prepare(SWEEP_READ_SQL).bind(ids, t),
  ]);
  const expired = (rd.results || []).map((r) => ({ project: r.project, key: r.ticket_key, box: r.box, requeued: Number(r.requeued) === 1 }));
  return { expired, requeued: changes(rq), backlog: due.length === SWEEP_CAP };
}

const refuse = (reason, extra = {}) => json(409, { error: "refused", refused: true, scope: "docker-pool", reason, ...extra });
const lost = (reason, t) => json(409, { error: "lost", reason, as_of: t });

export const routes = [
  [
    "POST", "/api/docker-pool/claim",
    ({ env, t, body }) => d1Guarded("docker_pool_leases", async () => {
      const q = parse(body);
      if (q.error) return json(400, { error: q.error });
      const { byKey } = await settingsRows(env);
      if (killed(byKey)) return refuse("killed");
      const max = maxConcurrent(byKey, q.box);
      if (max === 0) return refuse("off");
      await sweep(env, t);
      const until = isoPlusSeconds(t, leaseSeconds(byKey));
      const [, took, ins, rd] = await env.DB.batch([
        env.DB.prepare(ORPHAN_END_SQL).bind(q.project, q.key, t),
        env.DB.prepare(CLAIM_SQL).bind(q.project, q.key, q.box, t, max),
        env.DB.prepare(LEASE_INSERT_SQL).bind(q.project, q.key, q.box, t, until),
        env.DB.prepare(ROW_SQL).bind(q.project, q.key),
      ]);
      const row = (rd.results || [])[0] || null;
      if (changes(took) === 1 && changes(ins) === 1) {
        return json(200, {
          claimed: true, queued: { ticket_key: row.ticket_key, ticket_id: row.ticket_id, attempt: Number(row.attempt) },
          lease_until: until, as_of: t,
        });
      }
      if (changes(took) === 1) {
        // Claimed with no lease: hand the row straight back, so no claim lives
        // without a lease. Not reachable while ORPHAN_END runs first.
        await env.DB.prepare(
          "UPDATE build_queue SET status='queued', claimed_by=NULL, claimed_at=NULL, updated_at=?4 WHERE project=?1 AND ticket_key=?2 AND status='claimed' AND claimed_by=?3 AND claimed_at=?4"
        ).bind(q.project, q.key, q.box, t).run();
        return json(500, { error: "claim made without a lease; the row was requeued", as_of: t });
      }
      if (!row) return json(404, { error: "nothing queued", project: q.project, key: q.key });
      if (row.target !== "fly") return refuse("not_pool");
      if (row.status !== "queued") return refuse("lost");
      return refuse("full", { max });
    }),
  ],
  [
    "POST", "/api/docker-pool/heartbeat",
    ({ env, t, body }) => d1Guarded("docker_pool_leases", async () => {
      const q = parse(body);
      if (q.error) return json(400, { error: q.error });
      const { byKey } = await settingsRows(env);
      if (killed(byKey)) {
        await env.DB.batch([
          env.DB.prepare(REQUEUE_SQL).bind(q.project, q.key, q.box, "docker_pool.kill is 1", t),
          env.DB.prepare(END_LEASE_SQL).bind(q.project, q.key, q.box, "killed", t, "docker_pool.kill is 1"),
        ]);
        return refuse("killed");
      }
      const until = isoPlusSeconds(t, leaseSeconds(byKey));
      const r = await env.DB.prepare(HEARTBEAT_SQL).bind(q.project, q.key, q.box, t, until).run();
      if (changes(r) === 1) return json(200, { lease_until: until, as_of: t });
      const live = await env.DB.prepare(LIVE_LEASE_SQL).bind(q.project, q.key).first();
      if (!live) return lost("no_lease", t);
      if (live.box !== q.box) return lost("not_claimer", t);
      if (live.lease_until < t) return lost("expired", t);
      return lost("row_moved", t);
    }),
  ],
  [
    "POST", "/api/docker-pool/release",
    ({ env, t, body }) => d1Guarded("docker_pool_leases", async () => {
      const q = parse(body);
      if (q.error) return json(400, { error: q.error });
      const status = body && body.status;
      if (status !== "queued" && status !== "done") return json(400, { error: "status must be queued or done" });
      const reason = body.reason === undefined || body.reason === null ? "" : String(body.reason).slice(0, 200);
      const why = `docker-pool release by ${q.box}${reason ? `: ${reason}` : ""}`;
      const stmts = [];
      if (status === "queued") stmts.push(env.DB.prepare(REQUEUE_SQL).bind(q.project, q.key, q.box, why, t));
      stmts.push(env.DB.prepare(END_LEASE_SQL).bind(q.project, q.key, q.box, status === "queued" ? "released" : "done", t, why));
      const res = await env.DB.batch(stmts);
      if (changes(res[res.length - 1]) !== 1) return lost("no_lease", t);
      return json(200, { released: true, status, requeued: status === "queued" ? changes(res[0]) : 0, as_of: t });
    }),
  ],
  [
    "POST", "/api/docker-pool/sweep",
    ({ env, t }) => d1Guarded("docker_pool_leases", async () => json(200, { ...(await sweep(env, t)), as_of: t })),
  ],
];
