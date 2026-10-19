-- BH-7462 (follow-up to BH-6890): with lane_fallback.merge-conductor.<project>
-- = hub, bin/lib/mc/project-placement.sh counts the no-capacity cycles of a
-- fly-placed project (a stale row withdrawn unclaimed and taken back) in
-- state/merge-conductor/project-fly/<project>.nocap-n, and at this many in a
-- row raises one ALERTS line, held by mc_project_fly.alert_s. A row a machine
-- claimed resets the count. Rollback: set the row to 86400. No new table and
-- no new index: one settings row, and settings rows are not a growing table.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('mc_project_fly.nocap_alert_n','3','BH-7462: with lane_fallback.merge-conductor.<project>=hub, this many no-capacity cycles in a row (a row withdrawn unclaimed and taken back) raise one held ALERTS line (1..86400); the code default is 3','seed','2026-10-19T00:00:00Z');
