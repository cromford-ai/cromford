// period routes (BH-9304, BH-9120.0): the shared period knobs.
//
// GET /api/period/knobs -> 200 {knobs: {max_range_days, csv_row_cap,
//   default_preset, max_buckets}, source: {<key>: 'row' | 'fallback'}, as_of}.
//   One settings statement (readPeriodKnobs). Bearer-gated like every ROUTES
//   row. The console reads it through the coord proxy as
//   /api/coord/period/knobs, for the default period of a screen.

import { json } from "../lib/http.js";
import { readPeriodKnobs } from "../lib/period.js";

export const routes = [
  [
    "GET", "/api/period/knobs",
    async ({ env, t }) => {
      const { source, ...knobs } = await readPeriodKnobs(env);
      return json(200, { knobs, source, as_of: t });
    },
  ],
];
