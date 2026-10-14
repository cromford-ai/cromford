// block-classify reset route — BH-5915: re-open a classify run that
// bin/lesson-classify.sh parked because the lead report was cut at the worker's
// 4000-unit artifact cap. The one-shot `bin/lesson-classify.sh
// --requeue-truncated` calls it once per parked-<id> marker on the hub.
//
// The worker holds the park reason (the marker file is empty), so the reset
// is ONE conditional UPDATE: only a `failed` run whose error names the cap, and
// not already requeued. It sets attempts to 0, so `pending` lists the run again
// even at the attempt cap, and prefixes the error with `requeued: `, so a second
// call is a replay. The next claim sets error to NULL, so a run that parks for
// the cap again can be reset again.
//
// Behind the HARNESS_SECRET bearer like every block-classify route (not in
// OPEN_ROUTES). D1 has no RLS; the bearer is the admin-only gate.

import { json, d1Guarded } from "../lib/http.js";

const CAP_PHRASE = "%4000-unit artifact cap%"; // the text bin/lesson-classify.sh writes when it parks a cut report
const isId = (v) => typeof v === "number" && Number.isInteger(v) && v >= 1 && v <= Number.MAX_SAFE_INTEGER;
const runOut = (r) => r && ({
  verdict_id: r.verdict_id, status: r.status, attempts: Number(r.attempts), model: r.model,
  error: r.error, findings: Number(r.findings), updated_at: r.updated_at,
});

export const routes = [
  // ── POST /api/block-classify/reset {verdict_id} ─────────────────────────
  // 200 {reset:true} when the run changed; 200 {replay:true} when it is already
  // requeued; 404 no run; 409 not_cap_parked for any other run.
  [
    "POST", "/api/block-classify/reset",
    async ({ env, body, t }) => {
      const b = body || {};
      if (!isId(b.verdict_id)) return json(400, { error: "verdict_id" });
      return d1Guarded("block_classify_runs", async () => {
        const res = await env.DB.prepare(
          `UPDATE block_classify_runs SET attempts = 0, error = 'requeued: ' || error, updated_at = ?2
            WHERE verdict_id = ?1 AND status = 'failed' AND error LIKE ?3 AND error NOT LIKE 'requeued:%'`
        ).bind(b.verdict_id, t, CAP_PHRASE).run();
        const row = await env.DB.prepare("SELECT * FROM block_classify_runs WHERE verdict_id=?1").bind(b.verdict_id).first();
        if (!row) return json(404, { error: "no run" });
        if (Number(res.meta && res.meta.changes) === 1) return json(200, { reset: true, run: runOut(row) });
        if (row.status === "failed" && typeof row.error === "string" && row.error.startsWith("requeued: ")) {
          return json(200, { replay: true, run: runOut(row) });
        }
        return json(409, { error: "not_cap_parked", run: runOut(row) });
      });
    },
  ],
];
