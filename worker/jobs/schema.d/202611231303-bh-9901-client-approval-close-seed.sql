-- ── BH-9901 (BH-9887 slice C2): the per-tick bound on client-approval closes ─
-- Reader: bin/lib/client-approval.sh (ca_knob close_max_per_tick), from the
-- conductor fragment bin/merge-conductor.d/bh-9901-client-approval-close.sh.
-- No table is created here, so no index, RLS or retention rule applies. The
-- close reuses the C0 rows client_approval_board.retry_max and timeout_s.
-- INSERT OR IGNORE: a re-apply changes nothing and an operator's value stays.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('client_approval_board.close_max_per_tick','10','BH-9901: merged or closed PRs whose board approval request one conductor tick closes at most (the rest wait for the next tick); code fallback CA_CLOSE_MAX_PER_TICK_DEFAULT','seed','2026-11-23T13:03:00Z');
