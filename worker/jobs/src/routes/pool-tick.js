// pool-tick routes — the last pool tick of each project, grouped by why its
// rows did or did not spawn (BH-7709).
//
// The hub lane bin/pool-tick-summary.sh reads the tail of logs/fly-pool.log
// every 2 minutes and posts one row per pool project. Two readers make ONE GET
// each: the MCP pool_status tool (mcp/tools/pool-status.mjs, through
// /api/coord/pool/status) and the BH-7725 unblock collector
// (bin/lib/unblock/collectors/infra.sh, through _jobs_req).
// Table: schema.d/202610211310-bh-7709-pool-tick-summary.sql.
// Note: docs/notes/2026-10-21-BH-7709-pool-status-mcp.md.
//
// POST /api/pool/tick-summary {rows:[row]}
//   row = {project, tail_lines, tick: "ok"|null, reason,
//          queued, running, spawning, cap, hotfix,
//          last_tick: {at, started_at, ended_at, complete, rows_decided,
//                      rows_spawned, stop, window_stop, cap, knob,
//                      in_progress_since, max_ticks_waits_1h, last_max_ticks_at},
//          decisions: [[key, class]] | null, decisions_truncated,
//          env_bundle_failures_1h, respawns: [{key, count, last_result, last_at}],
//          respawns_since, respawns_truncated}
//   rows: 1..MAX_ROWS entries, else 400 and nothing written. A row with a bad
//   field, or a project named twice, is counted in `rejected` and not written.
//   Only the fields above are stored (summary_json), so a stray field never
//   reaches a reader. The good rows are ONE batch of upserts on the PRIMARY
//   KEY; reported_at is the worker clock `t`. → 200 {written, rejected, as_of}.
//
// GET /api/pool/status?project=<p>   (format pool-status v1)
//   → 200 {project, version: 1, reported_at, as_of, ...the stored row,
//          spawn_cap_per_key: {value, window_s, source: row|default}}
//   No row: {project, version: 1, tick: null, reason: "no summary row",
//   spawn_cap_per_key, as_of} with NO queued/running keys, so a reader that
//   checks `(.queued | type) == "number"` sees nothing to act on.
//   project is required ([A-Za-z0-9._-]{1,64}), else 400. spawn_cap_per_key
//   reads the settings rows bin/fly-pool.sh pool_spawn_cap_load reads, in its
//   order: the project's own lane.fly-pool.<p>.pool_spawn_cap_per_key, then
//   pool_spawn_cap_per_key, then 2; pool_spawn_cap_window_s, then 86400. A value
//   that is not digits is no row. The hub's env fallback (POOL_SPAWN_CAP_PER_KEY)
//   is not visible here, so it reads as default.
//   Statements: two PRIMARY KEY reads, in parallel.
import { d1Guarded, json } from "../lib/http.js";
import { laneName } from "../lib/core.js";

export const MAX_ROWS = 200;
export const MAX_DECISIONS = 500;
export const MAX_RESPAWNS = 50;
export const CLASSES = new Set(["waits_for", "hold", "spawn_cap", "env_bundle", "quota", "not_queued", "other", "spawned"]);
// stop: the window stops, plus the attempt stops. Never "cap".
const STOPS = new Set(["budget", "age", "code", "done", "max-ticks", "shed", "hold"]);
const WINDOW_STOPS = new Set(["budget", "age", "code", "done"]);
const KNOBS = new Set(["POOL_TICK_MAX_PARALLEL", "POOL_TICK_BUDGET_S", "POOL_TICK_MAX_AGE_S"]);
const ISO_RE = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
const MAX_COUNT = 1000000;
const CAP_DEFAULT = 2;
const WINDOW_DEFAULT = 86400;

// ?1 project, ?2 t, ?3 summary_json. The PRIMARY KEY autoindex serves the conflict.
export const UPSERT_SQL = `INSERT INTO pool_tick_summary (project, reported_at, summary_json, updated_at)
 VALUES (?1, ?2, ?3, ?2)
 ON CONFLICT(project) DO UPDATE SET
   reported_at=excluded.reported_at, summary_json=excluded.summary_json, updated_at=excluded.updated_at`;
// ?1 project. The PRIMARY KEY autoindex.
export const READ_SQL = `SELECT reported_at, summary_json FROM pool_tick_summary WHERE project = ?1`;
// ?1 the project's cap row, ?2 the fleet cap row, ?3 the window row. settings' PRIMARY KEY.
export const SETTINGS_SQL = `SELECT key, value FROM settings WHERE key IN (?1, ?2, ?3)`;

const isPlain = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const isCount = (v) => Number.isInteger(v) && v >= 0 && v <= MAX_COUNT;
const isIso = (v) => typeof v === "string" && ISO_RE.test(v);
const isKey = (v) => typeof v === "string" && laneName(v) === v;
const isBool = (v) => typeof v === "boolean";
// Each field: a check, or null (or absent) as null. A failed check fails the row.
function pick(src, spec) {
  const out = {};
  for (const [k, ok] of Object.entries(spec)) {
    const v = src[k];
    if (v === undefined || v === null) { out[k] = null; continue; }
    if (!ok(v)) return null;
    out[k] = v;
  }
  return out;
}

const LAST_TICK = {
  at: isIso, started_at: isIso, ended_at: isIso, complete: isBool,
  rows_decided: isCount, rows_spawned: isCount,
  stop: (v) => STOPS.has(v), window_stop: (v) => WINDOW_STOPS.has(v),
  cap: isCount, knob: (v) => KNOBS.has(v),
  in_progress_since: isIso, max_ticks_waits_1h: isCount, last_max_ticks_at: isIso,
};
const isDecisions = (v) => Array.isArray(v) && v.length <= MAX_DECISIONS
  && v.every((d) => Array.isArray(d) && d.length === 2 && isKey(d[0]) && CLASSES.has(d[1]));
const isRespawn = (r) => isPlain(r) && isKey(r.key) && Number.isInteger(r.count) && r.count >= 2 && r.count <= MAX_COUNT
  && (r.last_result === null || isKey(r.last_result)) && isIso(r.last_at);
const ROW = {
  tail_lines: isCount, tick: (v) => v === "ok", reason: (v) => typeof v === "string" && v.length <= 200,
  queued: isCount, running: isCount, spawning: isCount, cap: isCount, hotfix: isCount,
  decisions: isDecisions, decisions_truncated: isBool, env_bundle_failures_1h: isCount,
  respawns_since: isIso, respawns_truncated: isBool,
};

// One posted row → {project, summary} or null. The summary holds only the
// fields named in the header, in a fixed order.
function parseRow(r) {
  if (!isPlain(r) || !isKey(r.project) || !isPlain(r.last_tick)) return null;
  if (!isCount(r.tail_lines) || !isCount(r.env_bundle_failures_1h)) return null;
  if (!Array.isArray(r.respawns) || r.respawns.length > MAX_RESPAWNS || !r.respawns.every(isRespawn)) return null;
  const top = pick(r, ROW);
  const lastTick = pick(r.last_tick, LAST_TICK);
  if (!top || !lastTick) return null;
  const respawns = r.respawns.map((x) => ({ key: x.key, count: x.count, last_result: x.last_result, last_at: x.last_at }));
  const { decisions, decisions_truncated, env_bundle_failures_1h, respawns_since, respawns_truncated, ...head } = top;
  return {
    project: r.project,
    summary: {
      ...head, last_tick: lastTick, decisions, decisions_truncated, env_bundle_failures_1h,
      respawns, respawns_since, respawns_truncated,
    },
  };
}

// The cap row key bin/fly-pool.sh pool_spawn_cap_project_row builds: lowercased,
// and no row at all past 64 characters.
const projectCapKey = (p) => {
  const k = `lane.fly-pool.${p}.pool_spawn_cap_per_key`.toLowerCase();
  return /^[a-z0-9_.-]{1,64}$/.test(k) ? k : null;
};
const digits = (v) => (typeof v === "string" && /^\d+$/.test(v.trim()) ? Number(v.trim()) : null);

function spawnCap(projectKey, rows) {
  const by = new Map(rows.map((r) => [r.key, digits(r.value)]));
  const own = projectKey ? by.get(projectKey) ?? null : null;
  const fleet = by.get("pool_spawn_cap_per_key") ?? null;
  const win = by.get("pool_spawn_cap_window_s") ?? null;
  return {
    value: own ?? fleet ?? CAP_DEFAULT,
    window_s: win ?? WINDOW_DEFAULT,
    source: own !== null || fleet !== null ? "row" : "default",
  };
}

export const routes = [
  [
    "POST", "/api/pool/tick-summary",
    ({ env, t, body }) => d1Guarded("pool_tick_summary", async () => {
      const list = isPlain(body) ? body.rows : undefined;
      if (!Array.isArray(list) || list.length === 0 || list.length > MAX_ROWS) {
        return json(400, { error: `rows is required: an array of 1..${MAX_ROWS} entries` });
      }
      const seen = new Set();
      const good = [];
      for (const raw of list) {
        const r = parseRow(raw);
        if (!r || seen.has(r.project)) continue;
        seen.add(r.project);
        good.push(r);
      }
      if (good.length) {
        await env.DB.batch(good.map((r) => env.DB.prepare(UPSERT_SQL).bind(r.project, t, JSON.stringify(r.summary))));
      }
      return json(200, { written: good.length, rejected: list.length - good.length, as_of: t });
    }),
  ],
  [
    "GET", "/api/pool/status",
    ({ env, t, url }) => d1Guarded("pool_tick_summary", async () => {
      const raw = url.searchParams.get("project");
      const project = laneName(raw);
      if (!project || project !== raw) return json(400, { error: "project is required: [A-Za-z0-9._-]{1,64}" });
      const capKey = projectCapKey(project);
      const [row, settings] = await Promise.all([
        env.DB.prepare(READ_SQL).bind(project).first(),
        env.DB.prepare(SETTINGS_SQL).bind(capKey ?? "pool_spawn_cap_per_key", "pool_spawn_cap_per_key", "pool_spawn_cap_window_s").all(),
      ]);
      const cap = spawnCap(capKey, settings.results || []);
      if (!row) return json(200, { project, version: 1, tick: null, reason: "no summary row", spawn_cap_per_key: cap, as_of: t });
      return json(200, {
        project, version: 1, reported_at: row.reported_at, as_of: t,
        ...JSON.parse(row.summary_json), spawn_cap_per_key: cap,
      });
    }),
  ],
];
