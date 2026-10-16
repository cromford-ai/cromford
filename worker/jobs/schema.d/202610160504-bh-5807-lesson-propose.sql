-- ── BH-5807 (BH-5794.2): propose fixes for repeat causes ─────────────────────
-- The block-learning loop's second wave (#5794). bin/lesson-propose.sh (hub,
-- daily) reads GET /api/lesson-propose/triggers and drafts ONE change per
-- repeat cause. No new table: the dedup is ledgers kind=lesson_proposal, the
-- new categories are block_categories rows (POST /api/lesson-propose/categories).
-- Note: docs/notes/2026-10-15-BH-5807-lesson-propose.md.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lesson_propose.min_blocks','3','BH-5807: distinct BLOCK verdicts in the window that make a category (or a cluster of other findings) a lesson-propose trigger','seed','2026-10-13T00:00:00Z'),
  ('lesson_propose.since_days','14','BH-5807: how many days back GET /api/lesson-propose/triggers counts BLOCK verdicts','seed','2026-10-13T00:00:00Z'),
  ('lesson_propose.cooldown_days','14','BH-5807: days after a lesson merged before the same category is proposed again','seed','2026-10-13T00:00:00Z'),
  ('lesson_propose.max_attempts','3','BH-5807: billed drafting attempts for the same evidence (fingerprint) before the lane stops calling for it','seed','2026-10-13T00:00:00Z');
-- The drafting model, rank 0 at hub scope. It copies rule.miner rung 0 (the
-- other lane that turns the fleet's failures into rules), pinned to its claude
-- rung, so no model id is written here (tests/alert-triage-runners R6). Moving
-- it is a PUT /api/model-routes, not a deploy. Same tombstone guard as
-- lookback.cluster: an operator who deleted the role keeps it deleted.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'lesson.propose', 0, m.model, m.runner, 'seed', '2026-10-13T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'rule.miner' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'lesson.propose')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'lesson.propose');
-- stage.lesson-propose: the BH-2536 rule (every agent-call stage has a rung-0
-- stage route), copied from stage.execute rung 0 the way stage.lookback is.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.lesson-propose', 0, m.model, m.runner, 'seed', '2026-10-13T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'stage.execute' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.lesson-propose')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.lesson-propose');
