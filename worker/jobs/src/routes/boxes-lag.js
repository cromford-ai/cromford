// boxes-lag routes — the harness version lag the fleet-version-check lane
// computes, stored for the console Machines view (BH-7191.4).
//
//   POST /api/boxes/lag {rows:[{box, lag_min}]}
//
// The writer is fvc_sink (bin/lib/fleet-version-sink.sh), once per lane tick.
// UPDATE ONLY: a box with no box_status row gets none. The row is the box's
// own report (lane-gate, self-report), and a lag for a box nobody reports is
// not worth a row the console would list as a real box.
//
// lag_checked_at is the worker clock `t`, never a box clock: the console reads
// it as "how old is this number" and calls a stale 0 `unchecked`.
//
// A bad row (a name laneName refuses, a lag_min that is not a whole number in
// 0..LAG_MAX_MIN) is counted in `rejected` and never written. A body that is
// not a list of 1..ROWS_MAX rows is a 400 and writes nothing.

import { json } from "../lib/http.js";
import { ensureColumns, laneName } from "../lib/core.js";

// Far above the fleet (about 12 boxes); fvc_sink stops at the same number.
const ROWS_MAX = 200;
// One year in minutes. A larger number is not a lag, it is a broken reader.
const LAG_MAX_MIN = 525600;

export const routes = [
  [
    "POST", "/api/boxes/lag",
    async ({ env, t, body }) => {
      const rows = body && body.rows;
      if (!Array.isArray(rows) || rows.length === 0 || rows.length > ROWS_MAX) {
        return json(400, { error: `rows must be a list of 1 to ${ROWS_MAX} {box, lag_min}` });
      }
      // A box twice in one body: the last row wins.
      const want = new Map();
      let rejected = 0;
      for (const r of rows) {
        const box = r && typeof r === "object" ? laneName(r.box) : "";
        const lag = r && typeof r === "object" ? r.lag_min : undefined;
        if (!box || !Number.isInteger(lag) || lag < 0 || lag > LAG_MAX_MIN) { rejected += 1; continue; }
        want.set(box, lag);
      }
      const unknown = [];
      let updated = 0;
      if (want.size) {
        await ensureColumns(env, "box_status");
        const boxes = [...want.keys()];
        const res = await env.DB.batch(boxes.map((b) => env.DB.prepare(
          `UPDATE box_status SET harness_lag_min=?2, lag_checked_at=?3 WHERE box=?1`
        ).bind(b, want.get(b), t)));
        boxes.forEach((b, i) => {
          const n = Number((res[i] && res[i].meta && res[i].meta.changes) || 0);
          if (n > 0) updated += 1; else unknown.push(b);
        });
      }
      return json(200, { updated, unknown, rejected, as_of: t });
    },
  ],
];
