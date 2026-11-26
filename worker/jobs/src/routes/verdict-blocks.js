// verdict-blocks route — BH-9905: the BLOCK verdict rows of one repo since a
// time, in one read.
//
// The reader is the blocked-resolver's verdict-block candidate source. It
// reads one batch per project per tick through bin/lib/verdicts.sh
// vd_repo_blocks, not one GET /api/verdicts for each open PR. It then reads
// /api/verdicts&head= only for the PRs whose head matches a row here.
//
// GET /api/verdict-blocks?repo=<owner/name>&since=<ISO-8601>[&limit=<n>]
//   repo   required, REPO_RE (400 otherwise)
//   since  required, an ISO-8601 time (400 if absent or not a time). It is
//          normalized to the stored created_at form (YYYY-MM-DDTHH:MM:SSZ, UTC,
//          no milliseconds) so the text compare is a time compare.
//   limit  optional positive whole number (400 otherwise). It is clamped to
//          the settings row verdict_blocks.max_rows, which is also the default.
// 200 {repo, since, limit, rows:[{id, pr, head_sha, source, created_at}],
//      truncated: rows.length >= limit, as_of}. Newest first. No note column,
//      to keep the payload small. A retracted row (verdict_retractions,
//      BH-8476) is absent.
//
// One settings read and one verdicts read per request. The NOT IN is
// uncorrelated: each candidate id is a rowid lookup on the
// verdict_retractions primary key.
//
// EXPLAIN QUERY PLAN at 20,000 seeded rows over 20 repos
// (test/verdict-blocks.bh-9905.test.js W4), as observed:
//   SEARCH verdicts USING INDEX idx_verdicts_repo_verdict_created (repo=? AND verdict=? AND created_at>?)
//   USING ROWID SEARCH ON TABLE verdict_retractions FOR IN-OPERATOR
// No SCAN of verdicts, no SCAN of verdict_retractions, and no temp b-tree for
// the ORDER BY: the index serves it.
//
// Main-bearer gated: the route is in ROUTES (test/route-table.d).
import { d1Guarded, json } from "../lib/http.js";
import { ensureTable } from "../lib/core.js";
import { REPO_RE } from "./verdicts.js";

// Code fallback of the settings row verdict_blocks.max_rows (seeded '1000' by
// schema.d/202611242327-bh-9905-verdict-blocks.sql). Used when the row is
// absent, not a positive whole number, or the read throws.
export const VERDICT_BLOCKS_MAX_ROWS_FALLBACK = 1000;

const ISO_RE = /^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2}(\.\d{1,9})?)?(Z|[+-]\d{2}:?\d{2})?)?$/;
const POS_INT_RE = /^[1-9][0-9]{0,8}$/;

export const VERDICT_BLOCKS_SQL =
  `SELECT id, pr, head_sha, source, created_at FROM verdicts
    WHERE repo=?1 AND verdict='BLOCK' AND created_at >= ?2
      AND id NOT IN (SELECT verdict_id FROM verdict_retractions)
    ORDER BY created_at DESC LIMIT ?3`;

// sinceOf(raw) — the stored created_at form of an ISO-8601 time, or null.
export function sinceOf(raw) {
  const s = typeof raw === "string" ? raw.trim() : "";
  if (!ISO_RE.test(s)) return null;
  const ms = Date.parse(s);
  if (!Number.isFinite(ms)) return null;
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
}

async function maxRows(env) {
  try {
    const v = await env.DB.prepare("SELECT value FROM settings WHERE key='verdict_blocks.max_rows'").first("value");
    const s = typeof v === "string" ? v.trim() : v == null ? "" : String(v);
    return POS_INT_RE.test(s) ? Number(s) : VERDICT_BLOCKS_MAX_ROWS_FALLBACK;
  } catch (e) {
    console.warn("[verdict-blocks] settings read failed; using the fallback cap:", e?.message || e);
    return VERDICT_BLOCKS_MAX_ROWS_FALLBACK;
  }
}

export const routes = [
  [
    "GET", "/api/verdict-blocks",
    ({ env, url, t }) => d1Guarded("verdicts", async () => {
      const repo = (url.searchParams.get("repo") || "").trim();
      if (!REPO_RE.test(repo)) return json(400, { error: "repo must be owner/name" });
      const since = sinceOf(url.searchParams.get("since"));
      if (since === null) return json(400, { error: "since must be an ISO-8601 time, e.g. 2026-11-22T20:32:00Z" });
      const rawLimit = url.searchParams.get("limit");
      let asked = null;
      if (rawLimit !== null) {
        const s = rawLimit.trim();
        if (!POS_INT_RE.test(s)) return json(400, { error: "limit must be a positive integer" });
        asked = Number(s);
      }
      const cap = await maxRows(env);
      const limit = asked === null ? cap : Math.min(asked, cap);
      await ensureTable(env, "verdicts");
      await ensureTable(env, "verdict_retractions");
      const res = await env.DB.prepare(VERDICT_BLOCKS_SQL).bind(repo, since, limit).all();
      const rows = res.results || [];
      return json(200, { repo, since, limit, rows, truncated: rows.length >= limit, as_of: t });
    }),
  ],
];
