-- ── BH-6970 (BH-6544.4): the break-it verifier ────────────────────────────────
-- bin/lib/break-it.sh (called by bin/lead-review.sh after the model verdict)
-- writes at most break_it.max_tests test cases against a medium- or high-tier
-- head with ONE model call on route review-break-it, runs them on the head and
-- records clean | failed:<k> | could-not-run on the verdict row (verdicts.break_it).
--   break_it.mode            off | shadow | enforce. shadow (the seed) runs and
--                            records, and the review, the verdict and the PR do
--                            not change. enforce adds a [BLOCK wrong-data]
--                            finding on failed:<k> and commits the test file to
--                            the PR branch. The code fallback for no row, an
--                            unreadable row or any other value is off (no spend).
--   break_it.max_tests       1..20 cases kept from the answer; fallback 5.
--   break_it.budget_usd      the call's budget, a positive decimal up to 20;
--                            fallback 1.50.
--   break_it.max_diff_bytes  the diff is cut to this many bytes in the prompt;
--                            fallback 200000.
--   break_it.cache_days      the box replay files (state/break-it/) are deleted
--                            after this many days, 1..365; fallback 14.
-- D1 is SQLite, not Supabase: RLS does not apply. No new table, so no index:
-- verdicts.break_it rides the worker's ADDED_COLUMNS. INSERT OR IGNORE seeds
-- only, so a re-apply through bin/harness-sync.sh is a no-op and an operator's
-- value is kept.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('break_it.mode','shadow','BH-6970: off | shadow | enforce. shadow = run the break-it verifier on medium and high heads and record the result on the verdict row, change nothing else; enforce = a failing case is a [BLOCK wrong-data] finding and the test file is committed to the PR branch. The code fallback is off','seed','2026-10-17T00:00:00Z'),
  ('break_it.max_tests','5','BH-6970: at most this many break-it cases are kept from the answer (1..20; fallback 5)','seed','2026-10-17T00:00:00Z'),
  ('break_it.budget_usd','1.50','BH-6970: the budget of the one break-it call, USD (a positive decimal up to 20; fallback 1.50)','seed','2026-10-17T00:00:00Z'),
  ('break_it.max_diff_bytes','200000','BH-6970: the diff in the break-it prompt is cut to this many bytes (fallback 200000)','seed','2026-10-17T00:00:00Z'),
  ('break_it.cache_days','14','BH-6970: the box replay files under state/break-it/ are deleted after this many days (1..365; fallback 14)','seed','2026-10-17T00:00:00Z');
-- review-break-it: the break-it call's route. A copy of the BH-6967 review-intent
-- seed with only the role changed: rung 0 is a copy of triage.light rung 0 (the
-- claude runner); rung 1, the fallback, is a copy of lead.review rung 0. Both
-- rungs in one statement, and only when both source rows exist, so the route is
-- never a gapped ladder. No model literal enters. The NOT EXISTS guards keep an
-- operator's cut: a role with a model_route_changes row is never put back.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'review-break-it', r.position, r.model, r.runner, 'seed', '2026-10-17T00:00:00Z'
  FROM (SELECT 0 AS position, t.model AS model, t.runner AS runner FROM model_routes t
          WHERE t.project IS NULL AND t.role = 'triage.light' AND t.position = 0 AND t.runner = 'claude'
        UNION ALL
        SELECT 1, l.model, l.runner FROM model_routes l
          WHERE l.project IS NULL AND l.role = 'lead.review' AND l.position = 0) r
  WHERE EXISTS (SELECT 1 FROM model_routes t WHERE t.project IS NULL AND t.role = 'triage.light' AND t.position = 0 AND t.runner = 'claude')
    AND EXISTS (SELECT 1 FROM model_routes l WHERE l.project IS NULL AND l.role = 'lead.review' AND l.position = 0)
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'review-break-it')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'review-break-it');
-- stage.break-it: the BH-2536 rule (every agent-call stage has a rung-0 stage
-- route), copied from stage.execute rung 0 the way stage.lesson-propose is. The
-- call walks review-break-it (AGENT_CALL_ROLE); this row names the stage.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.break-it', 0, m.model, m.runner, 'seed', '2026-10-17T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'stage.execute' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.break-it')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.break-it');
