// staff screen routes — BH-5567 (BH-5556.10): the reads behind the console's
// /staff screen. Read only: nothing here writes staff_findings or staff_agents.
// The kill switch is not here either; the screen writes it through the
// existing PUT/DELETE /api/flags (flags.js) as staff-kill-<agent> and
// staff-kill-all.
//
// GET /api/staff/roster is Archie plus every staff_agents row, each with its
// open-findings count. Archie is not a staff_agents row: its role and
// accountable person are the settings rows staff.archie.role and
// staff.archie.accountable, and an absent row is null, never a fallback.
// precision is null on every row, because no source exists yet; `sources`
// names the ticket that builds it. last_tick_at is the newest staff_ticks row
// of each agent, Archie included (BH-9127: Archie posts heartbeats too).
//
// SPEND (BH-9127). spend_usd is the agent's priced cost since 00:00Z today and
// spend_usd_7d over the last staff.spend.window_days days (fallback 7); each
// comes with an unpriced row count, which is never read as $0. An agent's cost
// rows are (1) the rows of its lanes: its staff_lanes rows plus the lanes the
// settings row staff.spend.lane_map gives it (Archie's lanes live there), and
// (2) its own heartbeat model calls on the shared lane staff, found through
// staff_ticks.cost_run_id. A row on a mapped lane is counted by (1) only, so no
// row counts twice. An agent with no row is 0, because the read happened. A
// failed read is null on every row with sources.spend "unread"; an unparsable
// lane map is null on every row with sources.spend "invalid: ..." and runs
// nothing; an absent lane map row is null for Archie only.
//
// GET /api/staff/findings?agent= is one agent's open findings, newest first,
// capped at FINDINGS_MAX with `truncated` set when the cap cut the list.
// GET /api/staff/finding?id= is one finding with every column.
//
// "Open" is any status outside CLOSED. A missing table answers 503 naming it
// (d1Guarded), on every route.

import { json, d1Guarded } from "../lib/http.js";
import { COST_ARCHIVE_FLOOR_DAYS } from "./retention.js";

const AGENT_RE = /^[a-z][a-z0-9-]{1,39}$/;
const ID_RE = /^[1-9]\d{0,15}$/;
const ARCHIE = "archie";
const FINDINGS_MAX = 500;
// The status words that end a finding (wave 6's outcomes). Everything else is open.
const CLOSED = ["merged", "rejected", "noise", "closed"];
const CLOSED_SQL = CLOSED.map((s) => `'${s}'`).join(",");
const SOURCES = { precision: "not built: BH-5563 (#5563)" };
// The long SPEND window: settings row staff.spend.window_days; 7 is its
// fallback when the row is absent or outside 1..COST_ARCHIVE_FLOOR_DAYS (the
// cost_rows hot floor, so the read never reaches the archive).
const SPEND_WINDOW_DEFAULT = 7;
const SETTING_KEYS = ["staff.archie.role", "staff.archie.accountable", "staff.spend.lane_map", "staff.spend.window_days"];
const COLUMNS = "id, fingerprint, agent, title, source_kind, source_url, status, ticket_url, observed_at, claimed_at, updated_at";

// THE agent identity: the same rule as staff.js (trim, lowercase).
const agentOf = (v) => {
  if (typeof v !== "string") return null;
  const a = v.trim().toLowerCase();
  return AGENT_RE.test(a) ? a : null;
};
const bad = (field) => json(400, { error: field });

// The roster's settings rows in one read: key -> trimmed value, absent or blank -> null.
async function settingsOf(env) {
  const { results } = await env.DB.prepare(
    `SELECT key, value FROM settings WHERE key IN (SELECT value FROM json_each(?1))`
  ).bind(JSON.stringify(SETTING_KEYS)).all();
  const out = Object.fromEntries(SETTING_KEYS.map((k) => [k, null]));
  for (const r of results || []) {
    if (typeof r.value === "string" && r.value.trim() !== "") out[r.key] = r.value.trim();
  }
  return out;
}
const labelsOf = (raw) => {
  try {
    const v = JSON.parse(raw);
    if (Array.isArray(v)) return { source_labels: v };
  } catch { /* falls through: the raw text is shown, marked invalid */ }
  return { source_labels: raw, labels_invalid: true };
};

// The newest staff_ticks.started_at per agent (BH-6822): one index seek per
// agent, run together, never a GROUP BY over the table. null when the read
// fails (the table predates nothing here): the roster still answers, with
// sources.last_tick "unread".
async function lastTicks(env, names) {
  if (!names.length) return new Map();
  try {
    const stmt = `SELECT started_at FROM staff_ticks WHERE agent=?1 ORDER BY started_at DESC, id DESC LIMIT 1`;
    const rows = await Promise.all(names.map((n) => env.DB.prepare(stmt).bind(n).first()));
    return new Map(names.map((n, i) => [n, (rows[i] && rows[i].started_at) || null]));
  } catch {
    return null;
  }
}

// staff.spend.lane_map -> { map } (agent -> sorted lane list), { absent }, or { invalid }.
function laneMapOf(raw) {
  if (raw === null) return { map: {}, absent: true };
  let v;
  try { v = JSON.parse(raw); } catch { return { invalid: true }; }
  if (!v || typeof v !== "object" || Array.isArray(v)) return { invalid: true };
  const map = {};
  for (const [agent, lanes] of Object.entries(v)) {
    if (agentOf(agent) !== agent || !Array.isArray(lanes)) return { invalid: true };
    if (!lanes.every((l) => typeof l === "string" && /^[a-z0-9][a-z0-9._-]{0,79}$/.test(l))) return { invalid: true };
    map[agent] = [...new Set(lanes)].sort();
  }
  return { map };
}
function windowOf(raw) {
  const n = raw !== null && /^\d{1,3}$/.test(raw) ? Number(raw) : null;
  return n !== null && n >= 1 && n <= COST_ARCHIVE_FLOOR_DAYS ? { days: n } : { days: SPEND_WINDOW_DEFAULT, fallback: true };
}

// The agent -> lane set both spend statements share: staff_lanes plus the map row.
// In SUMS, a lane with no row in the window is a LEFT JOIN null row: its ts is
// null, so the today sums skip it, and the box test keeps it out of the
// unpriced count (box is NOT NULL on every real row).
const LANES_CTE = `WITH m(agent, lane) AS (
    SELECT agent, lane FROM staff_lanes
    UNION SELECT j1.key, j2.value FROM json_each(?1) j1, json_each(j1.value) j2)`;
const SUMS = `SUM(CASE WHEN cost_rows.ts >= ?2 THEN cost_rows.cost_usd END) AS today_usd,
    SUM(cost_rows.cost_usd) AS week_usd,
    SUM(CASE WHEN cost_rows.ts >= ?2 AND cost_rows.cost_usd IS NULL THEN 1 ELSE 0 END) AS today_unpriced,
    SUM(CASE WHEN cost_rows.box IS NOT NULL AND cost_rows.cost_usd IS NULL THEN 1 ELSE 0 END) AS week_unpriced`;

// Spend per agent in two statements, run beside the other roster reads.
// -> Map agent -> { today, week, today_unpriced, week_unpriced, lanes }.
// A D1 throw propagates: the caller reads it as "unread".
async function agentSpend(env, map, days, t) {
  const today = `${t.slice(0, 10)}T00:00:00Z`;
  const since = new Date(Math.min(Date.parse(t) - days * 86400e3, Date.parse(today))).toISOString().replace(/\.\d{3}Z$/, "Z");
  const mapJson = JSON.stringify(map);
  // (1) the agent's own lanes; idx_cost_rows_lane_ts per lane.
  // sql-ident-ok: LANES_CTE and SUMS are module string constants, values bound
  const byLane = env.DB.prepare(`${LANES_CTE}
    SELECT m.agent AS agent, json_group_array(DISTINCT m.lane) AS lanes, ${SUMS}
      FROM m LEFT JOIN cost_rows ON cost_rows.lane_id = m.lane AND cost_rows.ts >= ?3
     GROUP BY m.agent`).bind(mapJson, today, since).all();
  // (2) the agent's heartbeat calls on any lane not in (1): a range seek on
  // idx_staff_ticks_started, then idx_cost_rows_run_id. INDEXED BY pins the seek:
  // with no table statistics the planner walks the whole agent index for the
  // GROUP BY instead. The NOT IN set is built once, not per row.
  // sql-ident-ok: LANES_CTE and SUMS are module string constants, values bound
  const byTick = env.DB.prepare(`${LANES_CTE}
    SELECT staff_ticks.agent AS agent, ${SUMS}
      FROM staff_ticks INDEXED BY idx_staff_ticks_started JOIN cost_rows ON cost_rows.run_id = staff_ticks.cost_run_id
     WHERE staff_ticks.started_at >= ?3 AND cost_rows.ts >= ?3
       AND (cost_rows.lane_id IS NULL OR cost_rows.lane_id NOT IN (SELECT lane FROM m))
     GROUP BY staff_ticks.agent`).bind(mapJson, today, since).all();
  const [a, b] = await Promise.all([byLane, byTick]);
  const out = new Map();
  const add = (r, lanes) => {
    const o = out.get(r.agent) || { today: 0, week: 0, today_unpriced: 0, week_unpriced: 0, lanes: [] };
    o.today += Number(r.today_usd || 0);
    o.week += Number(r.week_usd || 0);
    o.today_unpriced += Number(r.today_unpriced || 0);
    o.week_unpriced += Number(r.week_unpriced || 0);
    if (lanes) o.lanes = JSON.parse(lanes).sort();
    out.set(r.agent, o);
  };
  for (const r of a.results || []) add(r, r.lanes);
  for (const r of b.results || []) add(r, null);
  return out;
}
const usd = (v) => Math.round(v * 1e6) / 1e6;

export const routes = [
  // ── GET /api/staff/roster — Archie plus the staff, with open findings ──────
  [
    "GET", "/api/staff/roster",
    async ({ env, t }) => {
      let agents = null;
      let set = null;
      const phase1 = await d1Guarded("staff_agents", async () => {
        const [a, s] = await Promise.all([
          env.DB.prepare(`SELECT name, role, accountable, autonomy, cap, status FROM staff_agents ORDER BY name`).all(),
          settingsOf(env),
        ]);
        agents = a.results || [];
        set = s;
        return null;
      });
      if (phase1) return phase1;
      const names = [ARCHIE, ...agents.filter((a) => a.name !== ARCHIE).map((a) => a.name)];
      const laneMap = laneMapOf(set["staff.spend.lane_map"]);
      const win = windowOf(set["staff.spend.window_days"]);

      // Phase 2: the findings count, the tick seeks and the spend, together.
      const open = new Map();
      const findings = d1Guarded("staff_findings", async () => {
        // sql-ident-ok: CLOSED_SQL is a module const list of quoted literal status words
        const { results } = await env.DB.prepare(
          `SELECT agent, COUNT(*) AS n FROM staff_findings WHERE status NOT IN (${CLOSED_SQL}) GROUP BY agent`
        ).all();
        for (const r of results || []) open.set(r.agent, Number(r.n));
        return null;
      });
      const ticksRead = lastTicks(env, names);
      const spendRead = laneMap.invalid ? Promise.resolve("invalid")
        : agentSpend(env, laneMap.map, win.days, t).catch(() => "unread");
      const [phase2, lastTick, spend] = await Promise.all([findings, ticksRead, spendRead]);
      if (phase2) return phase2;

      const rows = [
        {
          name: ARCHIE, kind: "overlooker", role: set["staff.archie.role"], accountable: set["staff.archie.accountable"],
          autonomy: "per-class", cap: null, status: null,
        },
        ...agents.filter((a) => a.name !== ARCHIE).map((a) => ({
          name: a.name, kind: "staff", role: a.role, accountable: a.accountable,
          autonomy: a.autonomy, cap: a.cap, status: a.status,
        })),
      ].map((a) => ({ ...a, open_findings: open.get(a.name) || 0, precision: null }));
      const sources = { ...SOURCES };
      if (!lastTick) sources.last_tick = "unread";
      for (const r of rows) {
        r.last_tick_at = (lastTick && lastTick.get(r.name)) || null;
        const known = spend instanceof Map && !(r.name === ARCHIE && laneMap.absent);
        const s = known ? spend.get(r.name) : null;
        r.spend_usd = known ? usd(s ? s.today : 0) : null;
        r.spend_usd_7d = known ? usd(s ? s.week : 0) : null;
        r.spend_unpriced = known ? (s ? s.today_unpriced : 0) : null;
        r.spend_unpriced_7d = known ? (s ? s.week_unpriced : 0) : null;
        r.spend_lanes = known ? ((s && s.lanes) || laneMap.map[r.name] || []) : [];
        r.spend_window_days = win.days;
      }
      sources.spend = spend instanceof Map ? "cost_rows"
        : spend === "invalid" ? "invalid: settings staff.spend.lane_map" : "unread";
      if (spend instanceof Map && laneMap.absent) sources.spend_archie = "no lane map row";
      if (win.fallback) sources.spend_window = "default";
      return json(200, { agents: rows, sources, as_of: t });
    },
  ],

  // ── GET /api/staff/findings?agent= — one agent's open findings ─────────────
  [
    "GET", "/api/staff/findings",
    async ({ env, url, t }) => {
      const name = agentOf(url.searchParams.get("agent"));
      if (name === null) return bad("agent");
      if (name !== ARCHIE) {
        const known = await d1Guarded("staff_agents", async () => {
          const row = await env.DB.prepare(`SELECT name FROM staff_agents WHERE name=?1`).bind(name).first();
          return row ? null : json(404, { error: "agent not found" });
        });
        if (known) return known;
      }
      return d1Guarded("staff_findings", async () => {
        // sql-ident-ok: COLUMNS, CLOSED_SQL and FINDINGS_MAX are module consts
        const { results } = await env.DB.prepare(
          `SELECT ${COLUMNS} FROM staff_findings
            WHERE agent=?1 AND status NOT IN (${CLOSED_SQL})
            ORDER BY id DESC LIMIT ${FINDINGS_MAX + 1}`
        ).bind(name).all();
        const list = results || [];
        return json(200, {
          agent: name, findings: list.slice(0, FINDINGS_MAX), truncated: list.length > FINDINGS_MAX, as_of: t,
        });
      });
    },
  ],

  // ── GET /api/staff/finding?id= — one finding, every column ─────────────────
  [
    "GET", "/api/staff/finding",
    async ({ env, url }) => {
      const raw = (url.searchParams.get("id") || "").trim();
      if (!ID_RE.test(raw)) return bad("id");
      return d1Guarded("staff_findings", async () => {
        const row = await env.DB.prepare(`SELECT * FROM staff_findings WHERE id=?1`).bind(Number(raw)).first();
        if (!row) return json(404, { error: "finding not found" });
        return json(200, { finding: { ...row, ...labelsOf(row.source_labels) } });
      });
    },
  ],
];
