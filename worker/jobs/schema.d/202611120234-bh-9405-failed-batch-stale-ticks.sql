-- ── BH-9405: the BH-8186 failed-batch hold parks a stale head for the resolver ──
-- Additive only: no table, no DROP, no UPDATE. INSERT OR IGNORE, so a re-apply
-- never resets a value an operator changed. One statement per seed
-- (bin/harness-sync.sh applies the file statement by statement, BH-1000).
-- Read by bin/lib/mc-failed-batch.sh fbh_stale_ticks; its code fallback (6)
-- equals this seed and the registry default
-- (catalog/lanes.d/merge-conductor.knobs.d/MC_FAILED_BATCH_STALE_TICKS.json).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.merge-conductor.mc_failed_batch_stale_ticks','6','BH-9405: conductor ticks a same-patch head Mergify dequeued for a failed batch is held with no solo proof before the row is parked BLOCKED_HUMAN queue-ejected-twice for the resolver, with the batch checks in an eject-cause line. 0 = off (the hold waits for mc_failed_batch_unjudged_hold_s). Read by bin/lib/mc-failed-batch.sh, code fallback 6','seed','2026-11-11T00:00:00Z');
