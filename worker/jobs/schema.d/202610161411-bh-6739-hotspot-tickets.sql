-- BH-6739 (BH-6543.2): the split tickets bin/hotspot-split-ticket.sh filed.
-- One row per (repo, path): a file that crossed hotspots.split_threshold
-- replayed conflicts in 30 days and got ONE ai-build "Split <path>" issue.
-- Written by PUT /api/hotspot-tickets (worker/jobs/src/routes/hotspot-tickets.js)
-- after the issue exists; read by GET /api/hotspot-tickets before the lane files.
--
-- Retention: rule hotspot_tickets.age in worker/jobs/src/routes/retention.js,
-- run by the hourly bin/d1-retention.sh (dry-run first: retention.dry_run, one
-- retention_runs row per rule per run). A row is the lane's "filed once"
-- memory; after retention.hotspot_tickets.days (default 365) it is deleted, and
-- a path that is still hot may file a new split ticket. The GitHub issue keeps
-- the history. Growth: at most 10 new rows a week (the top 10 hotspots).
CREATE TABLE IF NOT EXISTS hotspot_tickets (
  repo TEXT NOT NULL,
  path TEXT NOT NULL,
  issue INTEGER NOT NULL,
  filed_at TEXT NOT NULL,
  actor TEXT,
  PRIMARY KEY (repo, path)
);
-- Reads and the index that serves each:
--   GET /api/hotspot-tickets   WHERE repo = ? ORDER BY path      PRIMARY KEY (repo, path)
--   PUT /api/hotspot-tickets   conflict target, read-back        PRIMARY KEY (repo, path)
--   retention hotspot_tickets.age  WHERE filed_at < ? ORDER BY filed_at LIMIT ?  idx_hotspot_tickets_filed
CREATE INDEX IF NOT EXISTS idx_hotspot_tickets_filed ON hotspot_tickets (filed_at);

INSERT OR IGNORE INTO settings (key, value, note, actor, updated_at) VALUES
  ('hotspots.split_threshold', '10', 'BH-6739: bin/hotspot-split-ticket.sh files a split ticket for a file with at least this many replayed conflicts in 30 days (whole number 1..10000; another value stops the run, never clamped)', 'seed', '2026-10-15T00:00:00Z'),
  ('hotspots.split_max_age_days', '14', 'BH-6739: bin/hotspot-split-ticket.sh stops (stopped=stale) when the stored conflict-hotspots run is older than this many days (whole number 1..365; another value stops the run)', 'seed', '2026-10-16T00:00:00Z'),
  ('retention.hotspot_tickets.days', '365', 'BH-6739: rule hotspot_tickets.age deletes a split-ticket row this many days after filed_at; a still-hot path may then file again (0 = rule off)', 'seed', '2026-10-16T00:00:00Z');
