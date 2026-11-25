// staff scoreboard route — BH-9422 (C4 of BH-9187): every staff agent's lever
// scorecard in one read, for the weekly overlook report (bin/archie-overlook.sh),
// Archie's turn briefing (bin/lib/staff-scoreboard.sh) and the console /staff
// METRICS section (console-ui/src/screens/staff/staff-metrics.js).
//
// GET /api/staff/levers/scoreboard[?days=1..staff.scorecard_days_max (30)]
//   no days= is the row staff.scorecard_days (7), the same daysOf rule as
//   GET /api/staff/levers/scorecard. Answers {ok, days, as_of, agents:[...]},
//   one entry per staff_agents row (ordered by name) except archie, and each
//   entry is exactly scorecardOf (staff-levers.js), the scorecard answer
//   without ok. An agent with no staff.<agent>.metric row has metric null and
//   null samples. The roster read and the settings read run in parallel, then
//   every agent's three reads run in one Promise.all. The list size is the
//   staff_agents row count: no literal limit. No write.
// Note: docs/notes/2026-11-11-BH-9422-staff-report-screens.md.

import { json, d1Guarded } from "../lib/http.js";
import { settingsRows } from "../lib/settings-cache.js";
import { daysOf, scorecardOf } from "./staff-levers.js";

// The roster read, exported for the EXPLAIN test. staff_agents holds one row
// per staff agent (8 today).
export const ROSTER_SQL = `SELECT name FROM staff_agents ORDER BY name`;
// Archie is not a staff agent: it owns no lever metric.
const NOT_STAFF = "archie";

export const routes = [
  // ── GET /api/staff/levers/scoreboard — every agent's scorecard ─────────────
  [
    "GET", "/api/staff/levers/scoreboard",
    async ({ env, t, url }) => {
      const dq = url.searchParams.get("days");
      if (dq !== null && !/^\d+$/.test(dq)) return json(400, { error: "days" });

      return d1Guarded("staff_lever_actions", async () => {
        const [roster, { byKey }] = await Promise.all([env.DB.prepare(ROSTER_SQL).all(), settingsRows(env)]);
        const d = daysOf(byKey, dq);
        if (d.error) return json(400, { error: d.error });
        const names = ((roster && roster.results) || []).map((r) => r.name).filter((n) => n !== NOT_STAFF);
        const agents = await Promise.all(names.map((n) => scorecardOf(env, n, byKey, d.days, t)));
        return json(200, { ok: true, days: d.days, as_of: t, agents });
      });
    },
  ],
];
