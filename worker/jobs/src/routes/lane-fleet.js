// lane-fleet routes — the lane-run Fly fleet (BH-6126, BH-6047 part 3 of 5).
//
// bin/lane-fleet.sh (hub, every minute) starts and stops machines in the Fly
// app `lane-run`, which run bin/lane-run-worker.sh. These routes are its
// record, keyed on the Fly machine id (table lane_machines, schema.d/0022):
//
//   GET  /api/lane-fleet/machines  the starting/started rows, each with
//        in_flight (a start whose machine has made no claim yet and is
//        younger than lane_fleet.start_grace_s), busy (it holds a live
//        lane_runs claim) and idle_s, plus last_failed_at (the latest
//        failed_at of any row). The first claim by a machine since its row's
//        started_at promotes its `starting` row to `started`, in a statement
//        just before the read. A claim from an earlier life of a reused
//        machine counts for nothing: the reuse is in flight again.
//   POST /api/lane-fleet/machines  upsert one row; 201 insert, 200 update.
//        A stopped|destroyed row takes an optional stopped_at (Fly's stop
//        time, never later than now) and failed:true, which sets failed_at.
//   POST /api/lane-fleet/cost      one cost_rows row per whole machine-minute
//        up to `through`, keyed (box lane-run-<mid>, row_hash
//        lane-fleet:<mid>:<minute start>), so a replay writes nothing. The
//        lane is the lane_runs row the machine held in that minute, else
//        `lane-fleet` (an idle minute is the fleet's own cost). At most
//        COST_MINUTES_MAX rows per call; `incomplete` says the rest waits for
//        the next call, which resumes from lane_machines.costed_until.
//
// Every handler runs inside d1Guarded, so a worker whose D1 lacks the table
// answers 503 "lane_machines schema not applied" rather than a 500.

import { d1Guarded, json } from "../lib/http.js";
import { ensureColumns, leaseWon, str } from "../lib/core.js";

// The Fly machine id shape (routes/box-commands.js MACHINE_RE).
const MACHINE_RE = /^[0-9a-z]{8,32}$/;
const STATES = ["starting", "started", "stopped", "destroyed"];
const KIND_RE = /^[a-z0-9-]{1,32}$/;
const ISO_RE = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z$/;
const MINUTE_RE = /^\d{4}-\d\d-\d\dT\d\d:\d\d:00Z$/;
const LIST_MAX = 500;
const COST_MINUTES_MAX = 120;
const RUNS_MAX = 500;
// The settings row and its documented code fallback.
const GRACE_KEY = "lane_fleet.start_grace_s";
const GRACE_DEFAULT_S = 180;
const GRACE_MIN_S = 30;
const GRACE_MAX_S = 3600;
const IDLE_LANE = "lane-fleet";

const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
const floorMinute = (ms) => Math.floor(ms / 60000) * 60000;
const ceilMinute = (ms) => Math.ceil(ms / 60000) * 60000;

async function graceSeconds(env) {
  const r = await env.DB.prepare("SELECT value FROM settings WHERE key=?1").bind(GRACE_KEY).first();
  const s = r ? String(r.value).trim() : "";
  const n = /^\d+$/.test(s) ? Number(s) : NaN;
  return n >= GRACE_MIN_S && n <= GRACE_MAX_S ? n : GRACE_DEFAULT_S;
}

// An optional positive integer field: { v } (null when absent) or { err }.
function intField(body, k, max) {
  const v = body[k];
  if (v === undefined || v === null) return { v: null };
  if (!Number.isInteger(v) || v < 1 || v > max) return { err: `${k} must be an integer 1..${max}` };
  return { v };
}

function kindField(body) {
  const v = body.cpu_kind;
  if (v === undefined || v === null) return { v: null };
  if (typeof v !== "string" || !KIND_RE.test(v)) return { err: "cpu_kind must match [a-z0-9-]{1,32}" };
  return { v };
}

// Busy = a live claim; claimed = a claim since this start; last = the latest activity.
const MACHINES_SQL = `SELECT m.machine_id, m.state, m.started_at, m.cpu_kind, m.cpus, m.memory_mb, m.costed_until,
    EXISTS (SELECT 1 FROM lane_runs r WHERE r.claimed_by=m.machine_id AND r.status='claimed' AND r.lease_until >= ?1) AS busy,
    EXISTS (SELECT 1 FROM lane_runs r WHERE r.claimed_by=m.machine_id AND r.claimed_at >= m.started_at) AS claimed,
    (SELECT MAX(COALESCE(r.finished_at, r.heartbeat_at, r.claimed_at)) FROM lane_runs r WHERE r.claimed_by=m.machine_id) AS last_at
  FROM lane_machines m WHERE m.state IN ('starting','started')
  ORDER BY m.started_at, m.machine_id LIMIT ${LIST_MAX + 1}`;

const PROMOTE_SQL = `UPDATE lane_machines SET state='started', updated_at=?1
  WHERE state='starting' AND EXISTS (SELECT 1 FROM lane_runs r
    WHERE r.claimed_by=lane_machines.machine_id AND r.claimed_at >= lane_machines.started_at)`;

// The lane a machine held in [startMs, endMs): the latest claim that covers it.
// A run that is no longer claimed and has no finished_at ends at its last
// heartbeat (it died or was swept), never "still open".
function laneFor(runs, startMs, endMs) {
  for (const r of runs) {
    const c = Date.parse(r.claimed_at);
    if (!(c < endMs)) continue;
    const end = r.finished_at || (r.status === "claimed" ? null : (r.heartbeat_at || r.claimed_at));
    if (end !== null && Date.parse(end) < startMs) continue;
    return r;
  }
  return null;
}

export const routes = [
  [
    "GET", "/api/lane-fleet/machines",
    ({ env, t }) => d1Guarded("lane_machines", async () => {
      const grace = await graceSeconds(env);
      await env.DB.prepare(PROMOTE_SQL).bind(t).run();
      const rows = (await env.DB.prepare(MACHINES_SQL).bind(t).all()).results || [];
      const now = Date.parse(t);
      const machines = rows.slice(0, LIST_MAX).map((r) => {
        const busy = Number(r.busy) === 1;
        const started = Date.parse(r.started_at);
        const last = r.last_at ? Math.max(started, Date.parse(r.last_at)) : started;
        return {
          machine_id: r.machine_id,
          state: r.state,
          started_at: r.started_at,
          cpu_kind: r.cpu_kind, cpus: r.cpus, memory_mb: r.memory_mb,
          costed_until: r.costed_until,
          in_flight: r.state === "starting" && Number(r.claimed) === 0 && now - started < grace * 1000,
          busy,
          idle_s: busy ? 0 : Math.max(0, Math.floor((now - last) / 1000)),
        };
      });
      const f = await env.DB.prepare("SELECT MAX(failed_at) AS at FROM lane_machines").first();
      return json(200, {
        machines, start_grace_s: grace, last_failed_at: (f && f.at) || null, incomplete: rows.length > LIST_MAX, as_of: t,
      });
    }),
  ],

  [
    "POST", "/api/lane-fleet/machines",
    ({ env, t, body }) => d1Guarded("lane_machines", async () => {
      const mid = typeof body.machine_id === "string" ? body.machine_id : "";
      if (!MACHINE_RE.test(mid)) return json(400, { error: "machine_id must match ^[0-9a-z]{8,32}$" });
      const state = body.state;
      if (!STATES.includes(state)) return json(400, { error: `state must be one of ${STATES.join("|")}` });
      const kind = kindField(body);
      const cpus = intField(body, "cpus", 64);
      const mem = intField(body, "memory_mb", 262144);
      for (const f of [kind, cpus, mem]) if (f.err) return json(400, { error: f.err });
      const live = state === "starting" || state === "started";
      let startedAt = t;
      if (body.started_at !== undefined && body.started_at !== null) {
        if (!live) return json(400, { error: "started_at is only for state starting|started" });
        if (typeof body.started_at !== "string" || !ISO_RE.test(body.started_at)) {
          return json(400, { error: "started_at must be ISO YYYY-MM-DDTHH:MM:SS[.fff]Z" });
        }
        startedAt = iso(Date.parse(body.started_at));
      }
      let stoppedAt = t;
      if (body.stopped_at !== undefined && body.stopped_at !== null) {
        if (live) return json(400, { error: "stopped_at is only for state stopped|destroyed" });
        if (typeof body.stopped_at !== "string" || !ISO_RE.test(body.stopped_at)) {
          return json(400, { error: "stopped_at must be ISO YYYY-MM-DDTHH:MM:SS[.fff]Z" });
        }
        stoppedAt = iso(Math.min(Date.parse(body.stopped_at), Date.parse(t)));
      }
      if (body.failed !== undefined && body.failed !== null && typeof body.failed !== "boolean") {
        return json(400, { error: "failed must be a boolean" });
      }
      if (body.failed === true && live) return json(400, { error: "failed is only for state stopped|destroyed" });
      const failedAt = body.failed === true ? t : null;
      const actor = str(body.box, 64) || "lane-fleet";
      const ins = await env.DB.prepare(
        `INSERT OR IGNORE INTO lane_machines (machine_id, state, cpu_kind, cpus, memory_mb, started_at, stopped_at, updated_at, actor, failed_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)`
      ).bind(mid, state, kind.v, cpus.v, mem.v, startedAt, live ? null : stoppedAt, t, actor, failedAt).run();
      if (leaseWon(ins)) return json(201, { machine_id: mid, state, started_at: startedAt, as_of: t });
      if (live) {
        await env.DB.prepare(
          `UPDATE lane_machines SET state=?2, started_at=?3, stopped_at=NULL, cpu_kind=COALESCE(?4,cpu_kind),
             cpus=COALESCE(?5,cpus), memory_mb=COALESCE(?6,memory_mb), updated_at=?7, actor=?8 WHERE machine_id=?1`
        ).bind(mid, state, startedAt, kind.v, cpus.v, mem.v, t, actor).run();
      } else {
        await env.DB.prepare(
          `UPDATE lane_machines SET state=?2, stopped_at=?3, cpu_kind=COALESCE(?4,cpu_kind),
             cpus=COALESCE(?5,cpus), memory_mb=COALESCE(?6,memory_mb), updated_at=?7, actor=?8,
             failed_at=COALESCE(?9,failed_at) WHERE machine_id=?1`
        ).bind(mid, state, stoppedAt, kind.v, cpus.v, mem.v, t, actor, failedAt).run();
      }
      return json(200, { machine_id: mid, state, as_of: t });
    }),
  ],

  [
    "POST", "/api/lane-fleet/cost",
    ({ env, t, body }) => d1Guarded("lane_machines", async () => {
      const mid = typeof body.machine_id === "string" ? body.machine_id : "";
      if (!MACHINE_RE.test(mid)) return json(400, { error: "machine_id must match ^[0-9a-z]{8,32}$" });
      if (typeof body.through !== "string" || !MINUTE_RE.test(body.through)) {
        return json(400, { error: "through must be an ISO minute YYYY-MM-DDTHH:MM:00Z" });
      }
      const through = Date.parse(body.through);
      if (!Number.isFinite(through)) return json(400, { error: "through is not a date" });
      // A box clock ahead of the worker must not bill minutes that have not happened.
      if (through > floorMinute(Date.parse(t)) + 60000) return json(400, { error: "through is in the future", as_of: t });
      const rate = body.usd_per_s;
      if (rate !== null && !(typeof rate === "number" && Number.isFinite(rate) && rate >= 0)) {
        return json(400, { error: "usd_per_s must be null or a finite number >= 0" });
      }
      const kind = kindField(body);
      const cpus = intField(body, "cpus", 64);
      const mem = intField(body, "memory_mb", 262144);
      for (const f of [kind, cpus, mem]) if (f.err) return json(400, { error: f.err });

      const m = await env.DB.prepare("SELECT * FROM lane_machines WHERE machine_id=?1").bind(mid).first();
      if (!m) return json(404, { error: "unknown machine", machine_id: mid });
      // Minutes run from the later of costed_until and the start's own minute:
      // a reused machine is not billed for the time it sat stopped.
      let from = floorMinute(Date.parse(m.started_at));
      if (m.costed_until && Date.parse(m.costed_until) > from) from = Date.parse(m.costed_until);
      let to = through;
      if ((m.state === "stopped" || m.state === "destroyed") && m.stopped_at) {
        to = Math.min(to, ceilMinute(Date.parse(m.stopped_at)));
      }
      const total = to > from ? Math.floor((to - from) / 60000) : 0;
      const n = Math.min(total, COST_MINUTES_MAX);
      if (n === 0) {
        return json(200, { written: 0, already: 0, costed_until: m.costed_until, incomplete: false, as_of: t });
      }
      const end = from + n * 60000;
      // sql-ident-ok: RUNS_MAX is a module number const
      const runs = (await env.DB.prepare(
        `SELECT lane, project, status, claimed_at, finished_at, heartbeat_at FROM lane_runs
          WHERE claimed_by=?1 AND claimed_at < ?2 AND (finished_at IS NULL OR finished_at >= ?3)
          ORDER BY claimed_at DESC, id DESC LIMIT ${RUNS_MAX}`
      ).bind(mid, iso(end), iso(from)).all()).results || [];

      await ensureColumns(env, "cost_rows");
      const k = kind.v || m.cpu_kind || "unknown";
      const c = cpus.v || m.cpus || 0;
      const mb = mem.v || m.memory_mb || 0;
      const model = `${k}-${c}x-${mb}mb`;
      const cost = rate === null ? null : Math.round(60 * rate * 1e9) / 1e9;
      const note = rate === null ? `UNPRICED:fly-size-unknown:${mid}` : `fly:${mid}`;
      const box = `lane-run-${mid}`;
      const stmts = [];
      for (let i = 0; i < n; i++) {
        const s = from + i * 60000;
        const run = laneFor(runs, s, s + 60000);
        stmts.push(env.DB.prepare(
          `INSERT OR IGNORE INTO cost_rows (box, row_hash, line_no, ts, host, project, stage, runner, model, rc,
             duration_s, input_toks, output_toks, cache_read, cache_write, cost_usd, billing_mode, row_source,
             note, inserted_at, lane_id)
           VALUES (?1,?2,?3,?4,?5,?6,'infra','fly',?7,0,60,0,0,0,0,?8,'metered','fly-machine',?9,?10,?11)`
        ).bind(box, `lane-fleet:${mid}:${iso(s)}`, Math.floor(s / 60000), iso(s + 60000), mid,
          run ? run.project : null, model, cost, note, t, run ? run.lane : IDLE_LANE));
      }
      stmts.push(env.DB.prepare(
        "UPDATE lane_machines SET costed_until=?2, updated_at=?3 WHERE machine_id=?1 AND (costed_until IS NULL OR costed_until < ?2)"
      ).bind(mid, iso(end), t));
      const res = await env.DB.batch(stmts);
      const written = res.slice(0, n).reduce((a, r) => a + ((r && r.meta && Number(r.meta.changes)) || 0), 0);
      return json(200, {
        written, already: n - written, costed_until: iso(end), incomplete: total > n, as_of: t,
      });
    }),
  ],
];
