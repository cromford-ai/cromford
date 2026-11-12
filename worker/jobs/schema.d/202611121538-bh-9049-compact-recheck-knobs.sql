-- BH-9049: the iron-law re-check after context compaction. bin/agent-call.sh
-- reads these rows through compact_recheck_settings (bin/lib/compact-recheck.sh)
-- on the build stages plan, execute and fix:
--   build.compact_recheck.<project>.enabled  1 = install the SessionStart
--       "compact" hook bin/compact-recheck.sh in that project's sessions. No
--       row, an outage or any other value = off (code fallback 0).
--   build.compact_recheck.timeout_s  the CLI hook timeout, seconds; each of
--       the hook's 4 bounded steps gets a quarter (code fallback 30).
--   build.compact_recheck.max_hits   scan hit lines put in the context
--       (code fallback 50).
-- On for cromford only, the first project of the 2-week measure. Data
-- only: no new table, so no index, no RLS and no retention rule apply (D1 is
-- SQLite). INSERT OR IGNORE keeps an operator's value.
-- Rollback: set build.compact_recheck.cromford.enabled to 0; sessions
-- start with no compaction hook, as before this change.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('build.compact_recheck.cromford.enabled','1','BH-9049: 1 = SessionStart compact hook (iron-law block + diff scan) in cromford plan/execute/fix sessions; 0 = off','seed','2026-11-04T19:02:00Z'),
  ('build.compact_recheck.timeout_s','30','BH-9049: CLI timeout of the compaction re-check hook, seconds (4 bounded steps of a quarter each)','seed','2026-11-04T19:02:00Z'),
  ('build.compact_recheck.max_hits','50','BH-9049: scan hit lines the compaction re-check puts in the session context','seed','2026-11-04T19:02:00Z');
