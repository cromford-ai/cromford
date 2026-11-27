-- ── BH-10231 (C1 of BH-9889): the box-watch duty's restart rows ────────────
-- bin/box-watch.sh (a hub lane, every 5 min) restarts a fleet box that failed
-- box_watch.fail_probes ssh probes in a row. One row per restart attempt:
-- POST /api/box-watch/claim writes it (outcome 'claimed') BEFORE the restart,
-- with one INSERT ... WHERE NOT EXISTS that refuses a second claim for the
-- same box inside box_watch.restart_window_min. POST
-- /api/box-watch/actions/:id writes the end state once (refused,
-- restart_failed, still_dark, back). GET /api/box-watch/actions lists the
-- newest rows for the BOX WATCH section of /staff/quartermaster.
-- Route: src/routes/box-watch.js. Note: docs/notes/2026-11-26-BH-10231-box-watch.md.
--
-- INDEXES. Each read and the index that serves it:
--   claim NOT EXISTS / last claim   WHERE box=? AND acted_at >= ?
--                                    ORDER BY acted_at DESC LIMIT 1
--                                    idx_box_watch_actions_box
--   per-box list                    WHERE box=? ORDER BY acted_at DESC LIMIT ?
--                                    idx_box_watch_actions_box
--   newest list                     ORDER BY acted_at DESC LIMIT ?
--                                    idx_box_watch_actions_at
--   retention ids                   WHERE acted_at < ? ORDER BY acted_at LIMIT ?
--                                    idx_box_watch_actions_at
--   record / delete                 WHERE id=?: the INTEGER PRIMARY KEY
-- EXPLAIN QUERY PLAN at 20,000 seeded rows over 40 boxes (ANALYZE;
-- worker/jobs/test/box-watch.bh-10231.test.js "EXPLAIN"):
--   claim      SEARCH box_watch_actions USING COVERING INDEX idx_box_watch_actions_box (box=? AND acted_at>?)
--   per box    SEARCH box_watch_actions USING INDEX idx_box_watch_actions_box (box=?)
--   newest     SCAN box_watch_actions USING INDEX idx_box_watch_actions_at
--   retention  SEARCH box_watch_actions USING COVERING INDEX idx_box_watch_actions_at (acted_at<?)
-- No full SCAN of the table and no temp b-tree.
--
-- 12-MONTH SIZE: at most one row per box per 120 min, so at most 12 a day per
-- box; a real fleet of about 5 boxes writes a few rows a week (under 1,000 a
-- year). RETENTION (retention.d/bh-10231-box-watch.js, the hourly
-- bin/d1-retention.sh lane; retention.dry_run applies): a row older than
-- retention.box_watch_actions.days (365) is deleted. No money moves here.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op and an
-- operator's own settings row survives it.
CREATE TABLE IF NOT EXISTS box_watch_actions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  box TEXT NOT NULL,
  box_id TEXT,
  probes INTEGER NOT NULL DEFAULT 0,
  acted_at TEXT NOT NULL,
  outcome TEXT NOT NULL DEFAULT 'claimed'
    CHECK (outcome IN ('claimed','refused','restart_failed','still_dark','back')),
  restart_rc INTEGER,
  recovery_rc INTEGER,
  back_at TEXT,
  detail TEXT,
  ended_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_box_watch_actions_box ON box_watch_actions(box, acted_at);
CREATE INDEX IF NOT EXISTS idx_box_watch_actions_at ON box_watch_actions(acted_at);

INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('box_watch.fail_probes','3','BH-10231: failed 5-min ssh probes in a row before bin/box-watch.sh restarts a box; 1..100','seed','2026-11-26T14:40:00Z'),
  ('box_watch.restart_window_min','120','BH-10231: at most one box-watch restart per box in this many minutes; 5..10080','seed','2026-11-26T14:40:00Z'),
  ('box_watch.probe_timeout_s','15','BH-10231: seconds one box-watch ssh probe may take; 1..110','seed','2026-11-26T14:40:00Z'),
  ('box_watch.mass_dark_boxes','3','BH-10231: this many dark boxes in one tick = the hub network; restart none; 1..1000','seed','2026-11-26T14:40:00Z'),
  ('box_watch.boot_wait_s','600','BH-10231: seconds box-watch waits for ssh after a restart; 10..3600','seed','2026-11-26T14:40:00Z'),
  ('box_watch.boot_poll_s','15','BH-10231: seconds between probes in the box-watch boot wait; 1..600','seed','2026-11-26T14:40:00Z'),
  ('box_watch.recovery_timeout_s','180','BH-10231: seconds the one box-watch recovery ssh may take; 5..1800','seed','2026-11-26T14:40:00Z'),
  ('box_watch.act_timeout_s','2400','BH-10231: seconds one box-watch act may take before it pages; 60..7200','seed','2026-11-26T14:40:00Z'),
  ('box_watch.orgo_timeout_s','30','BH-10231: curl seconds of the hourly Orgo lever check (GET /workspaces); 1..300','seed','2026-11-26T14:40:00Z'),
  ('retention.box_watch_actions.days','365','BH-10231: days a box_watch_actions row is kept before d1-retention deletes it','seed','2026-11-26T14:40:00Z');

-- Ownership: quartermaster owns the duty (an ownership record only; the lane
-- keeps its own script, cron line and kill switch).
INSERT OR IGNORE INTO staff_lanes (agent, lane, created_at) VALUES
  ('quartermaster','box-watch','2026-11-26T14:40:00Z');
