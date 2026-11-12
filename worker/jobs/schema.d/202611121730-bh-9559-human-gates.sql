-- ── BH-9559 part A (BH-9580 tracer): human gates ───────────────────────────
-- A human gate is one question the harness asks a person, with a recommended
-- answer, 1-3 reasons, a default and a deadline. One row per question per
-- (repo, key, lane). The writer is POST /api/human-gates
-- (src/routes/human-gates.js); a re-ask of the same question is an upsert on
-- UNIQUE (repo, key, lane, question_fp) that only stamps asked_again_at.
-- gate_class comes from the settings row human_gate.class.<reason>; a reason
-- with no row is irreversible (fail-closed). An irreversible gate never
-- auto-applies its default.
-- Note: docs/notes/2026-11-12-BH-9580-human-gates.md, docs/CUSTODY.md.
--
-- INDEXES. Each read and the index that serves it:
--   upsert by question                WHERE repo=? AND key=? AND lane=? AND
--                                     question_fp=?  UNIQUE autoindex
--   open gates past their deadline    WHERE status='open' AND deadline_at < ?
--                                     idx_human_gates_open_deadline
--   open gates by class and age       WHERE status=? AND gate_class=?
--                                     ORDER BY created_at
--                                     idx_human_gates_open_created
--   the gates of one ticket           WHERE repo=? AND key=? AND status=?
--                                     idx_human_gates_key
--   review dates due                  WHERE status=? AND review_at < ?
--                                     idx_human_gates_review
--   retention ids                     WHERE status IN (resolved) AND age < ?
--                                     an index SEARCH on (status=?): the
--                                     planner picks idx_human_gates_review
--                                     or idx_human_gates_open_created
--   archive history of one ticket     WHERE repo=? AND key=?
--                                     idx_human_gates_archive_key
--
-- RETENTION (retention.d/bh-9559-human-gates.js, the hourly
-- bin/d1-retention.sh lane; retention.dry_run applies): a row whose status is
-- not open, resolved longer ago than human_gate.retention_days (90), is copied
-- to human_gates_archive and then deleted from human_gates in the same D1
-- batch. An open row never moves. human_gates_archive has no rule: it is the
-- history and keeps forever (a few rows per blocked ticket).
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS human_gates (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL,
  key TEXT NOT NULL,
  lane TEXT NOT NULL,
  reason TEXT NOT NULL DEFAULT '',
  gate_class TEXT NOT NULL CHECK (gate_class IN ('defaultable','irreversible')),
  question TEXT NOT NULL,
  question_fp TEXT NOT NULL,
  recommended TEXT NOT NULL,
  reasons_json TEXT NOT NULL,
  default_answer TEXT NOT NULL,
  deadline_at TEXT,
  review_at TEXT,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','answered','defaulted','expired-irreversible')),
  answer TEXT,
  answered_by TEXT CHECK (answered_by IS NULL OR answered_by IN ('reply','console','default')),
  comment_posted INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  resolved_at TEXT,
  asked_again_at TEXT,
  UNIQUE (repo, key, lane, question_fp)
);
CREATE INDEX IF NOT EXISTS idx_human_gates_open_deadline ON human_gates(status, deadline_at);
CREATE INDEX IF NOT EXISTS idx_human_gates_open_created ON human_gates(status, gate_class, created_at);
CREATE INDEX IF NOT EXISTS idx_human_gates_key ON human_gates(repo, key, status);
CREATE INDEX IF NOT EXISTS idx_human_gates_review ON human_gates(status, review_at);

-- no-retention: human_gates_archive keeps forever by design; it is the history of resolved human_gates rows (a few rows per blocked ticket, about 1k rows a year)
-- The history table. id is the hot row's id, kept, so a copy is idempotent
-- (INSERT OR IGNORE on the primary key).
CREATE TABLE IF NOT EXISTS human_gates_archive (
  id INTEGER PRIMARY KEY,
  repo TEXT NOT NULL,
  key TEXT NOT NULL,
  lane TEXT NOT NULL,
  reason TEXT NOT NULL DEFAULT '',
  gate_class TEXT NOT NULL,
  question TEXT NOT NULL,
  question_fp TEXT NOT NULL,
  recommended TEXT NOT NULL,
  reasons_json TEXT NOT NULL,
  default_answer TEXT NOT NULL,
  deadline_at TEXT,
  review_at TEXT,
  status TEXT NOT NULL,
  answer TEXT,
  answered_by TEXT,
  comment_posted INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  resolved_at TEXT,
  asked_again_at TEXT,
  archived_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_human_gates_archive_key ON human_gates_archive(repo, key);

-- Gate classes. Reader: classOf in src/routes/human-gates.js and hg_class in
-- bin/lib/human-gate.sh. Only the exact values defaultable | irreversible
-- count; anything else, and a reason with no row, is irreversible.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('human_gate.class.migration-gated','irreversible','BH-9559: gate class of reason migration-gated. Readers: routes/human-gates.js classOf, bin/lib/human-gate.sh hg_class. defaultable | irreversible; anything else is irreversible.','seed','2026-11-12T07:43:00Z'),
  ('human_gate.class.hotfix-migration-hold','irreversible','BH-9559: gate class of reason hotfix-migration-hold. Readers: classOf, hg_class.','seed','2026-11-12T07:43:00Z'),
  ('human_gate.class.provenance','irreversible','BH-9559: gate class of reason provenance. Readers: classOf, hg_class.','seed','2026-11-12T07:43:00Z'),
  ('human_gate.class.security-allowlist','irreversible','BH-9559: gate class of reason security-allowlist. Readers: classOf, hg_class.','seed','2026-11-12T07:43:00Z'),
  ('human_gate.class.plan_blocked','defaultable','BH-9559: gate class of reason plan_blocked (the planner PLAN_BLOCKED ask). Readers: classOf, hg_class.','seed','2026-11-12T07:43:00Z'),
  ('human_gate.class.tightened','defaultable','BH-9559: gate class of reason tightened. Readers: classOf, hg_class.','seed','2026-11-12T07:43:00Z'),
  ('human_gate.class.verdict-contradiction','defaultable','BH-9559: gate class of reason verdict-contradiction. Readers: classOf, hg_class.','seed','2026-11-12T07:43:00Z'),
  ('human_gate.class.nhv','defaultable','BH-9559: gate class of reason nhv. Readers: classOf, hg_class.','seed','2026-11-12T07:43:00Z'),
  ('human_gate.class.tackler','defaultable','BH-9559: gate class of reason tackler. Readers: classOf, hg_class.','seed','2026-11-12T07:43:00Z'),
  ('human_gate.class.needs-human','defaultable','BH-9559: gate class of reason needs-human. Readers: classOf, hg_class.','seed','2026-11-12T07:43:00Z'),
  ('human_gate.class.hold','defaultable','BH-9559: gate class of reason hold. Readers: classOf, hg_class.','seed','2026-11-12T07:43:00Z'),
  ('human_gate.class.parked','defaultable','BH-9559: gate class of reason parked. Readers: classOf, hg_class.','seed','2026-11-12T07:43:00Z');

-- Knobs and kill flags.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('human_gate.deadline_hours','24','BH-9559: hours from the ask to deadline_at when the caller gives none. Reader: routes/human-gates.js (integer 1..720, fallback 24).','seed','2026-11-12T07:43:00Z'),
  ('human_gate.hold_review_days','7','BH-9559: days from a HOLD to its review date. Reader: the BH-9559.5 review-date lane (not yet merged).','seed','2026-11-12T07:43:00Z'),
  ('human_gate.digest_hour_utc','7','BH-9559: the UTC hour of the human-gate digest. Reader: the BH-9559.4 digest lane (not yet merged).','seed','2026-11-12T07:43:00Z'),
  ('human_gate.retention_days','90','BH-9559: days a resolved human_gates row stays hot before it moves to human_gates_archive. Reader: retention.d/bh-9559-human-gates.js (0 = rule off, fallback 90).','seed','2026-11-12T07:43:00Z'),
  ('human_gate.format.enabled','1','BH-9559: kill flag. 0 = hg_ask (bin/lib/human-gate.sh) prints nothing and writes no row, so the caller keeps its old text.','seed','2026-11-12T07:43:00Z'),
  ('human_gate.default.enabled','1','BH-9559: kill flag of the default-at-deadline sweep. Reader: BH-9559.3 (not yet merged).','seed','2026-11-12T07:43:00Z'),
  ('human_gate.digest.enabled','1','BH-9559: kill flag of the human-gate digest. Reader: BH-9559.4 (not yet merged).','seed','2026-11-12T07:43:00Z'),
  ('human_gate.reask.enabled','1','BH-9559: kill flag of the re-ask reminder. Reader: BH-9559.5 (not yet merged).','seed','2026-11-12T07:43:00Z');
