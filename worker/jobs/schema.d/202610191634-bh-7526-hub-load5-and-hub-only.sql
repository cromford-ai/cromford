-- ── BH-7526: the hub load5 target, the before number, three hub-only reasons ─
-- Read by bin/lane-cpu-rank.sh (setting_get): the CPU table states "Hub load5
-- target: under <t>. Before: <b> at <ts>. After: start <x>, end <y>. Target
-- met: yes|no|unknown." Target 24 is the BH-7252 acceptance ("Hub load5 under
-- 24 after the moves"). The before number is the hub load5 at the first lane
-- flip, 2026-10-17T09:30:45Z (#7252 #issuecomment-6252072531: "Hub load5 at
-- the flip: 52.42").
-- The lane_placement.<lane>.hub_only rows are the one-line reason a lane must
-- stay on the hub (#7252: "Lanes that must stay on the hub get a one-line
-- reason in the lane registry"). bin/lane-cpu-rank.sh prints it in the
-- "hub-only reason" column; lp_decide reads it only when a lane is placed fly,
-- and none of these three has a lane_placement row or a lane-move module, so
-- no placement and no gate changes.
-- No table is created here (D1, not Supabase: no RLS applies).
-- INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_cpu_rank.load5_target','24','BH-7526: the hub load5 target the CPU table judges against; BH-7252 acceptance; code default 24','seed','2026-10-19T00:00:00Z'),
  ('lane_cpu_rank.load5_before','52.42','BH-7526: hub load5 at the first lane flip; #7252 #issuecomment-6252072531','seed','2026-10-19T00:00:00Z'),
  ('lane_cpu_rank.load5_before_at','2026-10-17T09:30:45Z','BH-7526: when lane_cpu_rank.load5_before was read (the pipeline-health flip)','seed','2026-10-19T00:00:00Z'),
  ('lane_placement.lane-cpu-rank.hub_only','samples the hub''s own /proc; on another machine it measures that machine','BH-7526: one-line reason this lane stays on the hub','seed','2026-10-19T00:00:00Z'),
  ('lane_placement.lane-move.hub_only','reads the hub''s pipeline-health and lane-snapshot-publish logs and state/lane-move/ to judge a move','BH-7526: one-line reason this lane stays on the hub','seed','2026-10-19T00:00:00Z'),
  ('lane_placement.lane-snapshot-publish.hub_only','applies lane-run write-backs into the hub''s tree and publishes the hub''s snapshots','BH-7526: one-line reason this lane stays on the hub','seed','2026-10-19T00:00:00Z');
