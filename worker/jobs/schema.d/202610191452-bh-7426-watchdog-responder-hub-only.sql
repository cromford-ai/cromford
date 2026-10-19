-- BH-7426 (part of #7397): watchdog-responder stays on the hub. A lane-run
-- machine cannot run it: bin/watchdog-responder.sh:134 keeps the 12 h cooldown
-- in the fleet-wide state/responder/handled.json, which
-- catalog/lane-run-inputs.d/watchdog-responder.rw does not carry back; :364
-- launches /root/harness/bin/run-build.sh by hub path; :405 and :523 read the
-- board token from env/<p>.env through bin/internal-token-for.sh. So
-- bin/lib/lane-placement.sh lp_decide answers hub for this lane whatever its
-- lane_placement row says, and bin/lane-move.sh holds it. The value shows in
-- bin/lane-move.sh and bin/lane-cpu-rank.sh, so it stays under 120 characters.
-- Evidence: docs/notes/2026-10-19-BH-7426-watchdog-responder-hub-only.md.
-- To move the lane later: solve the blockers, remove this seed in that PR and
-- delete the row. No new table, so no index and no retention rule.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_placement.watchdog-responder.hub_only','writes fleet-wide state/responder/handled.json (no write-back), launches hub run-build.sh, needs env/<p>.env board token','BH-7426: lane-move must not move this lane. Delete the row when the BH-6720 flip blockers are solved','seed','2026-10-19T14:52:00Z');
