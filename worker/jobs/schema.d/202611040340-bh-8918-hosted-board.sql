-- ── BH-8918 (BH-7913.1): the hosted Board API ──────────────────────────────
-- A project with no product board of its own gets one here. The routes are
-- src/routes/hosted-board.js (an OPEN family: its own token check, never
-- HARNESS_SECRET) and src/routes/hosted-board-admin.js (gated: board setup,
-- token issue and revoke). The SQL text of every hot read is a named constant
-- in src/lib/hosted-board.js, and test/hosted-board-explain.bh-8918.test.js
-- runs EXPLAIN QUERY PLAN on those same strings at 20,000 tickets.
-- Doc: docs/HOSTED-BOARD.md. Note: docs/notes/2026-11-02-BH-8918-hosted-board.md.
--
-- TABLES
--   hosted_board_boards    one row per (project, board id)
--   hosted_board_tickets   the tickets; labels and depends_on are JSON arrays
--   hosted_board_comments  the thread of a ticket
--   hosted_board_events    one row per write (created, commented, moved,
--                          turned, assigned)
--   hosted_board_tokens    sha256 hex of a bearer token; the token itself is
--                          never stored. role system = one project; role
--                          operator = project '*'
--   hosted_board_idem      the stored answer of each POST that carried an
--                          Idempotency-Key
--
-- INDEXES. Each query and the index that serves it:
--   board list     WHERE project=?1 AND archived_at IS NULL ORDER BY id
--                  ux_hosted_board_boards_key
--   board check    WHERE project=?1 AND id=?2   ux_hosted_board_boards_key
--   ticket list    WHERE project=?1 AND board_id=?2 AND archived_at IS NULL
--                  ORDER BY updated_at DESC, id DESC LIMIT ?3
--                  idx_hosted_board_tickets_list, read backwards: the order
--                  needs no sort, so a page reads about LIMIT rows. The list has
--                  no status filter, so status is not a column of this index.
--   next page      the same, AND (updated_at, id) < the cursor row's
--   ticket by id   WHERE id=?1 AND project=?2   the primary key
--   ticket by key  WHERE project=?1 AND key=?2   ux_hosted_board_tickets_key
--   next number    MAX(number) WHERE project=?1 AND board_id=?2
--                  ux_hosted_board_tickets_number
--   dependsOn      WHERE project=?1 AND id IN (json_each)   the primary key
--   children       WHERE project=?1 AND parent_id IN (json_each)
--                  idx_hosted_board_tickets_parent
--   comments       WHERE project=?1 AND ticket_id=?2 ORDER BY created_at
--                  idx_hosted_board_comments_ticket
--   events         WHERE project=?1 AND ticket_id=?2 ORDER BY at
--                  idx_hosted_board_events_ticket
--   token check    WHERE token_hash=?1   the primary key
--   token revoke   WHERE project=?1 AND token_id=?2   ux_hosted_board_tokens_id
--   idem read      WHERE project=?1 AND idem_key=?2   ux_hosted_board_idem_key
--   retention ids  WHERE at < ?1 ORDER BY at   idx_hosted_board_events_at
--                  WHERE created_at < ?1 ORDER BY created_at
--                  idx_hosted_board_idem_created
--
-- RETENTION (src/routes/retention.d/bh-8918-hosted-board.js, on the hourly
-- bin/d1-retention.sh lane; retention.dry_run applies). Events and idem rows
-- are deleted after retention.hosted_board_events.days and
-- retention.hosted_board_idem.days (180 each). Tickets and comments have no
-- rule: they archive by archived_at and are never deleted. Boards and tokens
-- are a handful of rows per project and keep forever (a token is revoked, not
-- deleted).
-- D1 is SQLite, not Supabase, so RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS hosted_board_boards (
  project TEXT NOT NULL,
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  key_prefix TEXT NOT NULL,
  created_at TEXT NOT NULL,
  archived_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_hosted_board_boards_key ON hosted_board_boards(project, id);
CREATE TABLE IF NOT EXISTS hosted_board_tickets (
  id TEXT PRIMARY KEY,
  project TEXT NOT NULL,
  board_id TEXT NOT NULL,
  number INTEGER NOT NULL,
  key TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  status TEXT NOT NULL DEFAULT 'todo',
  waiting_on TEXT NOT NULL DEFAULT 'team',
  triage_verdict TEXT,
  type TEXT NOT NULL DEFAULT 'feature',
  priority TEXT NOT NULL DEFAULT 'medium',
  labels TEXT NOT NULL DEFAULT '[]',
  assignee_kind TEXT,
  assignee_id TEXT,
  parent_id TEXT,
  depends_on TEXT NOT NULL DEFAULT '[]',
  source TEXT NOT NULL DEFAULT 'hosted',
  external_id TEXT,
  external_url TEXT,
  comment_count INTEGER NOT NULL DEFAULT 0,
  reporter_id TEXT,
  reporter_name TEXT,
  last_activity_at TEXT NOT NULL,
  turn_changed_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  archived_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_hosted_board_tickets_list ON hosted_board_tickets(project, board_id, updated_at, id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_hosted_board_tickets_number ON hosted_board_tickets(project, board_id, number);
CREATE UNIQUE INDEX IF NOT EXISTS ux_hosted_board_tickets_key ON hosted_board_tickets(project, key);
CREATE INDEX IF NOT EXISTS idx_hosted_board_tickets_parent ON hosted_board_tickets(project, parent_id);
CREATE TABLE IF NOT EXISTS hosted_board_comments (
  id TEXT PRIMARY KEY,
  project TEXT NOT NULL,
  ticket_id TEXT NOT NULL,
  author_kind TEXT NOT NULL,
  author_id TEXT NOT NULL,
  author_name TEXT,
  body TEXT NOT NULL,
  is_internal INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  archived_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_hosted_board_comments_ticket ON hosted_board_comments(project, ticket_id, created_at);
CREATE TABLE IF NOT EXISTS hosted_board_events (
  id INTEGER PRIMARY KEY,
  project TEXT NOT NULL,
  ticket_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  actor TEXT NOT NULL,
  payload TEXT,
  at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_hosted_board_events_ticket ON hosted_board_events(project, ticket_id, at);
CREATE INDEX IF NOT EXISTS idx_hosted_board_events_at ON hosted_board_events(at);
CREATE TABLE IF NOT EXISTS hosted_board_tokens (
  token_hash TEXT PRIMARY KEY,
  token_id TEXT NOT NULL,
  project TEXT NOT NULL,
  role TEXT NOT NULL,
  actor_name TEXT NOT NULL,
  note TEXT,
  created_at TEXT NOT NULL,
  revoked_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_hosted_board_tokens_id ON hosted_board_tokens(project, token_id);
CREATE TABLE IF NOT EXISTS hosted_board_idem (
  id INTEGER PRIMARY KEY,
  project TEXT NOT NULL,
  idem_key TEXT NOT NULL,
  method TEXT NOT NULL,
  path TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  status INTEGER NOT NULL,
  response_body TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_hosted_board_idem_key ON hosted_board_idem(project, idem_key);
CREATE INDEX IF NOT EXISTS idx_hosted_board_idem_created ON hosted_board_idem(created_at);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('hosted_board.list_page_max','500','BH-8918: tickets one GET /api/hosted-board/<p>/boards/<b>/tickets page answers (an integer >= 1); nextCursor is set when more wait','seed','2026-11-02T17:42:00Z'),
  ('hosted_board.title_max_chars','300','BH-8918: characters of a hosted-board ticket title (an integer >= 1); a longer one is a 400','seed','2026-11-02T17:42:00Z'),
  ('hosted_board.description_max_chars','20000','BH-8918: characters of a hosted-board ticket description (an integer >= 1); a longer one is a 400','seed','2026-11-02T17:42:00Z'),
  ('hosted_board.comment_max_chars','5000','BH-8918: characters of one hosted-board comment (an integer >= 1; the contract floor is 5000); a longer one is a 400','seed','2026-11-02T17:42:00Z'),
  ('hosted_board.depends_on_max','50','BH-8918: ids one hosted-board ticket may list in dependsOn (an integer >= 1); more is a 400','seed','2026-11-02T17:42:00Z'),
  ('hosted_board.create_retries','3','BH-8918: attempts a hosted-board create makes when two creates take the same ticket number (an integer >= 1); then 503','seed','2026-11-02T17:42:00Z'),
  ('retention.hosted_board_events.days','180','BH-8918: days a hosted_board_events row is kept before the retention lane deletes it (0 = off)','seed','2026-11-02T17:42:00Z'),
  ('retention.hosted_board_idem.days','180','BH-8918: days a hosted_board_idem row is kept before the retention lane deletes it (0 = off)','seed','2026-11-02T17:42:00Z');
