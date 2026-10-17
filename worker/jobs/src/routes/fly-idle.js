// fly-idle routes — BH-6061: the Fly idle reaper's stop ledger and its
// started-machine snapshot, read back by Mission Control (/machines).
// BH-6877: the destroy ledger (POST /api/fly-idle/destroys) and two snapshot
// fields per machine, last_work_at and no_claim.
//
// bin/fly-idle-reaper.sh writes both. A stop row is POSTed only after
// `flyctl machine stop` answered rc 0, from an outbox file that is removed on a
// 2xx, so a replay is normal: stop_id is the primary key and the INSERT is
// OR IGNORE. The snapshot is one PUT per pass: the old rows are deleted, the
// new rows inserted and the fly_idle_pass row upserted in ONE batch, so a
// failed batch leaves the old snapshot whole. Every row is validated before
// anything is written, so a bad body changes nothing. The tables come from
// schema.d/0023-bh-6061-fly-idle.sql; d1Guarded answers 503 when they are not
// applied. The worker's HARNESS_SECRET bearer guards all four routes.
//
// A destroy row (BH-6877) is POSTed the same way as a stop row: only after
// `flyctl machine destroy` answered rc 0, from an outbox file, keyed on
// destroy_id = <machine_id>-<epoch>, INSERT OR IGNORE. Its table comes from
// schema.d/202610170732-bh-6877-fly-destroys.sql. The GET reads it apart: when
// only fly_idle_destroys is missing, the GET still answers the stop half and
// says destroys: null with destroys_error, never an empty list. last_work_at
// and no_claim reach fly_idle_machines through ensureColumns (ADDED_COLUMNS in
// lib/core.js); both are optional on the PUT, so a reaper before BH-6877 still
// writes a valid snapshot.

import { json, d1Guarded } from "../lib/http.js";
import { ensureColumns } from "../lib/core.js";

const APP_RE = /^[a-z0-9-]{1,63}$/;
const MACHINE_RE = /^[0-9a-f]{6,32}$/;
const STOP_ID_RE = /^([0-9a-f]{6,32})-[0-9]{9,11}$/;
const DESTROY_ID_RE = STOP_ID_RE;
const SIZE_RE = /^[a-z0-9._-]{1,64}$/;
const STOP_SOURCE_RE = /^[a-z-]{1,32}$/;
const SNAP_SOURCE_RE = /^[a-z-]{1,32}$/;
const BOX_RE = /^[A-Za-z0-9._-]{1,64}$/;
// The reaper writes `date -u +%Y-%m-%dT%H:%M:%SZ`. Only that form is stored, so
// the 24 h window can compare the column as a string.
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const IDLE_STATES = new Set(["busy", "idle", "over", "stopping", "unknown", "nosignal", "exempt"]);
const STOP_ROWS_MAX = 50;
const SNAP_ROWS_MAX = 500;
const STOPS_SHOWN = 200;
const DESTROYS_SHOWN = 200;
const WINDOW_MS = 24 * 3600 * 1000;
// D1 binds at most 100 parameters per statement.
const STOP_COLS = 11;
const SNAP_COLS = 10;
const DESTROY_COLS = 11;

const bad = (error) => json(400, { error });
const isCount = (v) => typeof v === "number" && Number.isInteger(v) && v >= 0;
const optCount = (v) => v === null || v === undefined || isCount(v);
const optUsd = (v) => v === null || v === undefined || (typeof v === "number" && Number.isFinite(v) && v >= 0);
const optStr = (v, re) => v === null || v === undefined || (typeof v === "string" && re.test(v));
const isIso = (v) => typeof v === "string" && ISO_RE.test(v) && !Number.isNaN(Date.parse(v));
const nul = (v) => (v === undefined ? null : v);
const optIso = (v) => v === null || v === undefined || isIso(v);
const optBool = (v) => v === null || v === undefined || typeof v === "boolean";
const flag = (v) => (typeof v === "boolean" ? (v ? 1 : 0) : null);
const isoOf = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

// One validated INSERT per chunk, so no statement binds over 100 values.
function chunked(env, sql, cols, rows) {
  const per = Math.floor(100 / cols);
  const out = [];
  for (let i = 0; i < rows.length; i += per) {
    const chunk = rows.slice(i, i + per);
    const values = chunk.map((_, j) => `(${Array.from({ length: cols }, (_, k) => `?${j * cols + k + 1}`).join(", ")})`);
    // sql-ident-ok: sql is a literal INSERT prefix from the two callers in this file; values is ?N tuples
    out.push(env.DB.prepare(sql + values.join(", ")).bind(...chunk.flat()));
  }
  return out;
}

function stopRow(r) {
  if (!r || typeof r !== "object") return "each row must be an object";
  if (typeof r.app !== "string" || !APP_RE.test(r.app)) return "app must match ^[a-z0-9-]{1,63}$";
  if (typeof r.machine_id !== "string" || !MACHINE_RE.test(r.machine_id)) return "machine_id must match ^[0-9a-f]{6,32}$";
  const sid = typeof r.stop_id === "string" ? STOP_ID_RE.exec(r.stop_id) : null;
  if (!sid || sid[1] !== r.machine_id) return "stop_id must be <machine_id>-<epoch seconds>";
  if (!optStr(r.size, SIZE_RE)) return "size must be a size name or null";
  if (typeof r.source !== "string" || !STOP_SOURCE_RE.test(r.source)) return "source must match ^[a-z-]{1,32}$";
  if (!isCount(r.idle_s) || !isCount(r.threshold_s)) return "idle_s and threshold_s must be non-negative integers";
  if (!optUsd(r.usd_per_hour)) return "usd_per_hour must be a non-negative number or null";
  if (r.status !== "requested") return "status must be requested";
  if (!optStr(r.box, BOX_RE)) return "box is not a box name";
  if (!isIso(r.stopped_at)) return "stopped_at must be YYYY-MM-DDTHH:MM:SSZ";
  return [r.stop_id, r.app, r.machine_id, nul(r.size), r.source, r.idle_s, r.threshold_s,
    nul(r.usd_per_hour), "requested", nul(r.box), r.stopped_at];
}

function snapRow(r) {
  if (!r || typeof r !== "object") return "each row must be an object";
  if (typeof r.app !== "string" || !APP_RE.test(r.app)) return "app must match ^[a-z0-9-]{1,63}$";
  if (typeof r.machine_id !== "string" || !MACHINE_RE.test(r.machine_id)) return "machine_id must match ^[0-9a-f]{6,32}$";
  if (!optStr(r.size, SIZE_RE)) return "size must be a size name or null";
  if (typeof r.source !== "string" || !SNAP_SOURCE_RE.test(r.source)) return "source must match ^[a-z-]{1,32}$";
  if (!optCount(r.idle_s) || !optCount(r.threshold_s)) return "idle_s and threshold_s must be non-negative integers or null";
  if (!IDLE_STATES.has(r.idle_state)) return `idle_state must be one of ${[...IDLE_STATES].join(", ")}`;
  if (!optUsd(r.usd_per_hour)) return "usd_per_hour must be a non-negative number or null";
  if (!optIso(r.last_work_at)) return "last_work_at must be YYYY-MM-DDTHH:MM:SSZ or null";
  if (!optBool(r.no_claim)) return "no_claim must be true, false or null";
  return [r.app, r.machine_id, nul(r.size), r.source, nul(r.idle_s), r.idle_state, nul(r.threshold_s), nul(r.usd_per_hour),
    nul(r.last_work_at), flag(r.no_claim)];
}

function destroyRow(r) {
  if (!r || typeof r !== "object") return "each row must be an object";
  if (typeof r.app !== "string" || !APP_RE.test(r.app)) return "app must match ^[a-z0-9-]{1,63}$";
  if (typeof r.machine_id !== "string" || !MACHINE_RE.test(r.machine_id)) return "machine_id must match ^[0-9a-f]{6,32}$";
  const did = typeof r.destroy_id === "string" ? DESTROY_ID_RE.exec(r.destroy_id) : null;
  if (!did || did[1] !== r.machine_id) return "destroy_id must be <machine_id>-<epoch seconds>";
  if (!optStr(r.size, SIZE_RE)) return "size must be a size name or null";
  if (typeof r.source !== "string" || !STOP_SOURCE_RE.test(r.source)) return "source must match ^[a-z-]{1,32}$";
  if (!isCount(r.stopped_s)) return "stopped_s must be a non-negative integer";
  if (!optUsd(r.usd_per_hour)) return "usd_per_hour must be a non-negative number or null";
  if (r.kind !== "destroy") return "kind must be destroy";
  if (r.status !== "requested") return "status must be requested";
  if (!optStr(r.box, BOX_RE)) return "box is not a box name";
  if (!isIso(r.destroyed_at)) return "destroyed_at must be YYYY-MM-DDTHH:MM:SSZ";
  return [r.destroy_id, r.app, r.machine_id, nul(r.size), r.source, r.stopped_s,
    nul(r.usd_per_hour), "destroy", "requested", nul(r.box), r.destroyed_at];
}

// The two destroy reads of the GET. Plain range reads on
// fly_idle_destroys_destroyed_at; exported so the EXPLAIN QUERY PLAN test
// (test/fly-idle-destroys.bh-6877.test.js) runs the SQL that ships.
export const DESTROYS_24H_SQL =
  "SELECT destroy_id, app, machine_id, size, source, stopped_s, usd_per_hour, kind, status, box, destroyed_at "
  + "FROM fly_idle_destroys WHERE destroyed_at >= ?1 ORDER BY destroyed_at DESC, destroy_id ASC LIMIT ?2";
export const DESTROYS_AGG_SQL =
  "SELECT COUNT(*) AS n, SUM(usd_per_hour) AS usd FROM fly_idle_destroys WHERE destroyed_at >= ?1";

// The destroy half of the GET: both reads in ONE env.DB.batch (one round
// trip; lead review BLOCK on 83ca230c). A missing fly_idle_destroys (schema
// not applied) is reported in the body, so the stop half still answers.
async function destroysSince(env, since) {
  try {
    const [list, aggRes] = await env.DB.batch([
      env.DB.prepare(DESTROYS_24H_SQL).bind(since, DESTROYS_SHOWN),
      env.DB.prepare(DESTROYS_AGG_SQL).bind(since),
    ]);
    const agg = ((aggRes && aggRes.results) || [])[0] || null;
    return {
      destroys: (list.results || []).map((r) => ({
        destroy_id: r.destroy_id, app: r.app, machine_id: r.machine_id, size: r.size ?? null, source: r.source,
        stopped_s: Number(r.stopped_s), usd_per_hour: num(r.usd_per_hour), kind: r.kind, status: r.status,
        box: r.box ?? null, destroyed_at: r.destroyed_at,
      })),
      destroys_24h: Number((agg && agg.n) || 0),
      destroy_usd_per_hour_24h: Number((agg && agg.usd) || 0),
    };
  } catch (e) {
    const detail = String((e && e.message) || e);
    if (!/no such table/i.test(detail)) throw e;
    return { destroys: null, destroys_24h: null, destroy_usd_per_hour_24h: null, destroys_error: "fly_idle_destroys schema not applied" };
  }
}

const num = (v) => (v === null || v === undefined ? null : Number(v));

export const routes = [
  // The stop ledger. 1..50 rows, each validated; a replayed stop_id is ignored.
  [
    "POST", "/api/fly-idle/stops",
    async ({ env, body }) => {
      const rows = body.rows;
      if (!Array.isArray(rows) || rows.length < 1 || rows.length > STOP_ROWS_MAX) {
        return bad(`rows must be an array of 1..${STOP_ROWS_MAX}`);
      }
      const clean = [];
      for (const r of rows) {
        const v = stopRow(r);
        if (typeof v === "string") return bad(v);
        clean.push(v);
      }
      return d1Guarded("fly_idle_stops", async () => {
        const res = await env.DB.batch(chunked(env,
          "INSERT OR IGNORE INTO fly_idle_stops (stop_id, app, machine_id, size, source, idle_s, threshold_s, "
          + "usd_per_hour, status, box, stopped_at) VALUES ", STOP_COLS, clean));
        const inserted = res.reduce((n, r) => n + Number((r && r.meta && r.meta.changes) || 0), 0);
        return json(200, { ok: true, inserted, ignored: clean.length - inserted });
      });
    },
  ],

  // The destroy ledger (BH-6877). 1..50 rows, each validated; a replayed
  // destroy_id is ignored.
  [
    "POST", "/api/fly-idle/destroys",
    async ({ env, body }) => {
      const rows = body.rows;
      if (!Array.isArray(rows) || rows.length < 1 || rows.length > STOP_ROWS_MAX) {
        return bad(`rows must be an array of 1..${STOP_ROWS_MAX}`);
      }
      const clean = [];
      for (const r of rows) {
        const v = destroyRow(r);
        if (typeof v === "string") return bad(v);
        clean.push(v);
      }
      return d1Guarded("fly_idle_destroys", async () => {
        const res = await env.DB.batch(chunked(env,
          "INSERT OR IGNORE INTO fly_idle_destroys (destroy_id, app, machine_id, size, source, stopped_s, usd_per_hour, "
          + "kind, status, box, destroyed_at) VALUES ", DESTROY_COLS, clean));
        const inserted = res.reduce((n, r) => n + Number((r && r.meta && r.meta.changes) || 0), 0);
        return json(200, { ok: true, inserted, ignored: clean.length - inserted });
      });
    },
  ],

  // The started-machine snapshot of one pass. It replaces the last one whole.
  [
    "PUT", "/api/fly-idle/machines",
    async ({ env, body }) => {
      if (!isIso(body.pass_at)) return bad("pass_at must be YYYY-MM-DDTHH:MM:SSZ");
      if (!isCount(body.apps_total) || !isCount(body.apps_failed)) return bad("apps_total and apps_failed must be non-negative integers");
      if (body.apps_failed > body.apps_total) return bad("apps_failed must be at most apps_total");
      if (!optStr(body.box, BOX_RE)) return bad("box is not a box name");
      const rows = body.rows === undefined || body.rows === null ? [] : body.rows;
      if (!Array.isArray(rows) || rows.length > SNAP_ROWS_MAX) return bad(`rows must be an array of at most ${SNAP_ROWS_MAX}`);
      const seen = new Set();
      const clean = [];
      for (const r of rows) {
        const v = snapRow(r);
        if (typeof v === "string") return bad(v);
        const k = `${v[0]}/${v[1]}`;
        if (seen.has(k)) return bad(`machine ${k} appears twice`);
        seen.add(k);
        clean.push(v);
      }
      const partial = body.apps_failed > 0 ? 1 : 0;
      return d1Guarded("fly_idle_machines", async () => {
        await ensureColumns(env, "fly_idle_machines");
        const stmts = [env.DB.prepare("DELETE FROM fly_idle_machines")];
        stmts.push(...chunked(env,
          "INSERT INTO fly_idle_machines (app, machine_id, size, source, idle_s, idle_state, threshold_s, usd_per_hour, "
          + "last_work_at, no_claim) VALUES ",
          SNAP_COLS, clean));
        stmts.push(env.DB.prepare(
          "INSERT INTO fly_idle_pass (id, pass_at, apps_total, apps_failed, partial, box) VALUES (1, ?1, ?2, ?3, ?4, ?5) "
          + "ON CONFLICT(id) DO UPDATE SET pass_at = excluded.pass_at, apps_total = excluded.apps_total, "
          + "apps_failed = excluded.apps_failed, partial = excluded.partial, box = excluded.box"
        ).bind(body.pass_at, body.apps_total, body.apps_failed, partial, nul(body.box)));
        await env.DB.batch(stmts);
        return json(200, { ok: true, stored: clean.length, partial });
      });
    },
  ],

  // What Mission Control shows: the last snapshot and the stops and destroys
  // of the last 24 h, newest first. The window is taken from Date.now() at
  // request time.
  [
    "GET", "/api/fly-idle",
    async ({ env }) => d1Guarded("fly_idle_stops", async () => {
      const since = isoOf(Date.now() - WINDOW_MS);
      await ensureColumns(env, "fly_idle_machines");
      // The five reads do not depend on each other: they run together (BH-6946).
      const [pass, machines, stops, agg, destroyed] = await Promise.all([
        env.DB.prepare("SELECT pass_at, apps_total, apps_failed, partial, box FROM fly_idle_pass WHERE id = 1").first(),
        env.DB.prepare(
          "SELECT app, machine_id, size, source, idle_s, idle_state, threshold_s, usd_per_hour, last_work_at, no_claim "
          + "FROM fly_idle_machines "
          + "ORDER BY idle_s IS NULL, idle_s DESC, app ASC, machine_id ASC"
        ).all(),
        env.DB.prepare(
          "SELECT stop_id, app, machine_id, size, source, idle_s, threshold_s, usd_per_hour, status, box, stopped_at "
          + "FROM fly_idle_stops WHERE stopped_at >= ?1 ORDER BY stopped_at DESC, stop_id ASC LIMIT ?2"
        ).bind(since, STOPS_SHOWN).all(),
        env.DB.prepare(
          "SELECT COUNT(*) AS n, SUM(usd_per_hour) AS usd, SUM(CASE WHEN usd_per_hour IS NULL THEN 1 ELSE 0 END) AS unpriced "
          + "FROM fly_idle_stops WHERE stopped_at >= ?1"
        ).bind(since).first(),
        destroysSince(env, since),
      ]);
      const mrows = (machines.results || []).map((r) => ({
        app: r.app, machine_id: r.machine_id, size: r.size ?? null, source: r.source, idle_s: num(r.idle_s),
        idle_state: r.idle_state, threshold_s: num(r.threshold_s), usd_per_hour: num(r.usd_per_hour),
        last_work_at: r.last_work_at ?? null,
        no_claim: r.no_claim === null || r.no_claim === undefined ? null : Number(r.no_claim) === 1,
      }));
      return json(200, {
        pass: pass ? {
          pass_at: pass.pass_at, apps_total: Number(pass.apps_total), apps_failed: Number(pass.apps_failed),
          partial: Number(pass.partial), box: pass.box ?? null,
        } : null,
        machines: mrows,
        over_count: mrows.filter((r) => r.idle_state === "over").length,
        stops: (stops.results || []).map((r) => ({
          stop_id: r.stop_id, app: r.app, machine_id: r.machine_id, size: r.size ?? null, source: r.source,
          idle_s: Number(r.idle_s), threshold_s: Number(r.threshold_s), usd_per_hour: num(r.usd_per_hour),
          status: r.status, box: r.box ?? null, stopped_at: r.stopped_at,
        })),
        stops_24h: Number((agg && agg.n) || 0),
        unpriced_24h: Number((agg && agg.unpriced) || 0),
        saved_usd_per_hour_24h: Number((agg && agg.usd) || 0),
        ...destroyed,
        window_since: since,
      });
    }),
  ],
];
