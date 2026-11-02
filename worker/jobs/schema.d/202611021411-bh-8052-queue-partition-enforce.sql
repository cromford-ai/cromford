-- ── BH-8052 (slice C0): the merge queue uploads each PR's Mergify scopes ───
-- Read by qp_mode (bin/lib/queue-partition.sh) through setting_get. No row,
-- no jobs client or an outage is the code fallback shadow. On a
-- queue_mode=serial conf a failed PUT is one log line and the enqueue goes
-- ahead, so this row changes no queue behavior until a conf flips to parallel.
-- No table is created here (D1, not Supabase: no RLS applies). INSERT OR
-- IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_partition.mode','enforce','BH-8052: upload each PR''s Mergify scopes (off|shadow|enforce). On a serial conf a failed PUT is one log line and the enqueue proceeds; on a parallel conf it holds the PR (rc 3). Code fallback shadow. Rollback: off','seed','2026-11-02T14:11:00Z');
