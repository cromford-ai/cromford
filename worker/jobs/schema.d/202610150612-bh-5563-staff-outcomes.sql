-- ── BH-5563 (BH-5556.6): the staff learning loop ─────────────────────────────
-- staff_outcomes: one row per filed staff finding whose GitHub issue closed,
-- written only by POST /api/staff/outcomes (src/routes/staff-outcomes.js).
-- fingerprint is UNIQUE, so a finding has one outcome. verdict is the
-- agent-core outcome word: merged = agree, rejected and noise = overrule.
-- class is the classSlug() of the finding's class; family is
-- familyFingerprint(agent, class), the key a noise suppression is proposed on.
-- suppression_proposed marks the noise outcome that made a proposal, so the
-- next proposal counts only noise closures after it. suppression_window marks
-- a noise outcome that landed while the family had a pending or unexpired
-- active suppression; the count also starts after it, so a declined proposal
-- needs K noise closures after the decline. applied = 0 only inside
-- the route's one batch: every effect is conditioned on it and it is set last.
-- staff_promotions: a proposal to raise an agent one level, made when
-- agent-core nextLevel() with a hypothetical delegate would raise it. A human
-- applies it with POST /api/staff/agents/autonomy. One pending row per agent.
-- staff_suppressions gets its first 'pending' writer here (a noise proposal);
-- one pending row per fingerprint.
-- RETENTION (BH-6730 iron law, BH-6750 job, worker/jobs/src/routes/retention.js).
-- Both tables grow. They are history: precision and noise counts read them.
-- No archive store exists yet (#6777), so the windows are long, not short:
--   staff_outcomes.age        an applied outcome older than
--                             retention.staff_outcomes.days (180) AND older than
--                             its agent's last change. 180 d keeps two quarters
--                             of precision; the promotion read only uses rows
--                             since the agent's last change, and those stay.
--                             For an agent whose level never changes, the
--                             bound is staff_findings.done (365 d): it removes
--                             the outcome with its finding, in one batch
--                             (202610150613-bh-5563-staff-findings-retention.sql).
--   staff_promotions.void     a void proposal decided more than
--                             retention.staff_promotions.void_days (30) ago:
--                             it changed nothing, so it has little value.
--   staff_promotions.applied  an applied promotion decided more than
--                             retention.staff_promotions.applied_days (180) ago.
--   A pending promotion is never removed. retention.dry_run (seed 1) applies.
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS and
-- INSERT OR IGNORE, no DROP and no ALTER, so a re-apply through
-- bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS staff_outcomes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  fingerprint TEXT NOT NULL UNIQUE CHECK (length(fingerprint) = 64),
  agent TEXT NOT NULL,
  class TEXT NOT NULL,
  family TEXT NOT NULL CHECK (length(family) = 64),
  outcome TEXT NOT NULL CHECK (outcome IN ('merged','rejected','noise')),
  verdict TEXT NOT NULL CHECK (verdict IN ('agree','overrule')),
  ticket_url TEXT NOT NULL,
  resolved_at TEXT NOT NULL,
  suppression_proposed INTEGER NOT NULL DEFAULT 0 CHECK (suppression_proposed IN (0,1)),
  suppression_window INTEGER NOT NULL DEFAULT 0 CHECK (suppression_window IN (0,1)),
  applied INTEGER NOT NULL DEFAULT 0 CHECK (applied IN (0,1))
);
CREATE INDEX IF NOT EXISTS idx_staff_outcomes_agent ON staff_outcomes(agent, class, outcome, resolved_at);
CREATE INDEX IF NOT EXISTS idx_staff_outcomes_family ON staff_outcomes(family, outcome, id);
CREATE TABLE IF NOT EXISTS staff_promotions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT NOT NULL,
  from_level TEXT NOT NULL CHECK (from_level IN ('automation','augmentation','autonomy')),
  to_level TEXT NOT NULL CHECK (to_level IN ('automation','augmentation','autonomy')),
  agreements INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','applied','void')),
  created_at TEXT NOT NULL,
  decided_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_staff_promotions_pending ON staff_promotions(agent) WHERE status = 'pending';
-- The retention cutoff reads (oldest first through an index, never a scan).
CREATE INDEX IF NOT EXISTS idx_staff_outcomes_resolved ON staff_outcomes(resolved_at);
CREATE INDEX IF NOT EXISTS idx_staff_promotions_decided ON staff_promotions(status, decided_at);
CREATE UNIQUE INDEX IF NOT EXISTS ux_staff_suppressions_pending ON staff_suppressions(fingerprint) WHERE status = 'pending';
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.noise_suppress_after','3','BH-5563: same-family noise closures before a staff suppression is proposed (pending until a human approves)','seed','2026-10-14T00:00:00Z'),
  ('staff.noise_suppress_days','30','BH-5563: days an approved staff noise suppression lasts','seed','2026-10-14T00:00:00Z'),
  ('retention.staff_outcomes.days','180','BH-5563: days an applied staff outcome is kept, and never one since its agent''s last change (0 = off). History rows: precision and noise counts read them; no archive store yet (#6777).','seed','2026-10-14T00:00:00Z'),
  ('retention.staff_promotions.void_days','30','BH-5563: days a void staff promotion is kept after its decision (0 = off)','seed','2026-10-14T00:00:00Z'),
  ('retention.staff_promotions.applied_days','180','BH-5563: days an applied staff promotion is kept after its decision (0 = off). A pending one is never removed.','seed','2026-10-14T00:00:00Z');
