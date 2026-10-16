// landing-decisions routes — BH-6744 (wave 1 of #6541): the record of what the
// merge conductor WOULD have done with a READY PR under the landing contract
// (bin/lib/mc/landing.sh), one row per (repo, number, head, mode). Table:
// worker/jobs/schema.d/*-bh-6744-landing-decisions.sql.
//
// The writer is landing_shadow in the conductor's READY arm, in shadow (or
// optimistic) mode only. This row is a RECORD: nothing reads it to decide a
// merge, so the bearer alone writes it. A decision for a key is made once, so
// the same key again is 200 existing:true and the stored row is untouched.
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { REPO_RE, prOf, shaOf } from "./verdicts.js";

export const LD_MODES = ["queue", "shadow", "optimistic"];
export const LD_WOULD = ["direct", "queue"];
// The reason token. bin/lib/mc/landing.sh writes the same shape.
export const LD_REASON_RE = /^[a-z][a-z0-9-]{0,39}$/;
const LIST_DEFAULT = 50;
const LIST_MAX = 200;

const guarded = (fn) => (ctx) =>
  d1Guarded("landing_decisions", async () => {
    await ensureTable(ctx.env, "landing_decisions");
    return fn(ctx);
  });

export const routes = [
  [
    "POST", "/api/landing-decisions",
    guarded(async ({ env, t, body }) => {
      const b = body || {};
      const repo = typeof b.repo === "string" ? b.repo.trim() : "";
      if (!REPO_RE.test(repo)) return json(400, { error: "repo must be owner/name" });
      const number = prOf(b.number);
      if (number === null) return json(400, { error: "number must be a positive integer" });
      const head = shaOf(b.head);
      if (!head) return json(400, { error: "head must be a full 40-hex commit sha" });
      if (!LD_MODES.includes(b.mode)) return json(400, { error: `mode must be one of ${LD_MODES.join(", ")}` });
      if (!LD_WOULD.includes(b.would)) return json(400, { error: `would must be one of ${LD_WOULD.join(", ")}` });
      if (typeof b.reason !== "string" || !LD_REASON_RE.test(b.reason)) {
        return json(400, { error: "reason must be one lowercase token, [a-z][a-z0-9-], <= 40 chars" });
      }
      const res = await env.DB.prepare(
        `INSERT INTO landing_decisions (repo, number, head, mode, would, reason, at)
         VALUES (?1,?2,?3,?4,?5,?6,?7)
         ON CONFLICT(repo, number, head, mode) DO NOTHING`
      ).bind(repo, number, head, b.mode, b.would, b.reason, t).run();
      if (res.meta.changes === 1) return json(201, { ok: true, id: res.meta.last_row_id });
      return json(200, { ok: true, existing: true });
    }),
  ],

  // ?repo=&number=&limit= — newest first (id DESC). repo is required, so every
  // read is an index range (idx_landing_decisions_repo_id). The limit is
  // refused outside 1..200, never clamped, and `truncated` is measured by
  // reading one row past it.
  [
    "GET", "/api/landing-decisions",
    guarded(async ({ env, url, t }) => {
      const repo = (url.searchParams.get("repo") || "").trim();
      if (!REPO_RE.test(repo)) return json(400, { error: "repo is required, owner/name" });
      const rawNum = url.searchParams.get("number");
      const number = rawNum === null || rawNum === "" ? null : prOf(rawNum);
      if (rawNum && number === null) return json(400, { error: "number must be a positive integer" });
      const rawLimit = url.searchParams.get("limit");
      let limit = LIST_DEFAULT;
      if (rawLimit !== null) {
        limit = /^\d+$/.test(rawLimit) ? Number(rawLimit) : NaN;
        if (!(limit >= 1 && limit <= LIST_MAX)) return json(400, { error: `limit must be an integer 1..${LIST_MAX}` });
      }
      const rows = (await env.DB.prepare(
        "SELECT id, repo, number, head, mode, would, reason, at FROM landing_decisions" +
        " WHERE repo = ?1 AND (?2 IS NULL OR number = ?2)" +
        " ORDER BY id DESC LIMIT ?3"
      ).bind(repo, number, limit + 1).all()).results || [];
      return json(200, { rows: rows.slice(0, limit), truncated: rows.length > limit, as_of: t });
    }),
  ],
];
