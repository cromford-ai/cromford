-- ── BH-6967 (BH-6544.1): the intent review of a medium-risk head ──────────────
-- risk_tier.medium_mode: full | intent. bin/lead-review-enqueue.sh reads it once
-- a tick. intent = a medium head is reviewed with prompts/lead-review.d/intent.md
-- on route review-intent. full (the seed, and the code fallback for no row, an
-- unreadable row or any other value) = every head gets today's full review.
-- A risk_tier.* row is protected: full -> intent needs bin/protected-setting.sh.
-- D1 is SQLite, not Supabase: RLS does not apply. No new table and no new
-- column here (verdicts.review_tier and verdicts.review_mode ride the worker's
-- ADDED_COLUMNS). INSERT OR IGNORE seeds only, so a re-apply through
-- bin/harness-sync.sh is a no-op and an operator's value is kept.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('risk_tier.medium_mode','full','BH-6967: full | intent. intent = a medium-risk head gets the intent review (prompts/lead-review.d/intent.md, route review-intent); full = the full lead review. The code fallback is full','seed','2026-10-15T00:00:00Z');
-- review-intent: the intent review's route. Rung 0 is a copy of triage.light rung
-- 0 (the Sonnet-class row, claude runner); rung 1, the fallback, is a copy of
-- lead.review rung 0 (today's lead model). Both rungs in one statement, and only
-- when both source rows exist, so the route is never a gapped ladder
-- (bin/lib/model-route.sh reads a ladder with no rung 0 as no route). No model
-- literal enters. The NOT EXISTS guards keep an operator's cut: a role with a
-- model_route_changes row is never put back.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'review-intent', r.position, r.model, r.runner, 'seed', '2026-10-15T00:00:00Z'
  FROM (SELECT 0 AS position, t.model AS model, t.runner AS runner FROM model_routes t
          WHERE t.project IS NULL AND t.role = 'triage.light' AND t.position = 0 AND t.runner = 'claude'
        UNION ALL
        SELECT 1, l.model, l.runner FROM model_routes l
          WHERE l.project IS NULL AND l.role = 'lead.review' AND l.position = 0) r
  WHERE EXISTS (SELECT 1 FROM model_routes t WHERE t.project IS NULL AND t.role = 'triage.light' AND t.position = 0 AND t.runner = 'claude')
    AND EXISTS (SELECT 1 FROM model_routes l WHERE l.project IS NULL AND l.role = 'lead.review' AND l.position = 0)
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'review-intent')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'review-intent');
