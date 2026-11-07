// review-counts routes — BH-9154 (Fix 5 of BH-9066): the daily review counter.
//
// NEW family (test/route-table.d/bh-9154-review-counts.txt), behind the main
// bearer like every jobs route. The console reads it through the coord proxy
// for the REVIEW COUNTS panel on the Lead reviews screen.
//
//   GET  /api/review-counts?days=&project=
//     -> 200 {kinds, unmapped, days:[{day, kinds:{<kind>: n|null}, reviews,
//             merged_prs, rebinds, per_merged}], max_days, rolled_at, as_of}
//        days is 1..review_counts.max_days (default that max); anything else
//        is 400 (D11: refused, never clamped). Newest day first. A kind with no
//        rule in review_counts.kind_map is null on every day: unknown, never 0.
//        Rolls up first when the last rollup is older than
//        review_counts.rollup_every_s.
//   POST /api/review-counts/rollup  -> 200 {rows, since_day, rolled_at}
//
// THE ROLLUP. It recomputes the last review_counts.rollup_days days only, and
// never reads further back than that:
//   reviews     cost_rows ts >= since (idx_cost_rows_ts), one row = one model
//               call; rc 74..79 rows are refusals (nothing was called) and are
//               not counted. stage/lane_id -> kind through the kind map.
//   merged PRs  ledgers kind='merge' status='merged' updated_at >= since
//               (idx_ledgers_kind_status_updated); the repo in the PR url maps
//               to a project through the projects table, else its name.
//   rebinds     stage_events stage='review-saving' verdict='REUSED'
//               created_at >= since (idx_events_stage_created), project from
//               the jobs row (its primary key).
// Each read is grouped in SQL, so the rows that come back are (day, project,
// stage, lane) groups, not source rows. The write is one batch: delete the
// window's days, insert the new rows, stamp the mark.
//
// Deterministic, no model anywhere on this path.

import { d1Guarded, json } from "../lib/http.js";
import { settingsRows } from "../lib/settings-cache.js";

export const REVIEW_KINDS = ["lens", "fix-rereview", "lead", "conductor", "autopilot", "rescue", "resolver"];
const TOTAL = "total";
const MARK = "review-counts";
// Code fallbacks; each names the settings row it stands in for
// (schema.d/202611062026-bh-9154-review-counts.sql seeds every one).
const DEF = {
  max_days: 30,          // review_counts.max_days
  rollup_days: 2,        // review_counts.rollup_days
  rollup_every_s: 3600,  // review_counts.rollup_every_s
};
// review_counts.kind_map fallback, the same list the seed row holds.
const DEF_KIND_MAP = [
  { kind: "lead", stage: "lead-review" },
  { kind: "conductor", stage: "review", lane: "merge-conductor" },
  { kind: "autopilot", stage: "review", lane: "review-autopilot" },
  { kind: "rescue", stage: "review", lane: "review-rescue" },
  { kind: "resolver", stage: "review", lane: "blocked-resolver" },
  { kind: "lens", stage: "review", lane: "fly-pool" },
];

const DAY_MS = 86400e3;
const dayMinus = (t, days) => new Date(Date.parse(t) - days * DAY_MS).toISOString().slice(0, 10);

function intRow(byKey, key, def, lo, hi) {
  const row = byKey.get(key);
  const v = row ? String(row.value).trim() : "";
  if (!/^\d+$/.test(v)) return def;
  const n = Number(v);
  return n >= lo && n <= hi ? n : def;
}

// The kind map row as a rule list. A row that does not parse, or holds a rule
// with an unknown kind or no stage, falls back to the code default whole: a
// half-read map would count some kinds and silently drop others.
export function kindMap(byKey) {
  const row = byKey.get("review_counts.kind_map");
  if (!row) return DEF_KIND_MAP;
  try {
    const v = JSON.parse(String(row.value));
    if (!Array.isArray(v) || !v.length) return DEF_KIND_MAP;
    const ok = v.every((r) => r && REVIEW_KINDS.includes(r.kind) && typeof r.stage === "string" && r.stage
      && (r.lane === undefined || (typeof r.lane === "string" && r.lane)));
    return ok ? v : DEF_KIND_MAP;
  } catch { return DEF_KIND_MAP; }
}
const kindOf = (map, stage, lane) => {
  const r = map.find((x) => x.stage === stage && (x.lane === undefined || x.lane === lane));
  return r ? r.kind : null;
};

export const COST_SQL =
  `SELECT substr(ts, 1, 10) AS day, project, stage, lane_id AS lane, COUNT(*) AS n FROM cost_rows
    WHERE ts >= ?1 AND project IS NOT NULL AND project <> '' AND stage IS NOT NULL
      AND (rc IS NULL OR rc < 74 OR rc > 79)
    GROUP BY 1, 2, 3, 4`;
// 'https://github.com/' is 19 chars, so the repo starts at 20 and ends before '/pull/'.
export const MERGES_SQL =
  `SELECT m.day AS day, COALESCE(p.project, substr(m.repo, instr(m.repo, '/') + 1)) AS project, COUNT(*) AS n
     FROM (SELECT substr(updated_at, 1, 10) AS day,
                  substr(key, 20, instr(substr(key, 20), '/pull/') - 1) AS repo
             FROM ledgers
            WHERE kind = 'merge' AND status = 'merged' AND updated_at >= ?1
              AND key LIKE 'https://github.com/%/pull/%') m
     LEFT JOIN projects p ON p.repo = m.repo
    GROUP BY 1, 2`;
export const REBINDS_SQL =
  `SELECT substr(e.created_at, 1, 10) AS day, j.project AS project, COUNT(*) AS n
     FROM stage_events e JOIN jobs j ON j.id = e.job_id
    WHERE e.stage = 'review-saving' AND e.verdict = 'REUSED' AND e.created_at >= ?1
    GROUP BY 1, 2`;

// rollup(env, t, byKey) -> {rows, since_day, rolled_at}
export async function rollup(env, t, byKey) {
  const days = intRow(byKey, "review_counts.rollup_days", DEF.rollup_days, 1, 14);
  const sinceDay = dayMinus(t, days - 1);
  const since = `${sinceDay}T00:00:00Z`;
  const map = kindMap(byKey);
  const [cost, merges, rebinds] = await Promise.all([
    env.DB.prepare(COST_SQL).bind(since).all(),
    env.DB.prepare(MERGES_SQL).bind(since).all(),
    env.DB.prepare(REBINDS_SQL).bind(since).all(),
  ]);
  const out = new Map();  // `${day}\t${project}\t${kind}` -> row
  const row = (day, project, kind) => {
    const k = `${day}\t${project}\t${kind}`;
    if (!out.has(k)) {
      out.set(k, kind === TOTAL
        ? { day, project, kind, n: 0, merged_prs: 0, rebinds: 0 }
        : { day, project, kind, n: 0, merged_prs: null, rebinds: null });
    }
    return out.get(k);
  };
  for (const r of cost.results || []) {
    const kind = kindOf(map, r.stage, r.lane);
    if (!kind) continue;
    row(r.day, r.project, kind).n += Number(r.n);
    row(r.day, r.project, TOTAL).n += Number(r.n);
  }
  for (const r of merges.results || []) if (r.project) row(r.day, r.project, TOTAL).merged_prs += Number(r.n);
  for (const r of rebinds.results || []) if (r.project) row(r.day, r.project, TOTAL).rebinds += Number(r.n);
  const rows = [...out.values()];
  await env.DB.batch([
    env.DB.prepare("DELETE FROM review_counts_daily WHERE day >= ?1").bind(sinceDay),
    // One statement, two binds: the rows ride as one JSON list (the D1 100-bind cap).
    env.DB.prepare(
      `INSERT INTO review_counts_daily (day, project, kind, n, merged_prs, rebinds, updated_at)
       SELECT json_extract(value, '$.day'), json_extract(value, '$.project'), json_extract(value, '$.kind'),
              json_extract(value, '$.n'), json_extract(value, '$.merged_prs'), json_extract(value, '$.rebinds'), ?2
         FROM json_each(?1)`
    ).bind(JSON.stringify(rows), t),
    env.DB.prepare(
      `INSERT INTO review_counts_mark (name, rolled_at) VALUES (?1, ?2)
       ON CONFLICT(name) DO UPDATE SET rolled_at = excluded.rolled_at`
    ).bind(MARK, t),
  ]);
  return { rows: rows.length, since_day: sinceDay, rolled_at: t };
}

export const READ_ALL_SQL =
  `SELECT day, kind, SUM(n) AS n, SUM(merged_prs) AS merged_prs, SUM(rebinds) AS rebinds
     FROM review_counts_daily WHERE day >= ?1 GROUP BY day, kind ORDER BY day DESC`;
export const READ_PROJECT_SQL =
  `SELECT day, kind, n, merged_prs, rebinds
     FROM review_counts_daily WHERE project = ?2 AND day >= ?1 ORDER BY day DESC`;

// The read rows -> one entry per day, newest first.
export function shapeDays(rows, unmapped) {
  const byDay = new Map();
  for (const r of rows) {
    if (!byDay.has(r.day)) {
      const kinds = Object.fromEntries(REVIEW_KINDS.map((k) => [k, unmapped.includes(k) ? null : 0]));
      byDay.set(r.day, { day: r.day, kinds, reviews: 0, merged_prs: 0, rebinds: 0, per_merged: null });
    }
    const d = byDay.get(r.day);
    if (r.kind === TOTAL) {
      d.reviews = Number(r.n);
      d.merged_prs = Number(r.merged_prs || 0);
      d.rebinds = Number(r.rebinds || 0);
    } else if (REVIEW_KINDS.includes(r.kind) && !unmapped.includes(r.kind)) {
      d.kinds[r.kind] = Number(r.n);
    }
  }
  const days = [...byDay.values()].sort((a, b) => (a.day < b.day ? 1 : a.day > b.day ? -1 : 0));
  for (const d of days) d.per_merged = d.merged_prs > 0 ? d.reviews / d.merged_prs : null;
  return days;
}

export const routes = [
  [
    "GET", "/api/review-counts",
    ({ env, url, t }) => d1Guarded("review_counts_daily", async () => {
      const { byKey } = await settingsRows(env);
      const max = intRow(byKey, "review_counts.max_days", DEF.max_days, 1, 366);
      const raw = url.searchParams.get("days");
      let days = max;
      if (raw !== null) {
        if (!/^\d+$/.test(raw) || Number(raw) < 1 || Number(raw) > max) {
          return json(400, { error: `days must be a whole number 1..${max} (review_counts.max_days)` });
        }
        days = Number(raw);
      }
      const project = (url.searchParams.get("project") || "").trim() || null;
      const every = intRow(byKey, "review_counts.rollup_every_s", DEF.rollup_every_s, 0, 86400);
      const mark = await env.DB.prepare("SELECT rolled_at FROM review_counts_mark WHERE name = ?1").bind(MARK).first();
      let rolledAt = mark ? mark.rolled_at : null;
      if (!rolledAt || every === 0 || Date.parse(t) - Date.parse(rolledAt) >= every * 1000) {
        rolledAt = (await rollup(env, t, byKey)).rolled_at;
      }
      const sinceDay = dayMinus(t, days - 1);
      const res = project
        ? await env.DB.prepare(READ_PROJECT_SQL).bind(sinceDay, project).all()
        : await env.DB.prepare(READ_ALL_SQL).bind(sinceDay).all();
      const mapped = new Set(kindMap(byKey).map((r) => r.kind));
      const unmapped = REVIEW_KINDS.filter((k) => !mapped.has(k));
      return json(200, {
        kinds: REVIEW_KINDS, unmapped, days: shapeDays(res.results || [], unmapped),
        max_days: max, rolled_at: rolledAt, as_of: t,
      });
    }),
  ],
  [
    "POST", "/api/review-counts/rollup",
    ({ env, t }) => d1Guarded("review_counts_daily", async () => {
      const { byKey } = await settingsRows(env);
      return json(200, await rollup(env, t, byKey));
    }),
  ],
];
