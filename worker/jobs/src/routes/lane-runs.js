// lane-runs routes — the lane-run queue (BH-6124, BH-6047 part 1 of 5).
//
// A lane placed `fly` (bin/lib/lane-placement.sh) is enqueued by pl_dispatch
// as ONE row per (lane, project); a machine running bin/lane-run-worker.sh
// claims the oldest row in ONE statement, runs it and reports its rc. The
// partial unique index lane_runs_live (schema.d/0020) is the fleet-wide
// dedupe: a second live row for the same (lane, project) cannot exist.
//
// The shape is routes/account-leases.js: validation, then one statement, so
// two machines never race a read-modify-write. Every handler runs inside
// d1Guarded, so a worker whose D1 lacks the table answers 503 "lane_runs
// schema not applied" rather than a 500.
//
// A row is `done` only through the report route, which needs the claimer's
// machine id and an integer rc. A missing rc is a 400, never a 0.
//
// The release route (BH-6495) is the SIGTERM hand-off: the claimer sets its
// row back to `queued` and keeps `attempts`, so another machine re-claims it
// and sweepDead still counts the try. The prefix read lists one lane's rows
// whose project starts with a prefix, newest first: the merge-conductor-pr
// lane keys a row as <project>.<pr>.<head12>, and the hub reads one PR's rows
// before it enqueues (bin/lib/mc/fly-workers.sh).

import { d1Guarded, json } from "../lib/http.js";
import { isoPlusSeconds, laneName, leaseWon, str } from "../lib/core.js";
import { sweepDead } from "./lane-runs-lease.js";

const ARGS_MAX = 64;
const ARG_BYTES_MAX = 4096;
const ARGS_JSON_BYTES_MAX = 16384;
const LANES_FILTER_MAX = 32;
const PROF_BYTES_MAX = 512;
const LIST_LIMIT_MAX = 50;
// The settings rows and their documented code fallbacks.
const LEASE_KEY = "lane_run.lease_s";
const LEASE_DEFAULT_S = 120;
const LEASE_MIN_S = 30;
const LEASE_MAX_S = 3600;
// args[0] is a path under the machine's own harness root, never absolute.
const CMD_RE = /^bin\/[A-Za-z0-9._/-]+$/;

const LIVE = "(status='queued' OR (status='claimed' AND lease_until < ?2))";
// Binds: ?1 machine ?2 now ?3 lease_until ?4 lanes JSON array or NULL.
const CLAIM_SQL = `UPDATE lane_runs SET status='claimed', claimed_by=?1, claimed_at=?2,
  heartbeat_at=?2, lease_until=?3, attempts=attempts+1
  WHERE id=(SELECT id FROM lane_runs WHERE ${LIVE}
            AND (?4 IS NULL OR lane IN (SELECT value FROM json_each(?4)))
            ORDER BY enqueued_at, id LIMIT 1)
    AND ${LIVE}
  RETURNING id, lane, project, args_json, attempts, lease_until`;

const bytes = (s) => new TextEncoder().encode(s).length;

// The longest prefix of s that fits in max UTF-8 bytes, cut on a character.
function utf8Slice(s, max) {
  if (bytes(s) <= max) return s;
  let out = "";
  let n = 0;
  for (const ch of s) {
    const b = bytes(ch);
    if (n + b > max) break;
    out += ch;
    n += b;
  }
  return out;
}

// { v: <args array> } or { err }.
function argsOf(v) {
  if (!Array.isArray(v) || v.length < 1 || v.length > ARGS_MAX) {
    return { err: `args must be an array of 1..${ARGS_MAX} strings` };
  }
  if (!v.every((a) => typeof a === "string" && bytes(a) <= ARG_BYTES_MAX)) {
    return { err: `every arg must be a string of at most ${ARG_BYTES_MAX} bytes` };
  }
  if (!CMD_RE.test(v[0]) || v[0].split("/").includes("..")) {
    return { err: "args[0] must be a path under bin/ (^bin/[A-Za-z0-9._/-]+$, no '..')" };
  }
  const s = JSON.stringify(v);
  if (bytes(s) > ARGS_JSON_BYTES_MAX) return { err: `args is over ${ARGS_JSON_BYTES_MAX} bytes as JSON` };
  return { v: s };
}

async function leaseSeconds(env) {
  const r = await env.DB.prepare("SELECT value FROM settings WHERE key=?1").bind(LEASE_KEY).first();
  const s = r ? String(r.value).trim() : "";
  const n = /^\d+$/.test(s) ? Number(s) : NaN;
  return n >= LEASE_MIN_S && n <= LEASE_MAX_S ? n : LEASE_DEFAULT_S;
}

const NAME_ERR = "must match [A-Za-z0-9._-]{1,64}";

export const routes = [
  [
    "POST", "/api/lane-runs",
    ({ env, t, body }) => d1Guarded("lane_runs", async () => {
      const lane = laneName(body.lane);
      const project = laneName(body.project);
      if (!lane || !project) return json(400, { error: `lane and project are required and ${NAME_ERR}` });
      const a = argsOf(body.args);
      if (a.err) return json(400, { error: a.err });
      const r = await env.DB.prepare(
        "INSERT OR IGNORE INTO lane_runs (lane, project, args_json, enqueued_at, enqueued_by, status) VALUES (?1,?2,?3,?4,?5,'queued')"
      ).bind(lane, project, a.v, t, str(body.box, 64)).run();
      if (leaseWon(r)) return json(201, { id: Number(r.meta.last_row_id), lane, project, as_of: t });
      const live = await env.DB.prepare(
        "SELECT id FROM lane_runs WHERE lane=?1 AND project=?2 AND status IN ('queued','claimed')"
      ).bind(lane, project).first();
      return json(409, { error: "already_live", id: live ? Number(live.id) : null, lane, project, as_of: t });
    }),
  ],

  [
    "POST", "/api/lane-runs/claim",
    ({ env, t, body }) => d1Guarded("lane_runs", async () => {
      const machine = laneName(body.machine);
      if (!machine) return json(400, { error: `machine is required and ${NAME_ERR}` });
      let lanes = null;
      if (body.lanes !== undefined && body.lanes !== null) {
        const l = body.lanes;
        if (!Array.isArray(l) || l.length > LANES_FILTER_MAX || !l.every((x) => laneName(x) === x)) {
          return json(400, { error: `lanes must be an array of at most ${LANES_FILTER_MAX} lane names` });
        }
        lanes = JSON.stringify(l);
      }
      await sweepDead(env, t);
      const lease = isoPlusSeconds(t, await leaseSeconds(env));
      const row = await env.DB.prepare(CLAIM_SQL).bind(machine, t, lease, lanes).first();
      if (!row) return new Response(null, { status: 204 });
      return json(200, {
        id: Number(row.id), lane: row.lane, project: row.project, args: JSON.parse(row.args_json),
        attempts: Number(row.attempts), lease_until: row.lease_until,
      });
    }),
  ],

  [
    "POST", /^\/api\/lane-runs\/(\d+)\/report$/,
    ({ env, t, body, m }) => d1Guarded("lane_runs", async () => {
      const id = Number(m[1]);
      const machine = laneName(body.machine);
      if (!machine) return json(400, { error: `machine is required and ${NAME_ERR}` });
      const rc = body.rc;
      if (!Number.isInteger(rc) || rc < 0 || rc > 255) return json(400, { error: "rc must be an integer 0..255" });
      const prof = typeof body.prof === "string" && body.prof !== "" ? utf8Slice(body.prof, PROF_BYTES_MAX) : null;
      const r = await env.DB.prepare(
        "UPDATE lane_runs SET status='done', rc=?1, prof_line=?2, finished_at=?3 WHERE id=?4 AND status='claimed' AND claimed_by=?5"
      ).bind(rc, prof, t, id, machine).run();
      if (leaseWon(r)) return json(200, { id, status: "done", rc, as_of: t });
      const row = await env.DB.prepare("SELECT status, claimed_by, rc FROM lane_runs WHERE id=?1").bind(id).first();
      if (!row) return json(404, { error: "no such lane run", id });
      if (row.status === "queued" || row.status === "died") {
        return json(409, { error: "not reported", reason: "not_claimed", id, status: row.status });
      }
      if (row.claimed_by !== machine) {
        return json(409, { error: "not reported", reason: "not_claimer", id, status: row.status });
      }
      if (Number(row.rc) === rc) return json(200, { id, status: "done", rc, replay: true, as_of: t });
      return json(409, { error: "not reported", reason: "rc_mismatch", id, status: row.status, rc: Number(row.rc) });
    }),
  ],

  [
    "POST", /^\/api\/lane-runs\/(\d+)\/release$/,
    ({ env, t, body, m }) => d1Guarded("lane_runs", async () => {
      const id = Number(m[1]);
      const machine = laneName(body.machine);
      if (!machine) return json(400, { error: `machine is required and ${NAME_ERR}` });
      const r = await env.DB.prepare(
        `UPDATE lane_runs SET status='queued', claimed_by=NULL, claimed_at=NULL, lease_until=NULL, heartbeat_at=NULL
         WHERE id=?1 AND status='claimed' AND claimed_by=?2`
      ).bind(id, machine).run();
      const row = await env.DB.prepare("SELECT status, claimed_by, attempts FROM lane_runs WHERE id=?1").bind(id).first();
      if (leaseWon(r)) return json(200, { id, status: "queued", attempts: row ? Number(row.attempts) : null, as_of: t });
      if (!row) return json(404, { error: "no such lane run", id });
      if (row.status !== "claimed") {
        return json(409, { error: "not released", reason: "not_claimed", id, status: row.status });
      }
      return json(409, { error: "not released", reason: "not_claimer", id, status: row.status });
    }),
  ],

  [
    // Its own path (BH-6495 fix round): GET /api/lane-runs is the metrics list
    // (lane-runs-metrics.js, BH-6127). Registered here as well, the first entry
    // shadowed the other and the route table refused the duplicate.
    "GET", "/api/lane-runs/by-prefix",
    ({ env, url, t }) => d1Guarded("lane_runs", async () => {
      const q = url.searchParams;
      const lane = laneName(q.get("lane"));
      const prefix = laneName(q.get("project_prefix"));
      if (!lane || !prefix) return json(400, { error: `lane and project_prefix are required and ${NAME_ERR}` });
      const live = q.get("live");
      if (live !== null && live !== "1") return json(400, { error: "live must be 1 when present" });
      const rawLimit = q.get("limit");
      let limit = LIST_LIMIT_MAX;
      if (rawLimit !== null) {
        limit = /^\d+$/.test(rawLimit) ? Number(rawLimit) : NaN;
        if (!(limit >= 1 && limit <= LIST_LIMIT_MAX)) return json(400, { error: `limit must be 1..${LIST_LIMIT_MAX}` });
      }
      // A range on project, not LIKE: `_` is a legal name character and a LIKE
      // wildcard. Every legal character sorts below '~', so [prefix, prefix~)
      // is exactly the names that start with prefix.
      const rows = (await env.DB.prepare(
        `SELECT id, lane, project, status, claimed_by, attempts, rc, prof_line, enqueued_at, finished_at
         FROM lane_runs WHERE lane=?1 AND project >= ?2 AND project < ?3
           AND (?4 IS NULL OR status IN ('queued','claimed'))
         ORDER BY id DESC LIMIT ?5`
      ).bind(lane, prefix, `${prefix}~`, live, limit + 1).all()).results || [];
      const truncated = rows.length > limit;
      return json(200, {
        rows: rows.slice(0, limit).map((r) => ({
          id: Number(r.id), lane: r.lane, project: r.project, status: r.status, claimed_by: r.claimed_by,
          attempts: Number(r.attempts), rc: r.rc === null ? null : Number(r.rc), prof_line: r.prof_line,
          enqueued_at: r.enqueued_at, finished_at: r.finished_at,
        })),
        truncated, as_of: t,
      });
    }),
  ],

  [
    "GET", "/api/lane-runs/stats",
    ({ env, url, t }) => d1Guarded("lane_runs", async () => {
      const raw = url.searchParams.get("lane");
      const lane = laneName(raw);
      if (raw !== null && raw !== "" && !lane) return json(400, { error: `lane ${NAME_ERR}` });
      const rows = (await env.DB.prepare(
        `SELECT lane,
           SUM(status='queued') AS queued, SUM(status='claimed') AS claimed,
           SUM(status='done') AS done, SUM(status='died') AS died,
           MIN(CASE WHEN status='queued' THEN enqueued_at END) AS oldest_queued,
           COUNT(DISTINCT CASE WHEN status='claimed' THEN claimed_by END) AS live_claimers
         FROM lane_runs WHERE (?1 IS NULL OR lane=?1) GROUP BY lane ORDER BY lane LIMIT 500`
      ).bind(lane || null).all()).results || [];
      const now = Date.parse(t);
      const lanes = rows.map((r) => ({
        lane: r.lane,
        queued: Number(r.queued), claimed: Number(r.claimed), done: Number(r.done), died: Number(r.died),
        oldest_queued_wait_s: r.oldest_queued ? Math.max(0, Math.floor((now - Date.parse(r.oldest_queued)) / 1000)) : null,
        live_claimers: Number(r.live_claimers),
      }));
      return json(200, { lanes, as_of: t });
    }),
  ],
];
