-- BH-7427: why review-autopilot stays on the hub. bin/lib/lane-placement.sh
-- lp_decide and bin/lane-move.sh g2 read lane_placement.<lane>.hub_only: a
-- non-empty value keeps the lane on the hub even when its placement row says
-- fly. A project run needs the hub repo clone for the free verdict replay, and
-- the lane writes no per-project run-done line for lane-move to count. See
-- docs/notes/2026-10-19-BH-7427-review-autopilot-hub-only.md. No table is
-- created here, so no index and no retention rule apply. The kill row (an
-- empty value) is in the note.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_placement.review-autopilot.hub_only','BH-7427: a project run needs /root/repos/<p> for the free verdict replay, which a lane-run snapshot cannot carry, so a machine would buy reviews again; and the lane writes no per-project run-done line for lane-move to count. See docs/notes/2026-10-19-BH-7427-review-autopilot-hub-only.md','BH-7427: why review-autopilot stays on the hub (bin/lib/lane-placement.sh lp_decide, bin/lane-move.sh g2). Empty value = no hub_only','seed','2026-10-19T15:22:00Z');
