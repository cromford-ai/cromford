// lane-spend routes — each lane's spend today against its alert line and its
// ceiling, for Mission Control's /costs LANE SPEND section (BH-6174, BH-5526
// slice C4).
//
// GET /api/metrics/lane-spend[?day=YYYY-MM-DD] reads three tables and writes
// none:
//   cost_rows  today_usd / calls: the rows stamped lane_id=<lane> in
//              [day 00:00Z, day+1 00:00Z). The same rows the ceiling gate sums
//              (GET /api/metrics/llm-spend?lane=<lane>, no stage).
//   ledgers    kind spend_p99, one row per lane, written once a UTC day by the
//              hub's bin/spend-lane-push.sh: status <YYYYMMDD>, detail
//              `p99=<p> days=<d> mult=<m> alert=<a>`. Only the rows of the
//              newest table day not after `day` are current; an older row is a
//              lane that left the table and gives nulls.
//   settings   spend.ceiling.<lane>.day_usd, with the grammar of _llm_ceiling
//              in bin/lib/llm-gate.sh: trimmed; `off` is off; not a plain
//              decimal is junk; <= 0 is zero; else armed. A registry-seed row
//              is ignored, as the box settings cache ignores it. The fleet row
//              switch.spend-ceiling-off reads as lane_switch reads it (1|on|true,
//              0|off|false, anything else no row). A per-box switch row or a
//              flags/ file is not visible here.
//
// A past `day` reads the archive store too (lib/archive-read.js, BH-7035);
// the default day (today) never does. The answer's `archive` says which.
//
// A lane is listed when it has a current p99 row, a ceiling row in any state
// but none, or spend today. It never edits a ceiling: the settings routes stay
// the one writer.

import { json, d1Guarded } from "../lib/http.js";
import { ensureColumns, LANES_REGISTRY, REGISTRY_SEED_ACTOR } from "../lib/core.js";
import { settingsRows } from "../lib/settings-cache.js";
import { archiveReach, readHistory, mergeGroups, worstState } from "../lib/archive-read.js";

const DETAIL_RE = /^p99=([0-9.]+) days=(\d+) mult=([0-9.]+) alert=([0-9.]+)$/;
const CEILING_KEY_RE = /^spend\.ceiling\.([a-z0-9_.-]{1,42})\.day_usd$/;
const LANE_ID_RE = /^[A-Za-z0-9._-]{1,128}$/;
// D1 binds at most 100 parameters; 90 ids + the two ts bounds stay under it.
const CHUNK = 90;

const cents = (v) => (v === null ? null : Math.round(v * 100) / 100);
const byLane = (a, b) => (a.lane_id < b.lane_id ? -1 : a.lane_id > b.lane_id ? 1 : 0);
const dashed = (d) => (d ? `${d.slice(0, 4)}-${d.slice(4, 6)}-${d.slice(6, 8)}` : null);

function ceilingOf(row) {
  if (!row || row.actor === REGISTRY_SEED_ACTOR) return { state: "none", usd: null, raw: null };
  const raw = String(row.value);
  const v = raw.replace(/\s+/g, "");
  if (v === "off") return { state: "off", usd: null, raw };
  if (!/^[0-9]+(\.[0-9]+)?$/.test(v)) return { state: "junk", usd: null, raw };
  if (!(Number(v) > 0)) return { state: "zero", usd: null, raw };
  return { state: "armed", usd: Number(v), raw };
}

function switchOf(row) {
  if (!row || row.actor === REGISTRY_SEED_ACTOR) return null;
  const v = String(row.value).trim();
  if (/^(1|on|true)$/.test(v)) return true;
  if (/^(0|off|false)$/.test(v)) return false;
  return null;
}

export const routes = [
  [
    "GET", "/api/metrics/lane-spend",
    async ({ env, url, t }) => {
      const dayParam = url.searchParams.get("day");
      let day = t.slice(0, 10);
      if (dayParam !== null) {
        const ms = Date.parse(dayParam + "T00:00:00Z");
        const ok = /^\d{4}-\d{2}-\d{2}$/.test(dayParam)
          && !Number.isNaN(ms) && new Date(ms).toISOString().slice(0, 10) === dayParam;
        if (!ok) return json(400, { error: "day must be YYYY-MM-DD" });
        day = dayParam;
      }
      const since = day + "T00:00:00Z";
      const until = new Date(Date.parse(since) + 86400000).toISOString().slice(0, 10) + "T00:00:00Z";
      const dayC = day.replace(/-/g, "");

      return d1Guarded("lane-spend", async () => {
        await ensureColumns(env, "cost_rows");

        // The archive check does not wait on the ledger and settings reads.
        const reachP = archiveReach(env, { table: "cost_rows", since, now: t });
        // The current p99 table: the newest status day not after `day`.
        const led = await env.DB.prepare("SELECT key, status, detail FROM ledgers WHERE kind='spend_p99'").all();
        const ledRows = (led.results || []).filter((r) => /^\d{8}$/.test(String(r.status)) && r.status <= dayC);
        const p99Day = ledRows.reduce((m, r) => (r.status > m ? r.status : m), "") || null;
        const p99 = new Map();
        let skipped = 0;
        for (const r of ledRows) {
          if (r.status !== p99Day) continue;
          const m = DETAIL_RE.exec(String(r.detail || ""));
          if (!m) { skipped += 1; continue; }
          p99.set(r.key, { p99_usd: Number(m[1]), p99_days: Number(m[2]), alert_mult: Number(m[3]), alert_usd: Number(m[4]) });
        }

        const { rows: setRows, byKey } = await settingsRows(env);
        const ceilings = new Map();
        for (const r of setRows) {
          const m = CEILING_KEY_RE.exec(r.key);
          if (!m) continue;
          const c = ceilingOf(r);
          if (c.state !== "none") ceilings.set(m[1], c);
        }

        const registered = new Set((LANES_REGISTRY.lanes || []).map((l) => l.id));
        const ids = [...new Set([...registered, ...p99.keys(), ...ceilings.keys()])].filter((id) => LANE_ID_RE.test(id));
        const reach = await reachP;
        const stmts = [];
        for (let i = 0; i < ids.length; i += CHUNK) {
          const part = ids.slice(i, i + CHUNK);
          const marks = part.map((_, j) => `?${j + 3}`).join(",");
          // sql-ident-ok: marks is a ?N placeholder list built from the chunk index
          const sql = "SELECT lane_id, SUM(COALESCE(cost_usd,0)) AS usd, COUNT(*) AS calls FROM cost_rows" +
            ` WHERE lane_id IN (${marks}) AND ts >= ?1 AND ts < ?2 GROUP BY lane_id`;
          stmts.push(readHistory(env, { table: "cost_rows", since, now: t, hot: { sql, binds: [since, until, ...part] }, reach }));
        }
        const spend = new Map();
        const states = [];
        for (const res of await Promise.all(stmts)) {
          states.push(res.state);
          const { rows } = mergeGroups(res.hot.results || [], res.archive ? res.archive.results || [] : null, {
            by: ["lane_id"], spec: { usd: "sum", calls: "sum" }, pickBy: "lane_id", compare: byLane, limit: Infinity,
          });
          for (const r of rows) spend.set(r.lane_id, { usd: Number(r.usd || 0), calls: Number(r.calls || 0) });
        }
        // No chunk ran: nothing was read, so "read" is never claimed.
        const archive = states.length ? worstState(states) : reach === "reach" ? "not-needed" : reach;

        const lanes = [];
        for (const id of ids) {
          const s = spend.get(id);
          const p = p99.get(id);
          const c = ceilings.get(id) || { state: "none", usd: null, raw: null };
          if (!p && c.state === "none" && !(s && s.usd > 0)) continue;
          const today = cents(s ? s.usd : 0);
          const alertUsd = p ? p.alert_usd : null;
          lanes.push({
            lane: id,
            registered: registered.has(id),
            today_usd: today,
            calls: s ? s.calls : 0,
            p99_usd: p ? p.p99_usd : null,
            p99_days: p ? p.p99_days : null,
            alert_mult: p ? p.alert_mult : null,
            alert_usd: alertUsd,
            ceiling_usd: c.usd,
            ceiling_state: c.state,
            ceiling_raw: c.raw,
            over_alert: alertUsd !== null && today >= alertUsd,
            over_ceiling: c.usd !== null && today >= c.usd,
            pct_of_ceiling: c.usd !== null ? Math.round((today / c.usd) * 1000) / 10 : null,
          });
        }
        lanes.sort((a, b) => b.today_usd - a.today_usd || (a.lane < b.lane ? -1 : a.lane > b.lane ? 1 : 0));

        return json(200, {
          day, since, until,
          p99_day: dashed(p99Day),
          ceiling_switch_fleet: switchOf(byKey.get("switch.spend-ceiling-off")),
          skipped_rows: skipped,
          lanes,
          archive,
          as_of: t,
        });
      });
    },
  ],
];
