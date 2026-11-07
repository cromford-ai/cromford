// d1-stmt-stats routes — BH-9076 (slice 5 of BH-9067): the top D1 statements.
//
// NEW family (test/route-table.d/bh-9076-d1-stmt-stats.txt), behind the main
// bearer like every jobs route.
//
//   GET /api/d1/stmt-stats/top?hours=24&n=20
//     -> 200 {hours, n, since_hour, sample_pct, rows:[{sql_hash, sql_text,
//             calls, rows_read, rows_per_call}], as_of}
//        The statements src/lib/stmt-stats.js counted in d1_stmt_stats over
//        the last `hours` UTC hours (the current hour included), most calls
//        first. `calls` and `rows_read` are SAMPLED counts: sample_pct is in
//        the answer so a reader scales them. hours is 1..d1.stmt_stats_hours_max
//        and n is 1..d1.stmt_stats_top_max; anything else is 400 naming the
//        field (refused, never clamped).
//
// The read is one statement: a range on idx_d1_stmt_stats_hour_calls (hour),
// grouped by sql_hash, at most hours_max * max_keys rows.

import { d1Guarded, json } from "../lib/http.js";
import { settingsRows } from "../lib/settings-cache.js";
import { intSetting } from "./retention.js";

// Code fallbacks; each names the settings row it stands in for
// (schema.d/202611070338-bh-9076-d1-stmt-stats.sql seeds every one).
const DEF = {
  hours: 24,        // the default ?hours= (the ticket's GET example)
  n: 20,            // the default ?n=
  hours_max: 336,   // d1.stmt_stats_hours_max
  top_max: 100,     // d1.stmt_stats_top_max
  sample_pct: 1,    // d1.stmt_stats_sample_pct
};

export const TOP_SQL = `SELECT sql_hash, MAX(sql_text) AS sql_text, SUM(calls) AS calls, SUM(rows_read) AS rows_read
  FROM d1_stmt_stats WHERE hour >= ?1 GROUP BY sql_hash ORDER BY calls DESC, sql_hash ASC LIMIT ?2`;

// A query param as a whole number in [1, max], its default when absent, or
// null when it is anything else.
function param(url, name, def, max) {
  const raw = url.searchParams.get(name);
  if (raw === null) return def;
  if (!/^\d+$/.test(raw.trim())) return null;
  const v = Number(raw.trim());
  return v >= 1 && v <= max ? v : null;
}

export const routes = [
  [
    "GET", "/api/d1/stmt-stats/top",
    ({ env, url, t }) => d1Guarded("d1_stmt_stats", async () => {
      const { byKey } = await settingsRows(env);
      const hoursMax = intSetting(byKey, "d1.stmt_stats_hours_max", DEF.hours_max, 1, 8760);
      const topMax = intSetting(byKey, "d1.stmt_stats_top_max", DEF.top_max, 1, 1000);
      const hours = param(url, "hours", Math.min(DEF.hours, hoursMax), hoursMax);
      if (hours === null) return json(400, { error: `hours must be a whole number from 1 to ${hoursMax}`, field: "hours" });
      const n = param(url, "n", Math.min(DEF.n, topMax), topMax);
      if (n === null) return json(400, { error: `n must be a whole number from 1 to ${topMax}`, field: "n" });
      const since = new Date(Date.parse(t) - (hours - 1) * 3600e3).toISOString().slice(0, 13);
      const res = await env.DB.prepare(TOP_SQL).bind(since, n).all();
      const rows = ((res && res.results) || []).map((r) => {
        const calls = Number(r.calls), rowsRead = Number(r.rows_read);
        return {
          sql_hash: r.sql_hash, sql_text: r.sql_text, calls, rows_read: rowsRead,
          rows_per_call: calls > 0 ? Math.round((rowsRead / calls) * 10) / 10 : null,
        };
      });
      return json(200, {
        hours, n, since_hour: since,
        sample_pct: intSetting(byKey, "d1.stmt_stats_sample_pct", DEF.sample_pct, 0, 100),
        rows, as_of: t,
      });
    }),
  ],
];
