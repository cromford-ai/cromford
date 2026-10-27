-- ── BH-7243.2 (BH-7265): roadmap board knobs ────────────────────────────────
-- Settings rows only. No table is created here: every table and index the
-- board reads and writes is in 202610182038-bh-7243-roadmap-ideas.sql.
-- Readers: src/routes/roadmap-board.js (roadmap.board_links_limit and
-- roadmap.board_running_limit, through
-- settingsRows, one memoized settings read per request) and
-- bin/roadmap-render.sh (roadmap.render_projects, GET /api/settings/<key>).
-- Note: docs/notes/2026-10-17-BH-7243.2-roadmap-board.md.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('roadmap.render_projects','','BH-7243.2: comma-separated projects whose docs/ROADMAP.html bin/roadmap-render.sh renders and opens a PR for; empty = none','seed','2026-10-17T06:00:00Z'),
  ('roadmap.board_links_limit','2000','BH-7243.2: the most roadmap_links rows one GET /api/roadmap/board reads (1..10000); more sets truncated.links','seed','2026-10-17T06:00:00Z'),
  ('roadmap.board_running_limit','500','BH-7243.2: the most running jobs of one project one GET /api/roadmap/board reads (1..10000); more sets truncated.running','seed','2026-10-17T06:00:00Z');
