-- BH-6817: lane-run machines run current harness code, and a failed run is
-- reported once. Settings rows only, no table (so no index and no retention
-- rule apply). Each note names its code fallback.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_run.code_sync','1','BH-6817: 0 = a lane-run machine (LANE_RUN_CODE_SYNC=1) does not pull main of the harness repo before its claims (bin/lib/lane-run-code.sh); any other value, no row or an outage is on; the code default is on','seed','2026-10-15T00:00:00Z'),
  ('lane_run.code_check_s','120','BH-6817: seconds between two code-sync fetches on a lane-run machine (30..3600); out of range or no row uses the code default 120','seed','2026-10-15T00:00:00Z'),
  ('lane_run.command_missing_alert_s','3600','BH-6817: seconds between two lane-run-command-missing-<lane> alerts from one lane-run machine (60..86400); out of range or no row uses the code default 3600','seed','2026-10-15T00:00:00Z');
