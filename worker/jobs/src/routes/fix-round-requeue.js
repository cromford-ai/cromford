// fix-round-requeue route — BH-9906: put a claimed fix round back as queued
// for the same box, so the runner takes it again at once (the next claim adds
// 1 to attempt; this route never touches attempt).
//
// One CAS statement, like every write in fix-rounds.js: claimed → queued, only
// by the box that holds the claim. The answer is the row re-read after it.
// Validation is the finish route's: posId, laneName and record() with the
// 256 KB cap (413 over it, never sliced). record_in replaces the stored one;
// null or absent stores null, the same as the enqueue route.
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable, laneName } from "../lib/core.js";
import { obj, posId, readRow, record, rowOut } from "./fix-rounds.js";

export const routes = [
  [
    "POST", "/api/fix-rounds/requeue",
    ({ env, t, body }) => d1Guarded("fix_round_jobs", async () => {
      const b = obj(body);
      const id = posId(b.id);
      const box = laneName(b.box);
      if (!id) return json(400, { error: "id must be a positive integer" });
      if (!box) return json(400, { error: "box is required and must match [A-Za-z0-9._-]{1,64}" });
      const rec = record(b.record_in, "record_in");
      if (rec.res) return rec.res;
      await ensureTable(env, "fix_round_jobs");
      const moved = await env.DB.prepare(
        `UPDATE fix_round_jobs SET status='queued', record_in=?3, enqueued_at=?4, updated_at=?4
         WHERE id=?1 AND status='claimed' AND claimed_by=?2`
      ).bind(id, box, rec.value, t).run();
      const row = await readRow(env, id);
      if (moved.meta.changes === 1) return json(200, { job: rowOut(row), as_of: t });
      if (!row) return json(404, { error: "no such fix round", id });
      return json(409, {
        error: `requeue refused: row is ${row.status}${row.claimed_by ? ` on ${row.claimed_by}` : ""}`,
        refused: true, scope: "fix-rounds", job: rowOut(row),
      });
    }),
  ],
];
