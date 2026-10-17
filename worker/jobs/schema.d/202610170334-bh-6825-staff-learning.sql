-- ── BH-6825 (Staff in Mission Control 4/4): the agent page's learning view ──
-- staff_promotion_decisions: one row per staff_promotions row a human decided
-- with POST /api/staff/promotions/decide (src/routes/staff-learning.js):
-- approve (the agent rises to to_level and the promotion is applied) or void.
-- It holds the reason and the actor. promotion_id is UNIQUE, so a promotion is
-- decided once. The decide route is the only writer. Readers:
-- GET /api/staff/learning (the newest decisions of one agent), the decide
-- route's replay check, and the retention pre-deletes.
-- Indexes, one per query:
--   ux_staff_promotion_decisions_promotion  the replay check and the read-back
--                                           by promotion_id; the retention
--                                           pre-delete by promotion_id
--   idx_staff_promotion_decisions_agent     the newest 5 of one agent
--                                           (WHERE agent=? ORDER BY decided_at DESC)
--   idx_staff_outcomes_agent_resolved       the window counts, the drill-down
--                                           page and the evidence of one agent
--                                           (WHERE agent=? AND resolved_at >= ?
--                                           ORDER BY resolved_at DESC, id DESC)
-- RETENTION (BH-6730 iron law, BH-6750 job, src/routes/retention.js): a
-- decision row lives and dies with its promotion. The two staff_promotions
-- rules (retention.staff_promotions.void_days 30, .applied_days 180) delete
-- the decision rows of the promotions they delete, as a `pre` in the same
-- batch. retention.dry_run applies. A pending promotion has no decision row.
-- Settings: the two window lengths of the learning view and the drill-down
-- page size, with the code defaults as the documented fallback.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, no DROP and no ALTER, so a re-apply through
-- bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS staff_promotion_decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  promotion_id INTEGER NOT NULL,
  agent TEXT NOT NULL,
  decision TEXT NOT NULL CHECK (decision IN ('approve','void')),
  from_level TEXT NOT NULL,
  to_level TEXT NOT NULL,
  reason TEXT NOT NULL CHECK (length(reason) BETWEEN 1 AND 500),
  actor TEXT NOT NULL,
  decided_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_staff_promotion_decisions_promotion ON staff_promotion_decisions(promotion_id);
CREATE INDEX IF NOT EXISTS idx_staff_promotion_decisions_agent ON staff_promotion_decisions(agent, decided_at);
CREATE INDEX IF NOT EXISTS idx_staff_outcomes_agent_resolved ON staff_outcomes(agent, resolved_at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.learning.short_days','7','BH-6825: days in the short window of the staff learning view (1..365)','seed','2026-10-16T00:00:00Z'),
  ('staff.learning.long_days','30','BH-6825: days in the long window of the staff learning view (1..365)','seed','2026-10-16T00:00:00Z'),
  ('staff.learning.page_max','100','BH-6825: max outcome rows per page of the staff learning drill-down (1..200)','seed','2026-10-16T00:00:00Z');
