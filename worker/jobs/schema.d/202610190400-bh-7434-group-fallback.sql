-- BH-7434: lane-run fleet groups (lane_fleet.group.<name> rows, read by
-- lib/lane-fleet-groups.js). A queued row of a grouped project that waited
-- longer than this is claimable by the default lane-run fleet, and
-- bin/lane-fleet.sh writes one ALERTS line per UTC day for the group. No group
-- row is seeded: the first group is an operator's call (it creates a Fly app).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_run.group_fallback_s','900','BH-7434: seconds a queued lane run of a project in a lane_fleet.group.* row may wait before the default lane-run fleet may claim it too (0..86400; 0 = never), so a project never stalls when its group fleet is down; the code default is 900','seed','2026-10-19T00:00:00Z');
