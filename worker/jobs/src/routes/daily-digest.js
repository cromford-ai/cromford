// daily-digest route — BH-3703 (BH-3688 slice 1): one UTC day of the fleet,
// section by section, for the daily Telegram digest. Read-only.
//
// Every explicit param out of range is a 400, never clamped. Each reader runs
// under guardSections, so a throw in one marks its own sections ok:false and
// the other reader still answers.

import { json } from "../lib/http.js";
import { dayWindow, isEmptyDigest, guardSections, SECTION_KEYS } from "../lib/daily-digest/shape.js";
import { readCoreSections } from "../lib/daily-digest/core-sections.js";
import { readStateSections } from "../lib/daily-digest/state-sections.js";
import { sigKeyOf } from "./verdicts.js";

// Read limits, not business parameters: the lane passes its knob values in.
const INT_PARAMS = { limit: [1, 100, 20], loop_min: [2, 20, 2], trip: [1, 100, 2] };
const HUMAN_MAX = 20;
const HUMAN_LEN = 128;

export const routes = [
  [
    "GET", "/api/metrics/daily-digest",
    async ({ env, url, t }) => {
      const q = url.searchParams;
      const win = dayWindow(q.get("day"), t);
      if (!win) return json(400, { error: "day must be YYYY-MM-DD, a real date, not after today UTC" });

      const n = {};
      for (const [k, [lo, hi, def]] of Object.entries(INT_PARAMS)) {
        if (!q.has(k)) { n[k] = def; continue; }
        const v = q.get(k);
        if (!/^\d+$/.test(v) || Number(v) < lo || Number(v) > hi) {
          return json(400, { error: `${k} must be an integer ${lo}..${hi}` });
        }
        n[k] = Number(v);
      }

      const humanActors = (q.get("human") || "").split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
      if (humanActors.length > HUMAN_MAX || humanActors.some((s) => s.length > HUMAN_LEN)) {
        return json(400, { error: `human takes at most ${HUMAN_MAX} names of at most ${HUMAN_LEN} chars` });
      }

      const opts = { limit: n.limit, loopMin: n.loop_min, trip: n.trip, humanActors, sigKey: sigKeyOf(env), env, now: t };
      const db = env.DB;
      const core = await guardSections(SECTION_KEYS.core, () => readCoreSections(db, win, opts));
      const state = await guardSections(SECTION_KEYS.state, () => readStateSections(db, win, opts));
      const sections = { ...core, ...state };
      return json(200, { ...win, as_of: t, empty: isEmptyDigest(sections), ...sections });
    },
  ],
];
