-- ── BH-6972 (BH-6546.2): alert_decisions ─────────────────────────────────────
-- One row per decision bin/component-watch.sh made on an open alert: the
-- verdict (resolve | park | ticket | escalate), why, and what applying it did.
-- outcome = applied | noop | deferred | ticket-exists | invalid | failed:<why>.
-- until is set on a park only (the alerts API has no until field, so the lane
-- re-offers a parked alert to the model after it); title and issue on a ticket
-- only. An `invalid` row keeps the verdict token the model gave. The writer is
-- the lane (POST /api/alerts/decisions, one batch per run, after the applies);
-- the readers are the lane's next run (GET ?alert_ids=, the newest row per
-- alert), the console of wave 3 (GET ?alert_id= and ?component=) and the
-- retention rule. Note: docs/notes/2026-10-16-BH-6972-component-watch.md.
--
-- INDEXES. Each query and the index that serves it:
--   GET ?alert_ids=  WHERE alert_id IN (json_each) with ROW_NUMBER() OVER
--         (PARTITION BY alert_id ORDER BY at DESC, id DESC): one range of
--         idx_alert_decisions_alert (alert_id, at) per id, at most 50 ids.
--   GET ?alert_id=   WHERE alert_id=?1 ORDER BY at DESC, id DESC
--         idx_alert_decisions_alert (alert_id, at).
--   GET ?component=  WHERE component=?1 ORDER BY at DESC, id DESC
--         idx_alert_decisions_component (component, at).
--   retention id read  WHERE at < ?1 ORDER BY at
--         idx_alert_decisions_at (at).
--
-- RETENTION (src/routes/retention.js rule alert_decisions.age, the hourly
-- bin/d1-retention.sh lane). A row is a diagnostic of an automated decision;
-- the audit of each state change stays in alert_actions. Rows older than
-- retention.alert_decisions.days (90) are deleted, not archived.
-- retention.dry_run (seed 1) applies: the first runs only count.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS alert_decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  alert_id TEXT NOT NULL,
  component TEXT NOT NULL,
  run_id TEXT NOT NULL,
  verdict TEXT NOT NULL,
  until TEXT,
  reason TEXT NOT NULL,
  title TEXT,
  outcome TEXT NOT NULL,
  issue INTEGER,
  at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_alert_decisions_alert ON alert_decisions(alert_id, at);
CREATE INDEX IF NOT EXISTS idx_alert_decisions_component ON alert_decisions(component, at);
CREATE INDEX IF NOT EXISTS idx_alert_decisions_at ON alert_decisions(at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('component_watch.budget_usd','0.5','BH-6972: --max-budget-usd of one bin/component-watch.sh model call (0 = no run). A runaway wire, not a target: one Haiku-class call over a 40 KB prompt costs a few cents.','seed','2026-10-16T12:01:00Z'),
  ('component_watch.max_tickets','2','BH-6972: ai-build issues one component-watch run may file; later ticket groups are deferred to the next run','seed','2026-10-16T12:01:00Z'),
  ('component_watch.max_attempts','3','BH-6972: billed failed model calls on one unchanged alert set before the lane waits for a new sighting','seed','2026-10-16T12:01:00Z'),
  ('retention.alert_decisions.days','90','BH-6972: days a component-watch decision row is kept (0 = off)','seed','2026-10-16T12:01:00Z');
-- The decision model, rank 0 at hub scope. It copies review.trivial rung 0 (a
-- Haiku-class model on the claude runner), so no model id is written here.
-- Moving it is a PUT /api/model-routes, not a deploy. The tombstone guard keeps
-- a role an operator deleted deleted.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'component-watch', 0, m.model, m.runner, 'seed', '2026-10-16T12:01:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'review.trivial' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'component-watch')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'component-watch');
-- stage.component-watch: the BH-2536 rule (every agent-call stage has a rung-0
-- stage route), copied from stage.execute rung 0 the way stage.lesson-propose is.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.component-watch', 0, m.model, m.runner, 'seed', '2026-10-16T12:01:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'stage.execute' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.component-watch')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.component-watch');
