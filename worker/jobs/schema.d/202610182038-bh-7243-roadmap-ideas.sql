-- ── BH-7243.0 (BH-7263): the roadmap tables ──────────────────────────────────
-- The per-project roadmap and ideas backlog. ALL five tables are here, so no
-- child ticket of BH-7243 needs the DDL of another child:
--   roadmap_ideas        one row per idea. lane = ideas | next | discarded;
--                        Now and Shipped are computed (BH-7243.2), never stored.
--                        version counts edits (the BH-7243.1 CAS).
--   roadmap_idea_events  one row per change of an idea: created | moved |
--                        edited | imported. Written in the same D1 batch as
--                        the change.
--   roadmap_links        idea -> filed GitHub issue. issue_state = open |
--                        closed_completed | closed_other | NULL (not seen yet).
--   roadmap_decisions    the decisions log (kind log) and open questions
--                        (kind open). status = open | decided | dropped.
--   roadmap_waves        one shaping request over a set of ideas. status =
--                        requested | shaping | draft | empty | failed |
--                        rejected | approved | filing | filed; the status
--                        column is the claim (CAS). input_fp is the
--                        dedup-before-spend key. draft is JSON:
--                        {slices:[{title, body, acceptance_tests[], spec_refs[],
--                        files[], seam_files[], blocked_by[]}], notes}, where
--                        blocked_by holds 1-based earlier slice positions.
-- Writer and reader of this slice: src/routes/roadmap-ideas.js (POST and GET
-- /api/roadmap/ideas). Enums are checked in JS, not by CHECK constraints, so a
-- later enum change stays additive. Note:
-- docs/notes/2026-10-17-BH-7243.0-roadmap-contract.md.
--
-- INDEXES. Each query and the index that serves it:
--   GET list, no lane   WHERE project=?1 ORDER BY updated_at DESC, id DESC
--         idx_roadmap_ideas_project_updated (project, updated_at)
--   GET list, lane=     WHERE project=?1 AND lane=?3 ORDER BY updated_at DESC
--         idx_roadmap_ideas_project_lane_updated (project, lane, updated_at)
--   GET counts          WHERE project=?1 GROUP BY lane
--         idx_roadmap_ideas_project_lane_updated (covering)
--   POST idem lookup    WHERE project=?1 AND idem_key=?2, and the ON CONFLICT
--         target: ux_roadmap_ideas_idem (project, idem_key). SQLite UNIQUE
--         allows many NULLs, so an idea without a key never conflicts.
--   BH-7243.1 import dedup  ux_roadmap_ideas_source_ref (project, source_ref)
--   retention ids       WHERE lane='discarded' AND discarded_at < ?1
--         idx_roadmap_ideas_discarded (discarded_at) WHERE lane='discarded'
--   idea detail events  WHERE idea_id=?1 ORDER BY at DESC
--         idx_roadmap_idea_events_idea (idea_id, at)
--   retention ids       WHERE at < ?1   idx_roadmap_idea_events_at (at)
--   board links         WHERE project=?1   idx_roadmap_links_project
--   issue state write   WHERE repo=?1 AND issue=?2   idx_roadmap_links_repo_issue
--   stale state read    ORDER BY state_seen_at   idx_roadmap_links_state_seen
--   filing reads        WHERE wave_id=?1   idx_roadmap_links_wave
--   decisions board     WHERE project=?1 AND kind=?2 ORDER BY updated_at
--         idx_roadmap_decisions_project (project, kind, updated_at)
--   wave dedup          ux_roadmap_waves_fp (project, input_fp)
--   wave claim reads and retention ids   WHERE status IN (...) AND updated_at
--         idx_roadmap_waves_status (status, updated_at)
--   wave list           WHERE project=?1 ORDER BY created_at
--         idx_roadmap_waves_project (project, created_at)
--
-- RETENTION (src/routes/retention.js, the hourly bin/d1-retention.sh lane).
-- Every rule copies to the archive D1 before it deletes (src/lib/archive.js);
-- with the archive unbound it deletes nothing. retention.dry_run (seed 1)
-- applies: the first runs only count.
--   roadmap_ideas.discarded   a discarded idea, after
--                             retention.roadmap_ideas.discarded_days (180).
--   roadmap_idea_events.age   an event, after retention.roadmap_idea_events.days (730).
--   roadmap_waves.closed      a rejected or failed wave, after
--                             retention.roadmap_waves.days (365). Waves hold
--                             cost_usd (money), so they are archived.
--   roadmap_links and roadmap_decisions keep forever on purpose: they are the
--   Shipped column and the decisions log, and they grow at human speed (one
--   row per filed slice or decision).
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS roadmap_ideas (
  id TEXT PRIMARY KEY,
  project TEXT NOT NULL,
  title TEXT NOT NULL,
  note TEXT,
  source TEXT NOT NULL,
  source_ref TEXT,
  link TEXT,
  lane TEXT NOT NULL DEFAULT 'ideas',
  version INTEGER NOT NULL DEFAULT 1,
  idem_key TEXT,
  created_by TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  discarded_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_roadmap_ideas_project_updated ON roadmap_ideas(project, updated_at);
CREATE INDEX IF NOT EXISTS idx_roadmap_ideas_project_lane_updated ON roadmap_ideas(project, lane, updated_at);
CREATE UNIQUE INDEX IF NOT EXISTS ux_roadmap_ideas_idem ON roadmap_ideas(project, idem_key);
CREATE UNIQUE INDEX IF NOT EXISTS ux_roadmap_ideas_source_ref ON roadmap_ideas(project, source_ref);
CREATE INDEX IF NOT EXISTS idx_roadmap_ideas_discarded ON roadmap_ideas(discarded_at) WHERE lane = 'discarded';
CREATE TABLE IF NOT EXISTS roadmap_idea_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  idea_id TEXT NOT NULL,
  project TEXT NOT NULL,
  kind TEXT NOT NULL,
  from_lane TEXT,
  to_lane TEXT,
  actor TEXT NOT NULL,
  reason TEXT,
  detail TEXT,
  at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_roadmap_idea_events_idea ON roadmap_idea_events(idea_id, at);
CREATE INDEX IF NOT EXISTS idx_roadmap_idea_events_at ON roadmap_idea_events(at);
CREATE TABLE IF NOT EXISTS roadmap_links (
  idea_id TEXT NOT NULL,
  project TEXT NOT NULL,
  repo TEXT NOT NULL,
  issue INTEGER NOT NULL,
  wave_id TEXT,
  issue_state TEXT,
  state_seen_at TEXT,
  created_by TEXT,
  created_at TEXT NOT NULL,
  PRIMARY KEY (idea_id, repo, issue)
);
CREATE INDEX IF NOT EXISTS idx_roadmap_links_project ON roadmap_links(project);
CREATE INDEX IF NOT EXISTS idx_roadmap_links_repo_issue ON roadmap_links(repo, issue);
CREATE INDEX IF NOT EXISTS idx_roadmap_links_state_seen ON roadmap_links(state_seen_at);
CREATE INDEX IF NOT EXISTS idx_roadmap_links_wave ON roadmap_links(wave_id);
CREATE TABLE IF NOT EXISTS roadmap_decisions (
  id TEXT PRIMARY KEY,
  project TEXT NOT NULL,
  kind TEXT NOT NULL,
  title TEXT NOT NULL,
  body TEXT,
  status TEXT NOT NULL DEFAULT 'open',
  created_by TEXT,
  decided_by TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  decided_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_roadmap_decisions_project ON roadmap_decisions(project, kind, updated_at);
CREATE TABLE IF NOT EXISTS roadmap_waves (
  id TEXT PRIMARY KEY,
  project TEXT NOT NULL,
  status TEXT NOT NULL,
  input_fp TEXT NOT NULL,
  idea_ids TEXT NOT NULL,
  spec_fp TEXT,
  draft TEXT,
  model TEXT,
  cost_usd REAL,
  error TEXT,
  requested_by TEXT,
  claimed_by TEXT,
  claimed_at TEXT,
  approved_by TEXT,
  approved_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_roadmap_waves_fp ON roadmap_waves(project, input_fp);
CREATE INDEX IF NOT EXISTS idx_roadmap_waves_status ON roadmap_waves(status, updated_at);
CREATE INDEX IF NOT EXISTS idx_roadmap_waves_project ON roadmap_waves(project, created_at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('roadmap.list_limit','200','BH-7243.0: the most ideas GET /api/roadmap/ideas returns in one answer (1..1000); a larger ?limit= is lowered to it','seed','2026-10-17T05:47:00Z'),
  ('retention.roadmap_ideas.discarded_days','180','BH-7243.0: days a discarded roadmap idea stays hot before it moves to the archive (0 = off)','seed','2026-10-17T05:47:00Z'),
  ('retention.roadmap_idea_events.days','730','BH-7243.0: days a roadmap idea event stays hot before it moves to the archive (0 = off)','seed','2026-10-17T05:47:00Z'),
  ('retention.roadmap_waves.days','365','BH-7243.0: days a rejected or failed roadmap wave stays hot before it moves to the archive (0 = off)','seed','2026-10-17T05:47:00Z');
