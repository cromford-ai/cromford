// cost-hourly.js — the spend windows of GET /api/progress/stamps, read from
// hourly buckets instead of from every cost_rows row in the widest window.
//
// The old read summed every priced cost_rows row of the last 7 days (the
// default lookback) on every call: 129,155 rows a call on 2026-10-16
// (BH-7164). Now each call:
//   1. FOLDS the cost_rows rows above the cost_fold_mark watermark into
//      cost_project_hourly (one bucket per project and hour). cost_rows rows
//      never change ts, project or cost_usd after the insert, so "rowid >
//      mark" is exactly the set not summed yet. The fold and the mark advance
//      are one D1 batch (one transaction), so two calls never sum one range.
//   2. splits each window into a raw lead edge (the part of the first hour
//      after the cut), whole-hour buckets, and the raw current hour
//      (windowParts), and reads the three in parallel.
// A mark above MAX(rowid) (the table emptied or renumbered) clears the
// buckets and refolds from 0.
//
// readCost() answers the same shape on both paths. If the fold or a summary
// read throws, it logs one line and runs the old single query (legacyCost):
// the answer stays the same, only the cost of the read changes.
import { ensureTable } from "./core.js";

const HOUR_MS = 3600e3;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
export const hourKey = (ms) => iso(ms).slice(0, 13);
const newer = (a, b) => (!a ? b || null : !b ? a : (a > b ? a : b));
const MARK = "progress.cost";
const MAX_ROWID = "(SELECT COALESCE(MAX(rowid), 0) FROM cost_rows)";
const LAST_ROWID = `(SELECT last_rowid FROM cost_fold_mark WHERE name = '${MARK}')`;

// The fold, in batch order. MATERIALIZED keeps the rowid range read first,
// and `WHERE true` is SQLite's parse rule for INSERT ... SELECT ... ON
// CONFLICT (the routes/wakes.js fold uses both for the same reasons).
export const FOLD_SQL = [
  `INSERT OR IGNORE INTO cost_fold_mark (name, last_rowid) VALUES ('${MARK}', 0)`,
  `DELETE FROM cost_project_hourly WHERE ${LAST_ROWID} > ${MAX_ROWID}`,
  `UPDATE cost_fold_mark SET last_rowid = 0 WHERE name = '${MARK}' AND last_rowid > ${MAX_ROWID}`,
  `WITH w AS MATERIALIZED (
     SELECT project, ts, cost_usd FROM cost_rows
      WHERE rowid > ${LAST_ROWID}
        AND ts IS NOT NULL AND COALESCE(cost_usd, 0) > 0 AND project IS NOT NULL AND project <> '')
   INSERT INTO cost_project_hourly (project, hour, usd, n, max_ts)
   SELECT project, substr(ts, 1, 13), SUM(cost_usd), COUNT(*), MAX(ts) FROM w WHERE true
    GROUP BY project, substr(ts, 1, 13)
   ON CONFLICT(project, hour) DO UPDATE SET
     usd = usd + excluded.usd, n = n + excluded.n, max_ts = MAX(max_ts, excluded.max_ts)`,
  `UPDATE cost_fold_mark SET last_rowid = ${MAX_ROWID} WHERE name = '${MARK}'`,
];

export async function foldCostHourly(env) {
  await ensureTable(env, "cost_project_hourly");
  await ensureTable(env, "cost_fold_mark");
  await env.DB.batch(FOLD_SQL.map((sql) => env.DB.prepare(sql)));
}

// windowParts(cutMs, nowMs) — the window [cut, now] as three disjoint parts.
// H is the current hour. `raw` is the cut the current-hour raw read uses
// (ts >= raw). `edge` is the raw lead edge [a, b) in ISO, or null. `buckets`
// is the hour-key range [from, to) of whole hours, or null.
export function windowParts(cutMs, nowMs) {
  const H = Math.floor(nowMs / HOUR_MS) * HOUR_MS;
  if (cutMs >= H) return { raw: iso(cutMs), edge: null, buckets: null };
  const A = Math.min(Math.ceil(cutMs / HOUR_MS) * HOUR_MS, H);
  return {
    raw: iso(H),
    edge: cutMs < A ? [iso(cutMs), iso(A)] : null,
    buckets: A < H ? [hourKey(A), hourKey(H)] : null,
  };
}

const PRICED = "COALESCE(cost_usd, 0) > 0";

// The three reads, built from the windows. Exported so a test can EXPLAIN
// the exact statements with their binds. Windows: index 0 is the lookback
// (it gives the last priced ts), 1.. are the long cuts.
export function costReads({ shortCut, lookback, longCuts, nowMs }) {
  const wins = [lookback, ...longCuts].map((c) => windowParts(Date.parse(c), nowMs));
  const lo = [Date.parse(shortCut), Math.floor(nowMs / HOUR_MS) * HOUR_MS].reduce((a, b) => Math.min(a, b));
  // R: the raw recent rows, per stage (the short window is per stage).
  const longCols = wins.slice(1).map((_, i) => `, SUM(CASE WHEN ts >= ?${i + 4} THEN cost_usd ELSE 0 END) AS l${i}`).join("");
  const R = {
    sql: `WITH c AS MATERIALIZED (
            SELECT project, stage, ts, cost_usd FROM cost_rows WHERE ts >= ?1 AND ${PRICED})
          SELECT project, stage,
                 SUM(CASE WHEN ts >= ?2 THEN cost_usd ELSE 0 END) AS short_usd,
                 MAX(CASE WHEN ts >= ?3 THEN ts END) AS last_ts${longCols}
            FROM c GROUP BY project, stage`,
    binds: [iso(lo), shortCut, ...wins.map((w) => w.raw)],
  };
  // E: one branch per distinct non-empty lead edge.
  const edges = [];
  const edgeOf = wins.map((w) => {
    if (!w.edge) return -1;
    const k = edges.findIndex((e) => e[0] === w.edge[0] && e[1] === w.edge[1]);
    return k >= 0 ? k : edges.push(w.edge) - 1;
  });
  const E = edges.length ? {
    sql: edges.map((_, k) =>
      `SELECT ${k} AS w, project, SUM(cost_usd) AS usd, MAX(ts) AS max_ts FROM cost_rows
        WHERE ts >= ?${2 * k + 1} AND ts < ?${2 * k + 2} AND ${PRICED} GROUP BY project`).join(" UNION ALL "),
    binds: edges.flat(),
  } : null;
  // B: the whole-hour buckets. A window with no bucket range binds the
  // current hour, which no row inside the WHERE reaches.
  const hnow = hourKey(nowMs);
  const from = wins.map((w) => (w.buckets ? w.buckets[0] : hnow));
  const hmin = from.reduce((a, b) => (a < b ? a : b));
  const B = hmin < hnow ? {
    sql: `SELECT project, MAX(CASE WHEN hour >= ?3 THEN max_ts END) AS last_ts${
      from.slice(1).map((_, i) => `, SUM(CASE WHEN hour >= ?${i + 4} THEN usd ELSE 0 END) AS l${i}`).join("")}
            FROM cost_project_hourly WHERE hour >= ?1 AND hour < ?2 GROUP BY project`,
    binds: [hmin, hnow, ...from],
  } : null;
  return { R, E, B, edgeOf };
}

// The answer both paths give: short = [{project, stage, usd}] (usd > 0 only),
// long = Map project -> [sum per long cut], last = Map project -> newest
// priced ts in the lookback. A project with no rows in any window is absent;
// a NULL or '' project never counts.
function answer(nLong) {
  const long = new Map(), last = new Map();
  const L = (p) => { if (!long.has(p)) long.set(p, new Array(nLong).fill(0)); return long.get(p); };
  return {
    short: [], long, last,
    add(p, i, usd) { if (p) L(p)[i] += Number(usd || 0); },
    seen(p, ts) { if (p) { L(p); if (ts) last.set(p, newer(last.get(p), ts)); } },
  };
}

export async function readCostWindows(env, w) {
  const { R, E, B, edgeOf } = costReads(w);
  const all = async (q) => (q ? (await env.DB.prepare(q.sql).bind(...q.binds).all()).results || [] : []);
  const [rr, er, br] = await Promise.all([all(R), all(E), all(B)]);
  const out = answer(w.longCuts.length);
  for (const r of rr) {
    if (!r.project) continue;
    if (Number(r.short_usd) > 0) out.short.push({ project: r.project, stage: r.stage, usd: Number(r.short_usd) });
    out.seen(r.project, r.last_ts);
    w.longCuts.forEach((_, i) => out.add(r.project, i, r[`l${i}`]));
  }
  for (const r of er) {
    if (!r.project) continue;
    out.seen(r.project, null);
    edgeOf.forEach((k, wi) => {
      if (k !== Number(r.w)) return;
      if (wi === 0) out.seen(r.project, r.max_ts); else out.add(r.project, wi - 1, r.usd);
    });
  }
  for (const r of br) {
    if (!r.project) continue;
    out.seen(r.project, r.last_ts);
    w.longCuts.forEach((_, i) => out.add(r.project, i, r[`l${i}`]));
  }
  return out;
}

// The read before BH-7164, verbatim: one aggregate over every priced row from
// the widest cut. The fallback when the fold or a summary read fails.
export async function legacyCost(env, { scanCut, shortCut, lookback, longCuts }) {
  const longCols = longCuts.map((_, i) =>
    `SUM(CASE WHEN ts >= ?${i + 4} THEN cost_usd ELSE 0 END) AS l${i}`).join(", ");
  // sql-ident-ok: longCols holds literal SUM text with ?N binds and l<index> aliases
  const rows = (await env.DB.prepare(
    `SELECT project, stage,
            SUM(CASE WHEN ts >= ?2 THEN cost_usd ELSE 0 END) AS short_usd,
            MAX(CASE WHEN ts >= ?3 THEN ts END) AS last_ts${longCols ? `, ${longCols}` : ""}
       FROM cost_rows
      WHERE ts >= ?1 AND COALESCE(cost_usd, 0) > 0
      GROUP BY project, stage`).bind(scanCut, shortCut, lookback, ...longCuts).all()).results || [];
  const out = answer(longCuts.length);
  for (const r of rows) {
    if (!r.project) continue;
    if (Number(r.short_usd) > 0) out.short.push({ project: r.project, stage: r.stage, usd: Number(r.short_usd) });
    out.seen(r.project, r.last_ts);
    longCuts.forEach((_, i) => out.add(r.project, i, r[`l${i}`]));
  }
  return out;
}

// readCost(env, {nowMs, scanCut, shortCut, lookback, longCuts}) — the fold
// and the summary read; the legacy read when either throws. A legacy read
// that throws is the caller's error.
export async function readCost(env, w) {
  try {
    await foldCostHourly(env);
    return await readCostWindows(env, w);
  } catch (e) {
    console.log(`progress/stamps: cost summary unreadable, legacy read — ${e && e.message || e}`);
    return legacyCost(env, w);
  }
}
