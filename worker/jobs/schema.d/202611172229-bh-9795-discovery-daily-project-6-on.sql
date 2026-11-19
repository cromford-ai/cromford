-- BH-9795: the discovery-daily lane ON for project-6-os: source sentry, tickets
-- in its fleet.conf repo (example-org/project-6; the DISCOVERY_TARGET_REPO row is not seeded, empty = the fleet.conf repo). The Sentry project slug is NOT seeded: until the lead
-- sets it with bin/discovery-setup.sh --sentry-project <slug>, the run logs
-- `sentry not-configured` and makes no call.
-- Reader: lane_env_apply discovery-daily project-6-os (bin/lib/lane-gate.sh).
-- INSERT OR IGNORE: a row an operator already wrote is kept.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.discovery-daily.project-6-os.discovery_sources','sentry','BH-9795: discovery sources of project-6-os. Reader: bin/lib/discovery-daily.sh (fallback empty = lane off).','seed','2026-11-17T22:29:00Z');
