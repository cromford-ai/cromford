-- ── BH-6877: Fly idle reaper destroy rows and the daily rollup ──
-- bin/fly-idle-reaper.sh destroys a machine of a pool, builder or lane-run app
-- that has been stopped for more than fly.destroy_after_stopped_s. Each destroy
-- it requested (flyctl rc 0) is one fly_idle_destroys row, keyed on
-- destroy_id = <machine_id>-<destroy epoch> and written with INSERT OR IGNORE
-- (POST /api/fly-idle/destroys), so a replayed outbox post is a no-op. status
-- is 'requested': the next pass sees whether the machine is gone. usd_per_hour
-- is the compute $/h of the machine size: what a restart of it would cost. It
-- is NOT a saving: a stopped machine pays no compute. Mission Control (/machines) reads the last 24 h through
-- GET /api/fly-idle. D1 has no RLS; the worker's bearer guards the routes.
--
-- INDEX. fly_idle_destroys_destroyed_at serves the 24 h GET
--   WHERE destroyed_at >= ?1 ORDER BY destroyed_at DESC
-- and the retention id read
--   WHERE destroyed_at < ?1 ORDER BY destroyed_at LIMIT ?2.
-- The retention delete is by destroy_id, the PRIMARY KEY.
-- The stops retention read uses fly_idle_stops_stopped_at (0023).
--
-- RETENTION (BH-6750 job, src/routes/retention.js). fly_idle_stops and
-- fly_idle_destroys are the reaper's cost audit. Each row is kept
-- retention.fly_idle_stops.days / retention.fly_idle_destroys.days (400: one
-- year plus a month). Past that, the rule adds the rows to fly_idle_daily in
-- the same D1 batch as the delete, so the history is archived, not lost.
-- retention.dry_run (seed 1) applies: the first runs only count.
--
-- fly_idle_daily is the archive: one row per (day, app, action). The PRIMARY
-- KEY serves the rollup upsert ON CONFLICT (day, app, action).
-- no-index: fly_idle_daily its one write is the rollup upsert ON CONFLICT (day, app, action), served by the PRIMARY KEY; nothing reads it by another column
-- no-retention: fly_idle_daily keeps forever by design; it is the archive of the stop and destroy rows (about 33 apps x 2 actions a day, about 24k rows a year)
-- Only IF NOT EXISTS and INSERT OR IGNORE, so a re-apply through
-- bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS fly_idle_destroys (
  destroy_id TEXT PRIMARY KEY,
  app TEXT NOT NULL,
  machine_id TEXT NOT NULL,
  size TEXT,
  source TEXT NOT NULL,
  stopped_s INTEGER NOT NULL,
  usd_per_hour REAL,
  kind TEXT NOT NULL CHECK (kind IN ('destroy')),
  status TEXT NOT NULL CHECK (status IN ('requested')),
  box TEXT,
  destroyed_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS fly_idle_destroys_destroyed_at ON fly_idle_destroys (destroyed_at);
CREATE TABLE IF NOT EXISTS fly_idle_daily (
  day TEXT NOT NULL,
  app TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('stop','destroy')),
  n INTEGER NOT NULL,
  usd_per_hour_sum REAL NOT NULL DEFAULT 0,
  PRIMARY KEY (day, app, action)
);
-- The reaper's BH-6877 knobs and the two retention windows. INSERT OR IGNORE,
-- so an operator's edit survives every re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('fly.no_claim_alert_s','600','BH-6877: seconds a lane-run machine runs with no claim before one alert per image digest; code fallback 600','seed','2026-10-15T00:00:00Z'),
  ('fly.probe_busy_cpu_pct','5','BH-6877: CPU percent at which a process the probe does not list as idle makes the machine busy; code fallback 5','seed','2026-10-15T00:00:00Z'),
  ('fly.metrics_idle_cpu_pct','2','BH-6877: busy CPU percent under which a metrics app machine counts as idle; code fallback 2','seed','2026-10-15T00:00:00Z'),
  ('fly.metrics_idle_net_bps','2048','BH-6877: network bytes per second under which a metrics app machine counts as idle; code fallback 2048','seed','2026-10-15T00:00:00Z'),
  ('fly.destroy_after_stopped_s','604800','BH-6877: seconds a pool, builder or lane-run machine stays stopped before bin/fly-idle-reaper.sh destroys it (more than, not equal); code fallback 604800','seed','2026-10-15T00:00:00Z'),
  ('fly.destroy_max_per_pass','10','BH-6877: the most machines one reaper pass destroys; code fallback 10','seed','2026-10-15T00:00:00Z'),
  ('fly.destroy_enabled','1','BH-6877: 1 lets the reaper destroy long-stopped machines, 0 turns the destroy step off; code fallback 1','seed','2026-10-15T00:00:00Z'),
  ('retention.fly_idle_stops.days','400','BH-6877: days a fly_idle_stops row is kept before it is added to fly_idle_daily and removed (0 = off); code fallback 400','seed','2026-10-15T00:00:00Z'),
  ('retention.fly_idle_destroys.days','400','BH-6877: days a fly_idle_destroys row is kept before it is added to fly_idle_daily and removed (0 = off); code fallback 400','seed','2026-10-15T00:00:00Z');
