// review-tiers routes — the window reads behind the DORA digest's `review`
// block (BH-6969): merges, verdicts, reverts and main-red culprits over a
// window, so bin/dora_review.py can count them by review tier and mode.
//
// READ-ONLY. Four statements in one Promise.all, needed columns only, each
// with a LIMIT and a `capped` flag so the reader never mistakes a cut list
// for a complete one. Each read and the index that serves it:
//   merges    ledgers kind='merge' status='merged' updated_at>=since
//             idx_ledgers_kind_updated (BH-5566). updated_at, not created_at:
//             PUT /api/ledger is an upsert that sets created_at on the FIRST
//             write only, and bin/merge-sweep.sh writes `parked` on the same
//             key before bin/lib/mc/settle.sh writes `merged`. created_at is
//             the park time; updated_at is the merge write.
//   verdicts  verdicts created_at>=verdict_since, source lead|risk-tier
//             idx_verdicts_created (BH-5808)
//   reverts   outcome_metrics outcome='reverted' created_at>=since
//             idx_outcome_created (this ticket; `day` moves on every re-scan)
//   culprits  ledgers kind='main_red_attrib' updated_at>=since
//             idx_ledgers_kind_updated (BH-5566)
// The verdict read reaches 14 days further back than the window: a PR merged
// in the window can carry the verdict that decided it from before the window.

import { json } from "../lib/http.js";
import { ensureColumns, ensureTable } from "../lib/core.js";

export const REVIEW_TIER_LIMITS = { merges: 5000, verdicts: 20000, reverts: 5000, culprits: 2000 };
const VERDICT_REACH_DAYS = 14;

export const MERGES_SQL =
  `SELECT key AS pr_url, updated_at AS merged_at FROM ledgers
    WHERE kind='merge' AND status='merged' AND updated_at>=?1
    ORDER BY updated_at DESC LIMIT ?2`;
export const VERDICTS_SQL =
  `SELECT id, repo, pr, head_sha, verdict, source, review_tier, review_mode, created_at FROM verdicts
    WHERE created_at>=?1 AND source IN ('lead','risk-tier')
    ORDER BY created_at DESC LIMIT ?2`;
export const REVERTS_SQL =
  `SELECT repo, pr, outcome, created_at FROM outcome_metrics
    WHERE created_at>=?1 AND outcome='reverted'
    ORDER BY created_at DESC LIMIT ?2`;
export const CULPRITS_SQL =
  `SELECT key, status, json_extract(detail,'$.pr') AS pr, updated_at FROM ledgers
    WHERE kind='main_red_attrib' AND updated_at>=?1
    ORDER BY updated_at DESC LIMIT ?2`;

const isoDaysAgo = (nowMs, days) =>
  new Date(nowMs - days * 86400000).toISOString().replace(/\.\d{3}Z$/, "Z");

// days: 1..90, default 7. An absent or non-numeric value is the default; a
// number out of range is clamped, as GET /api/metrics/dora does.
export function reviewTierDays(raw) {
  const n = Number(raw);
  if (raw === null || String(raw).trim() === "" || !Number.isFinite(n)) return 7;
  return Math.min(Math.max(Math.floor(n), 1), 90);
}

export const routes = [
  [
    "GET", "/api/metrics/review-tiers",
    async ({ env, url, t }) => {
      // review_tier/review_mode are ADD COLUMNs (BH-6967) on an older table.
      await ensureTable(env, "verdicts");
      await ensureColumns(env, "verdicts");
      const days = reviewTierDays(url.searchParams.get("days"));
      const nowMs = Date.parse(t);
      const since = isoDaysAgo(nowMs, days);
      const verdictSince = isoDaysAgo(nowMs, days + VERDICT_REACH_DAYS);
      const L = REVIEW_TIER_LIMITS;
      const [merges, verdicts, reverts, culprits] = await Promise.all([
        env.DB.prepare(MERGES_SQL).bind(since, L.merges).all(),
        env.DB.prepare(VERDICTS_SQL).bind(verdictSince, L.verdicts).all(),
        env.DB.prepare(REVERTS_SQL).bind(since, L.reverts).all(),
        env.DB.prepare(CULPRITS_SQL).bind(since, L.culprits).all(),
      ]);
      const rows = {
        merges: merges.results || [], verdicts: verdicts.results || [],
        reverts: reverts.results || [], culprits: culprits.results || [],
      };
      const capped = Object.fromEntries(Object.keys(rows).map((k) => [k, rows[k].length >= L[k]]));
      return json(200, { days, since, verdict_since: verdictSince, ...rows, capped, as_of: t });
    },
  ],
];
