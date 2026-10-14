-- ── BH-6061: Fly idle reaper rows ──
-- bin/fly-idle-reaper.sh stops a started Fly machine that is idle above
-- fly.idle_stop_after_s. Each stop it requested (flyctl rc 0) is one
-- fly_idle_stops row, keyed on stop_id = <machine_id>-<stop epoch> and written
-- with INSERT OR IGNORE, so a replayed outbox post is a no-op. status is
-- 'requested', never 'stopped': the next pass sees whether the machine stopped.
-- fly_idle_machines is the last pass's started-machine snapshot. One PUT
-- replaces it in ONE batch (src/routes/fly-idle.js). fly_idle_pass holds the
-- one row with that pass's time and coverage. Mission Control (/machines)
-- reads all three through GET /api/fly-idle. D1 has no RLS; the worker's
-- bearer guards the routes.
CREATE TABLE IF NOT EXISTS fly_idle_stops (
  stop_id TEXT PRIMARY KEY,
  app TEXT NOT NULL,
  machine_id TEXT NOT NULL,
  size TEXT,
  source TEXT NOT NULL,
  idle_s INTEGER NOT NULL,
  threshold_s INTEGER NOT NULL,
  usd_per_hour REAL,
  status TEXT NOT NULL CHECK (status IN ('requested')),
  box TEXT,
  stopped_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS fly_idle_stops_stopped_at ON fly_idle_stops (stopped_at);
CREATE TABLE IF NOT EXISTS fly_idle_machines (
  app TEXT NOT NULL,
  machine_id TEXT NOT NULL,
  size TEXT,
  source TEXT NOT NULL,
  idle_s INTEGER,
  idle_state TEXT NOT NULL CHECK (idle_state IN ('busy','idle','over','stopping','unknown','nosignal','exempt')),
  threshold_s INTEGER,
  usd_per_hour REAL,
  PRIMARY KEY (app, machine_id)
);
CREATE TABLE IF NOT EXISTS fly_idle_pass (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  pass_at TEXT NOT NULL,
  apps_total INTEGER NOT NULL,
  apps_failed INTEGER NOT NULL,
  partial INTEGER NOT NULL,
  box TEXT
);
-- The reaper's knobs. INSERT OR IGNORE, so an operator's edit survives every
-- re-apply. A per-app override is fly.idle_stop_after_s.<app> (no seed row).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('fly.idle_stop_after_s','900','BH-6061: idle seconds above which bin/fly-idle-reaper.sh stops a started Fly machine; per-app override fly.idle_stop_after_s.<app>; code fallback 900','seed','2026-10-11T00:00:00Z'),
  ('fly.idle_nosignal_alert_s','3600','BH-6061: seconds a no-signal app keeps a started machine before one alert; code fallback 3600','seed','2026-10-11T00:00:00Z'),
  ('fly.idle_fail_alert_after','3','BH-6061: consecutive read or stop failures per machine before the alert; code fallback 3','seed','2026-10-11T00:00:00Z'),
  ('fly.idle_max_stops_per_pass','10','BH-6061: the most machines one reaper pass stops; the rest are reported over; code fallback 10','seed','2026-10-11T00:00:00Z');
