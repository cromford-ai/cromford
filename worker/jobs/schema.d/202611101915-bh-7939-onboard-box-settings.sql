-- ── BH-7975 (BH-7939.1): the onboarding box station knobs ─────────────────
-- bin/lib/onboard-box.sh (_obx_knobs) reads these rows once per box station.
-- Each code fallback equals the seed value here. Integers outside the range in
-- the note fall back to the default.
-- No table here, so no index and no RLS. Only INSERT OR IGNORE: a re-apply is
-- a no-op.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('onboard.box_image','','BH-7975: the Fly image of a dedicated project box (a full fleet box image: sshd, cron, the harness). Empty = the dedicated path fails with "no box image set". Code default empty.','seed','2026-11-01T23:56:00Z'),
  ('onboard.box_region','iad','BH-7975: the Fly region of a dedicated project box (three lower-case letters). Code default iad.','seed','2026-11-01T23:56:00Z'),
  ('onboard.box_pool_timeout_s','3600','BH-7975: seconds the pool path waits for the FLY_ONBOARD verdict (1..86400). Code default 3600.','seed','2026-11-01T23:56:00Z'),
  ('onboard.box_provision_timeout_s','600','BH-7975: seconds the dedicated path waits for the new machine to reach started (1..7200). Code default 600.','seed','2026-11-01T23:56:00Z'),
  ('onboard.box_poll_s','30','BH-7975: seconds between two polls of a box station wait; each poll is one read of the run (no beat) (1..600). Code default 30.','seed','2026-11-01T23:56:00Z'),
  ('onboard.box_call_timeout_s','120','BH-7975: seconds for one flyctl call or one Tailscale ssh call (1..1800). Code default 120.','seed','2026-11-01T23:56:00Z'),
  ('onboard.box_fail_tail_lines','20','BH-7975: rollout log lines the pool path shows after a FAILED verdict (1..200). Code default 20.','seed','2026-11-01T23:56:00Z');
