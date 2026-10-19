-- ── BH-7406: the issue the hub lane CPU table goes to ───────────────────────
-- Read by bin/lane-cpu-rank.sh (setting_get lane_cpu_rank.issue). #7252 is
-- closed; #7406 carries the rest of its items, so the table posts there. The
-- code default (7252) stays as the fallback when the row cannot be read.
-- To measure again (the "after" numbers), set this row to another issue with
-- bin/jobs-client.sh setting-set lane_cpu_rank.issue <n>.
-- No table is created here (D1, not Supabase: no RLS applies).
-- INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_cpu_rank.issue','7406','BH-7406: the issue bin/lane-cpu-rank.sh posts the hub CPU table to; #7252 is closed; code default 7252','seed','2026-10-18T00:00:00Z');
