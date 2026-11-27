// lane-runs-metrics routes — Mission Control's lane-run views and the
// queue-wait alert (BH-6127, BH-6047 part 4 of 5). The queue itself is
// routes/lane-runs.js; this file only READS lane_runs.
//
//   GET  /api/lane-runs              newest first, capped, `truncated` at the cap
//   GET  /api/lane-runs/<id>         one run: rc, prof line, claimer, wait
//   GET  /api/lane-runs/metrics      per lane and per machine counts, queue
//                                    wait p50/max, cost per lane, hub load
//   POST /api/lane-runs/wait-tick    the alert decision, one call per hub tick
//   POST /api/lane-runs/wait-ack     stamps alerted_at after the alert is sent
//
// THE ALERT LATCH LIVES HERE, IN D1 (lane_run_wait_alerts, schema.d/0023). A
// lane is OVER when its oldest queued run waited more than
// lane_run.wait_alert_min minutes (equal is not over). Each tick counts the
// consecutive over ticks per lane and DELETES the row of every lane that is not
// over, so one under tick resets the count. A lane fires on its 2nd over tick
// and stays latched (alerted_at) until its row is deleted. alerted_at is
// written only by wait-ack, which bin/lane-run-wait-alert.sh calls AFTER the
// alert is written: a lost ack re-fires on the next tick, and lane-alert.sh's
// --id dedupes that send. When the lane drains before that next tick, the
// deleted row still resolves, because it reached FIRE_TICKS (BH-6127 refute).
//
// Every handler runs inside d1Guarded, so a D1 without lane_runs answers 503
// "lane_runs schema not applied", never an empty list.

import { d1Guarded, json } from "../lib/http.js";
import { ensureColumns, laneName, leaseWon, percentile } from "../lib/core.js";
import { parseRange, readPeriodKnobs, bucketExpr, csvResponse } from "../lib/period.js";
import {
  firstGiven, searchParam, likeClause, sortParam, orderBy, keysetClause, cursorParam,
  flagParam, formatParam, seriesParam, fillSeries, pageOut,
} from "../lib/log-query.js";

const NAME_ERR = "must match [A-Za-z0-9._-]{1,64}";
const STATUSES = ["queued", "claimed", "done", "died"];
const LIST_LIMIT_DEFAULT = 200;
const LIST_LIMIT_MAX = 500;
const HOURS_DEFAULT = 24;
const HOURS_MAX = 168;
// Rows read for the wait sample, and groups read per GROUP BY. Over either cap
// the answer says `truncated`.
const WAIT_SAMPLE_MAX = 5000;
const GROUP_MAX = 500;
// The settings row and its documented code fallback (schema.d/0023).
const WAIT_KEY = "lane_run.wait_alert_min";
const WAIT_DEFAULT_MIN = 10;
const WAIT_MAX_MIN = 1440;
const FIRE_TICKS = 2;
// The cost rows a Fly lane machine writes (BH-6126): box `lane-run-<machine>`,
// lane_id the lane, or `lane-fleet` for a minute the machine sat idle.
const COST_BOX_LIKE = "lane-run-%";
const IDLE_LANE = "lane-fleet";

const ms = (iso) => (iso ? Date.parse(iso) : NaN);
// Whole seconds from a to b, or null when either end is missing.
function secs(a, b) {
  const d = ms(b) - ms(a);
  return Number.isFinite(d) ? Math.max(0, Math.floor(d / 1000)) : null;
}
const isoAt = (msv) => new Date(msv).toISOString().replace(/\.\d{3}Z$/, "Z");
const round6 = (n) => Math.round(n * 1e6) / 1e6;

// The queue wait of one row: claimed_at - enqueued_at once claimed, now -
// enqueued_at while still queued, null otherwise.
function waitOf(r, nowIso) {
  if (r.claimed_at) return secs(r.enqueued_at, r.claimed_at);
  if (r.status === "queued") return secs(r.enqueued_at, nowIso);
  return null;
}

// An integer query param: absent or "" is the default; anything else must be an
// integer in [min, max] or the request is a 400 (never clamped).
function intParam(url, name, def, min, max) {
  const raw = url.searchParams.get(name);
  if (raw === null || raw === "") return { v: def };
  if (!/^\d+$/.test(raw) || Number(raw) < min || Number(raw) > max) {
    return { err: `${name} must be an integer ${min}..${max}` };
  }
  return { v: Number(raw) };
}

// A name filter: absent or "" is no filter; anything else must be a lane name.
function nameParam(url, name) {
  const raw = url.searchParams.get(name);
  if (raw === null || raw === "") return { v: null };
  const v = laneName(raw);
  return v ? { v } : { err: `${name} ${NAME_ERR}` };
}

// laneMetrics(rows, nowMs) — the queue-wait sample per lane. `rows` are
// lane_runs rows ({lane, status, enqueued_at, claimed_at}); a claimed row
// contributes claimed_at - enqueued_at and a queued row now - enqueued_at.
// Returns Map lane -> {wait_p50_s, wait_max_s, wait_n}.
export function laneMetrics(rows, nowMs) {
  const nowIso = isoAt(nowMs);
  const by = new Map();
  for (const r of rows) {
    const w = waitOf(r, nowIso);
    if (w === null) continue;
    if (!by.has(r.lane)) by.set(r.lane, []);
    by.get(r.lane).push(w);
  }
  const out = new Map();
  for (const [lane, xs] of by) {
    xs.sort((a, b) => a - b);
    out.set(lane, { wait_p50_s: percentile(xs, 50), wait_max_s: xs[xs.length - 1], wait_n: xs.length });
  }
  return out;
}

// waitDecision(queuedByLane, stateRows, thresholdS) — the pure half of a tick.
//   queuedByLane: [{lane, wait_s, queued}] (the oldest queued wait per lane)
//   stateRows:    lane_run_wait_alerts rows before this tick
// over:    the lanes whose wait is strictly above thresholdS
// resolve: lanes whose latch row goes away this tick AND reached FIRE_TICKS.
//   A row at FIRE_TICKS was returned in `fire`, so its alert may be open even
//   when the ack was lost (alerted_at NULL). lane-alert.sh --resolve on an id
//   that is not open is silent, so resolving it is safe.
export function waitDecision(queuedByLane, stateRows, thresholdS) {
  const over = queuedByLane.filter((q) => q.queued > 0 && q.wait_s > thresholdS);
  const overSet = new Set(over.map((q) => q.lane));
  const resolve = stateRows
    .filter((s) => !overSet.has(s.lane) && (s.alerted_at || Number(s.over_ticks) >= FIRE_TICKS))
    .map((s) => s.lane);
  return { over, resolve };
}

async function thresholdMin(env) {
  const r = await env.DB.prepare("SELECT value FROM settings WHERE key=?1").bind(WAIT_KEY).first();
  const s = r ? String(r.value).trim() : "";
  const n = /^\d+$/.test(s) ? Number(s) : NaN;
  return n >= 1 && n <= WAIT_MAX_MIN ? { min: n, source: "settings" } : { min: WAIT_DEFAULT_MIN, source: "default" };
}

function runOut(r, t) {
  return {
    id: Number(r.id), lane: r.lane, project: r.project, status: r.status,
    enqueued_at: r.enqueued_at, claimed_at: r.claimed_at || null, claimed_by: r.claimed_by || null,
    finished_at: r.finished_at || null,
    rc: r.rc === null || r.rc === undefined ? null : Number(r.rc),
    attempts: Number(r.attempts),
    wait_s: waitOf(r, t),
    run_s: r.finished_at && r.claimed_at ? secs(r.claimed_at, r.finished_at) : null,
    harness_commit: r.harness_commit || null,
  };
}

function argsOf(s) {
  try { return JSON.parse(s); } catch { return null; }
}

// ── GET /api/lane-runs with a range (BH-9308, BH-9120.4) ─────────────────
// The params below need a from/to range; without one they are a 400.
const RANGE_PARAMS = ["q", "project", "sort", "dir", "cursor", "totals", "series", "format"];
// q searches these columns; one bound LIKE value serves them all.
const SEARCH_COLS = ["lane", "project", "claimed_by", "args_json", "prof_line"];
// The sort allowlist: key -> SQL column. Every column is NOT NULL.
const RUN_SORT = {
  enqueued_at: { col: "enqueued_at", type: "text" },
  id: { col: "id", type: "num" },
  lane: { col: "lane", type: "text" },
  project: { col: "project", type: "text" },
  status: { col: "status", type: "text" },
  attempts: { col: "attempts", type: "num" },
};
// status on the range path, with the BH-6817 meaning: a done row with rc<>0
// is `failed`, and `done` is a done row with rc 0 or no rc. Fixed fragments;
// a raw status is a bind.
const RANGE_STATUS = {
  queued: null, claimed: null, died: null,
  done: "status='done' AND (rc IS NULL OR rc=0)",
  failed: "status='done' AND rc IS NOT NULL AND rc<>0",
};
const CSV_COLUMNS = ["id", "lane", "project", "status", "rc", "enqueued_at", "claimed_at", "claimed_by", "finished_at", "attempts"];
const RUN_COLS = "id, lane, project, status, enqueued_at, claimed_at, claimed_by, finished_at, rc, attempts, harness_commit";

// The range path. ONE knob read, then every param is validated (a 400 reads
// no table after the knob read), then page, totals and series in one
// Promise.all. Always keyset-paged: enqueued_at DESC, id DESC by default.
async function laneRunsRange({ env, url, t }) {
  const sp = url.searchParams;
  const knobs = await readPeriodKnobs(env);
  const range = parseRange(sp, knobs, Date.parse(t));
  if (range.error) return json(400, { error: range.error });
  const lane = nameParam(url, "lane");
  const machine = nameParam(url, "machine");
  const project = nameParam(url, "project");
  const nameErr = lane.err || machine.err || project.err;
  if (nameErr) return json(400, { error: nameErr });
  const status = sp.get("status") || null;
  if (status !== null && !Object.prototype.hasOwnProperty.call(RANGE_STATUS, status)) {
    return json(400, { error: `status must be one of ${Object.keys(RANGE_STATUS).join("|")}` });
  }
  const limit = intParam(url, "limit", LIST_LIMIT_DEFAULT, 1, LIST_LIMIT_MAX);
  if (limit.err) return json(400, { error: limit.err });
  const q = searchParam(sp);
  if (q.err) return json(400, { error: q.err });
  const sort = sortParam(sp, RUN_SORT, "enqueued_at");
  if (sort.err) return json(400, { error: sort.err });
  const cursor = cursorParam(sp, sort.type, "num");
  if (cursor.err) return json(400, { error: cursor.err });
  const totals = flagParam(sp, "totals");
  if (totals.err) return json(400, { error: totals.err });
  const series = seriesParam(sp, range, knobs.max_buckets);
  if (series.err) return json(400, { error: series.err });
  const format = formatParam(sp);
  if (format.err) return json(400, { error: format.err });

  const where = [], binds = [];
  const add = (frag, v) => { binds.push(v); where.push(frag.replace("?", `?${binds.length}`)); };
  add("enqueued_at>=?", range.from);
  add("enqueued_at<?", range.to);
  if (project.v) add("project=?", project.v);
  if (lane.v) add("lane=?", lane.v);
  if (machine.v) add("claimed_by=?", machine.v);
  if (status !== null) {
    if (RANGE_STATUS[status] === null) add("status=?", status);
    else where.push(RANGE_STATUS[status]);
  }
  if (q.v !== null) { binds.push(q.v); where.push(likeClause(SEARCH_COLS, binds.length)); }
  const whereSql = ` WHERE ${where.join(" AND ")}`;
  const order = orderBy(sort, "id");

  if (format.v === "csv") {
    const sql = `SELECT ${CSV_COLUMNS.join(", ")} FROM lane_runs${whereSql} ORDER BY ${order} LIMIT ?${binds.length + 1}`;
    const rows = (await env.DB.prepare(sql).bind(...binds, knobs.csv_row_cap + 1).all()).results || [];
    return csvResponse(CSV_COLUMNS, rows, { cap: knobs.csv_row_cap, filename: `lane-runs-${range.from}.csv` });
  }

  await ensureColumns(env, "lane_runs");
  const pw = [...where];
  let pageBinds = binds;
  if (cursor.v !== null) {
    pageBinds = [...binds, cursor.v[0], cursor.v[1]];
    pw.push(keysetClause(sort, "id", binds.length + 1));
  }
  const pageSql = `SELECT ${RUN_COLS} FROM lane_runs WHERE ${pw.join(" AND ")} ORDER BY ${order} LIMIT ?${pageBinds.length + 1}`;
  const reads = [env.DB.prepare(pageSql).bind(...pageBinds, limit.v + 1).all()];
  if (totals.v) {
    // sql-ident-ok: whereSql holds fixed fragments (RANGE_STATUS, likeClause over SEARCH_COLS) with ?N binds
    reads.push(env.DB.prepare(
      `SELECT COUNT(*) AS total, COALESCE(SUM(status='queued'),0) AS queued,
              COALESCE(SUM(status='claimed'),0) AS claimed,
              COALESCE(SUM(status='done' AND (rc IS NULL OR rc=0)),0) AS done,
              COALESCE(SUM(status='done' AND rc IS NOT NULL AND rc<>0),0) AS failed,
              COALESCE(SUM(status='died'),0) AS died
         FROM lane_runs${whereSql}`
    ).bind(...binds).first());
  }
  if (series.v) {
    // sql-ident-ok: bucketExpr is one of 3 fixed fragments over the literal column enqueued_at; whereSql as above
    reads.push(env.DB.prepare(
      `SELECT ${bucketExpr(series.v.series, "enqueued_at")} AS bucket, COUNT(*) AS n FROM lane_runs${whereSql} GROUP BY bucket`
    ).bind(...binds).all());
  }
  const res = await Promise.all(reads);
  const p = pageOut(res[0].results || [], limit.v, sort, "num");
  const out = {
    runs: p.rows.map((r) => runOut(r, t)), truncated: p.next_cursor !== null, limit: limit.v,
    next_cursor: p.next_cursor, as_of: t,
  };
  let i = 1;
  if (totals.v) {
    const r = res[i++] || {};
    out.totals = {};
    for (const k of ["total", "queued", "claimed", "done", "failed", "died"]) out.totals[k] = Number(r[k]) || 0;
  }
  if (series.v) out.series = fillSeries(series.v.buckets, res[i++].results);
  return json(200, out);
}

export const routes = [
  [
    "GET", "/api/lane-runs",
    ({ env, url, t }) => d1Guarded("lane_runs", async () => {
      // ?from=&to= (BH-9308, BH-9120.4): the range path. No range param: the
      // statement and the answer below are the ones before BH-9308.
      if (url.searchParams.has("from") || url.searchParams.has("to")) return laneRunsRange({ env, url, t });
      const needs = firstGiven(url.searchParams, RANGE_PARAMS);
      if (needs) return json(400, { error: `${needs} needs a from/to range` });
      const lane = nameParam(url, "lane");
      const machine = nameParam(url, "machine");
      if (lane.err || machine.err) return json(400, { error: lane.err || machine.err });
      const status = url.searchParams.get("status") || null;
      if (status !== null && !STATUSES.includes(status)) {
        return json(400, { error: `status must be one of ${STATUSES.join("|")}` });
      }
      const limit = intParam(url, "limit", LIST_LIMIT_DEFAULT, 1, LIST_LIMIT_MAX);
      if (limit.err) return json(400, { error: limit.err });
      await ensureColumns(env, "lane_runs");
      const rows = (await env.DB.prepare(
        `SELECT id, lane, project, status, enqueued_at, claimed_at, claimed_by, finished_at, rc, attempts, harness_commit
           FROM lane_runs
          WHERE (?1 IS NULL OR lane=?1) AND (?2 IS NULL OR claimed_by=?2) AND (?3 IS NULL OR status=?3)
          ORDER BY id DESC LIMIT ?4`
      ).bind(lane.v, machine.v, status, limit.v + 1).all()).results || [];
      const truncated = rows.length > limit.v;
      return json(200, {
        runs: rows.slice(0, limit.v).map((r) => runOut(r, t)), truncated, limit: limit.v, as_of: t,
      });
    }),
  ],

  [
    "GET", /^\/api\/lane-runs\/(\d+)$/,
    ({ env, t, m }) => d1Guarded("lane_runs", async () => {
      const id = Number(m[1]);
      const r = await env.DB.prepare("SELECT * FROM lane_runs WHERE id=?1").bind(id).first();
      if (!r) return json(404, { error: "no such lane run", id });
      return json(200, {
        run: {
          ...runOut(r, t), args: argsOf(r.args_json), enqueued_by: r.enqueued_by || null,
          heartbeat_at: r.heartbeat_at || null, lease_until: r.lease_until || null, prof_line: r.prof_line || null,
        },
        as_of: t,
      });
    }),
  ],

  [
    "GET", "/api/lane-runs/metrics",
    ({ env, url, t }) => d1Guarded("lane_runs", async () => {
      const hours = intParam(url, "hours", HOURS_DEFAULT, 1, HOURS_MAX);
      if (hours.err) return json(400, { error: hours.err });
      const now = Date.parse(t);
      const since = isoAt(now - hours.v * 3600 * 1000);
      // In the window: every run enqueued since `since`, plus every run still
      // live (queued or claimed) whenever it was enqueued.
      const IN_WINDOW = "(enqueued_at >= ?1 OR status IN ('queued','claimed'))";
      const [laneRows, machineRows, sample] = await Promise.all([
        // sql-ident-ok: IN_WINDOW is a local literal clause with ?N binds
        env.DB.prepare(
          `SELECT lane, SUM(status='queued') AS queued, SUM(status='claimed') AS claimed,
                  SUM(status='done') AS done, SUM(status='died') AS died
             FROM lane_runs WHERE ${IN_WINDOW} GROUP BY lane ORDER BY lane LIMIT ?2`
        ).bind(since, GROUP_MAX + 1).all(),
        // sql-ident-ok: IN_WINDOW is a local literal clause with ?N binds
        env.DB.prepare(
          `SELECT claimed_by AS machine, SUM(status='claimed') AS claimed, SUM(status='done') AS done,
                  SUM(status='died') AS died, MAX(claimed_at) AS last_claimed_at
             FROM lane_runs WHERE claimed_by IS NOT NULL AND ${IN_WINDOW}
            GROUP BY claimed_by ORDER BY claimed_by LIMIT ?2`
        ).bind(since, GROUP_MAX + 1).all(),
        env.DB.prepare(
          `SELECT lane, status, enqueued_at, claimed_at FROM lane_runs
            WHERE enqueued_at >= ?1 OR status='queued' ORDER BY id DESC LIMIT ?2`
        ).bind(since, WAIT_SAMPLE_MAX + 1).all(),
      ]);
      const lanesR = laneRows.results || [];
      const machinesR = machineRows.results || [];
      const sampleR = sample.results || [];
      const truncated = lanesR.length > GROUP_MAX || machinesR.length > GROUP_MAX || sampleR.length > WAIT_SAMPLE_MAX;

      // Cost in its own try: a D1 whose cost_rows lacks lane_id must not take
      // the rest of the answer down. Unavailable is said, never a silent 0.
      let cost = new Map();
      let costAvailable = true;
      try {
        const rows = (await env.DB.prepare(
          `SELECT lane_id, SUM(cost_usd) AS usd FROM cost_rows
            WHERE box LIKE ?1 AND ts >= ?2 AND lane_id IS NOT NULL GROUP BY lane_id`
        ).bind(COST_BOX_LIKE, since).all()).results || [];
        cost = new Map(rows.map((r) => [r.lane_id, round6(Number(r.usd) || 0)]));
      } catch {
        costAvailable = false;
      }

      const waits = laneMetrics(sampleR.slice(0, WAIT_SAMPLE_MAX), now);
      const lanes = lanesR.slice(0, GROUP_MAX).map((r) => ({
        lane: r.lane,
        queued: Number(r.queued), claimed: Number(r.claimed), done: Number(r.done), died: Number(r.died),
        ...(waits.get(r.lane) || { wait_p50_s: null, wait_max_s: null, wait_n: 0 }),
        cost_usd: cost.get(r.lane) || 0,
      }));
      // A lane that spent money in the window but has no run in it still shows.
      const seen = new Set(lanes.map((l) => l.lane));
      for (const [lane, usd] of cost) {
        if (lane === IDLE_LANE || seen.has(lane)) continue;
        lanes.push({ lane, queued: 0, claimed: 0, done: 0, died: 0, wait_p50_s: null, wait_max_s: null, wait_n: 0, cost_usd: usd });
      }
      const machines = machinesR.slice(0, GROUP_MAX).map((r) => ({
        machine: r.machine, claimed: Number(r.claimed), done: Number(r.done), died: Number(r.died),
        last_claimed_at: r.last_claimed_at || null,
      }));
      const h = await env.DB.prepare(
        "SELECT box, load1, reported_at FROM lane_run_hub_load ORDER BY reported_at DESC LIMIT 1"
      ).first();
      const hub = h ? {
        box: h.box, load1: h.load1 === null ? null : Number(h.load1), reported_at: h.reported_at,
        age_s: secs(h.reported_at, t),
      } : null;
      const wa = await thresholdMin(env);
      return json(200, {
        hours: hours.v, since, lanes, machines, hub,
        idle_cost_usd: cost.get(IDLE_LANE) || 0, cost_available: costAvailable,
        wait_alert_min: wa.min, truncated, as_of: t,
      });
    }),
  ],

  [
    "POST", "/api/lane-runs/wait-tick",
    ({ env, t, body }) => d1Guarded("lane_runs", async () => {
      const wa = await thresholdMin(env);
      const qrows = (await env.DB.prepare(
        `SELECT lane, MIN(enqueued_at) AS oldest, COUNT(*) AS n FROM lane_runs
          WHERE status='queued' GROUP BY lane ORDER BY lane LIMIT ?1`
      ).bind(GROUP_MAX + 1).all()).results || [];
      // Over the group cap the over set is incomplete, so no row is pruned
      // against it this tick (a missing lane is not an under lane).
      const truncated = qrows.length > GROUP_MAX;
      const queued = qrows.slice(0, GROUP_MAX).map((r) => ({
        lane: r.lane, wait_s: secs(r.oldest, t), queued: Number(r.n),
      }));
      const state = (await env.DB.prepare(
        "SELECT lane, over_ticks, alerted_at FROM lane_run_wait_alerts"
      ).all()).results || [];
      const d = waitDecision(queued, state, wa.min * 60);
      const stmts = d.over.map((q) => env.DB.prepare(
        `INSERT INTO lane_run_wait_alerts (lane, over_ticks, first_over_at, last_wait_s, last_tick_at)
         VALUES (?1, 1, ?2, ?3, ?2)
         ON CONFLICT(lane) DO UPDATE SET over_ticks=over_ticks+1, last_wait_s=excluded.last_wait_s,
           last_tick_at=excluded.last_tick_at`
      ).bind(q.lane, t, q.wait_s));
      if (!truncated) {
        stmts.push(env.DB.prepare(
          "DELETE FROM lane_run_wait_alerts WHERE lane NOT IN (SELECT value FROM json_each(?1))"
        ).bind(JSON.stringify(d.over.map((q) => q.lane))));
      }
      const box = laneName(body.box);
      const load1 = body.load1;
      const loadOk = Boolean(box) && typeof load1 === "number" && Number.isFinite(load1) && load1 >= 0;
      if (loadOk) {
        stmts.push(env.DB.prepare(
          `INSERT INTO lane_run_hub_load (box, load1, reported_at) VALUES (?1, ?2, ?3)
           ON CONFLICT(box) DO UPDATE SET load1=excluded.load1, reported_at=excluded.reported_at`
        ).bind(box, load1, t));
      }
      if (stmts.length) await env.DB.batch(stmts);
      const byLane = new Map(queued.map((q) => [q.lane, q]));
      const fireRows = (await env.DB.prepare(
        `SELECT lane, over_ticks, last_wait_s FROM lane_run_wait_alerts
          WHERE over_ticks >= ?1 AND alerted_at IS NULL ORDER BY lane`
      ).bind(FIRE_TICKS).all()).results || [];
      const fire = fireRows.filter((r) => byLane.has(r.lane)).map((r) => ({
        lane: r.lane, wait_s: Number(r.last_wait_s), queued: byLane.get(r.lane).queued, over_ticks: Number(r.over_ticks),
      }));
      return json(200, {
        threshold_min: wa.min, threshold_source: wa.source,
        over: d.over.map((q) => q.lane), fire, resolve: truncated ? [] : d.resolve,
        hub_load: loadOk ? "stored" : "skipped", truncated, as_of: t,
      });
    }),
  ],

  [
    "POST", "/api/lane-runs/wait-ack",
    ({ env, t, body }) => d1Guarded("lane_runs", async () => {
      const lane = laneName(body.lane);
      if (!lane) return json(400, { error: `lane is required and ${NAME_ERR}` });
      const r = await env.DB.prepare(
        "UPDATE lane_run_wait_alerts SET alerted_at=?1 WHERE lane=?2 AND alerted_at IS NULL"
      ).bind(t, lane).run();
      const acked = leaseWon(r) ? 1 : 0;
      if (!acked) {
        const row = await env.DB.prepare("SELECT lane FROM lane_run_wait_alerts WHERE lane=?1").bind(lane).first();
        if (!row) return json(404, { error: "no breach row for this lane", lane });
      }
      return json(200, { lane, acked, as_of: t });
    }),
  ],
];
