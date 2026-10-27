-- ── BH-7999 (BH-7935.2): the /projects/new settings rows ────────────────────
-- Read by console-ui/src/screens/Onboard.js through GET /api/settings/<key>
-- (KNOBS in console-ui/src/lib/onboard.js). A missing row or a value that is
-- not an integer falls back to the code default of the same value.
-- No table is created here (D1, not Supabase: no RLS applies). INSERT OR
-- IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('onboarding.product_board_ready','0','BH-7999: 1 makes the Product board tracker selectable on /projects/new (after #7913). Code default 0','seed','2026-10-27T01:33:00Z'),
  ('onboarding.detect_poll_ms','3000','BH-7999: ms between repo-detect polls on /projects/new; also the idle wait before the first poll. Code default 3000','seed','2026-10-27T01:33:00Z'),
  ('onboarding.detect_poll_max_s','120','BH-7999: seconds the repo-detect poll runs before it offers Retry. Code default 120','seed','2026-10-27T01:33:00Z');
