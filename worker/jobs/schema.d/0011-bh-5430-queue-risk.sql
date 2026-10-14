
-- ── BH-5430: the merge-queue break-risk score ───────────────────────────────
-- One row per scored PR head, written by bin/lib/queue-risk.sh (qr_enqueue_step,
-- called from mc_enqueue_mergify) through POST /api/queue-risk on every enqueue
-- in a mode other than off; read by Mission Control's MERGE QUEUE BREAK RISK
-- badge. Unlike risk_tiers, the same head is UPDATED, not kept: a re-enqueue
-- under changed queue_risk.* rows must show the new routing. score is NULL when
-- the PR's files were unreadable (route batch, reason files-unavailable).
-- route: solo | batch. mode: off | shadow | enforce. reasons: comma-joined
-- signal:+weight(evidence) tokens. Enum values sit in comments, not CHECKs (D1
-- cannot ALTER a CHECK). D1, not Supabase: no RLS, the worker bearer is the
-- access boundary. Self-create copy: CREATED_TABLES.queue_risk_scores in
-- src/lib/core.js.
CREATE TABLE IF NOT EXISTS queue_risk_scores (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL,              -- owner/name
  pr INTEGER NOT NULL,
  head_sha TEXT NOT NULL,          -- the full 40-hex sha that was scored
  project TEXT,
  score INTEGER,                   -- NULL = files unreadable
  threshold INTEGER NOT NULL,      -- score >= threshold routes solo
  route TEXT NOT NULL,             -- solo | batch
  mode TEXT NOT NULL,              -- off | shadow | enforce
  reasons TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(repo, pr, head_sha)
);
CREATE INDEX IF NOT EXISTS idx_queue_risk_scores_repo_pr ON queue_risk_scores(repo, pr);
CREATE INDEX IF NOT EXISTS idx_queue_risk_scores_route ON queue_risk_scores(route, id);

-- BH-5430 knobs, one seed per statement (see gh_quota_alert_pct above). bin/lib/queue-risk.sh
-- reads each row; its QR_*_DEFAULT constants are only the fallbacks. INSERT OR IGNORE: a
-- deploy never resets an operator's edit. mode is shadow: on the last 50 merges to main the
-- fallback rules routed 38 solo (76%), which would serialize the queue; raise the threshold
-- (100 routed 11 of 50) before setting enforce.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.mode','shadow','BH-5430: merge-queue break-risk routing: off|shadow|enforce. shadow logs QRISK lines and records scores, writes no label','seed','2026-10-08T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.threshold','50','BH-5430: a PR whose break-risk score is >= this gets the queue-solo label (size-1 solo queue)','seed','2026-10-08T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.weight.shared_lib','30','BH-5430: break-risk weight of the shared_lib signal, counted once per PR','seed','2026-10-08T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.weight.ci_config','40','BH-5430: break-risk weight of the ci_config signal, counted once per PR','seed','2026-10-08T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.weight.registry','25','BH-5430: break-risk weight of the registry signal, counted once per PR','seed','2026-10-08T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.weight.generated','20','BH-5430: break-risk weight of the generated signal, counted once per PR','seed','2026-10-08T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.weight.share_mirror','30','BH-5430: break-risk weight of the share_mirror signal, counted once per PR','seed','2026-10-08T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.weight.schema','40','BH-5430: break-risk weight of the schema signal, counted once per PR','seed','2026-10-08T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.weight.new_tests','10','BH-5430: break-risk weight of the new_tests signal, counted once per PR','seed','2026-10-08T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.weight.size','15','BH-5430: break-risk weight of the size signal, counted once per PR','seed','2026-10-08T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.weight.size_files','10','BH-5430: break-risk weight of the size_files signal, counted once per PR','seed','2026-10-08T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.weight.ejected_before','25','BH-5430: break-risk weight of the ejected_before signal, counted once per PR','seed','2026-10-08T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.weight.prequeue_red','20','BH-5430: break-risk weight of the prequeue_red signal, counted once per PR','seed','2026-10-08T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.globs.shared_lib','bin/lib/*','BH-5430: paths of the shared_lib signal, space-separated globs','seed','2026-10-08T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.globs.ci_config','.github/* .mergify.yml config/mergify/* bin/test-impact* bin/ci-plan.sh','BH-5430: paths of the ci_config signal, space-separated globs','seed','2026-10-08T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.globs.registry','catalog/* cron/* worker/jobs/src/index.js','BH-5430: paths of the registry signal, space-separated globs','seed','2026-10-08T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.globs.generated','rules/CLAUDE.md env-templates/*','BH-5430: paths of the generated signal, space-separated globs','seed','2026-10-08T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.globs.share_mirror','bin/share/*','BH-5430: paths of the share_mirror signal, space-separated globs','seed','2026-10-08T00:00:00Z');
-- BH-6011: worker/jobs/schema.sql left git, so a schema PR's diff names only
-- worker/<w>/schema.d/ fragments; the schema signal matches them too. On an
-- existing DB only the untouched BH-5430 seed row moves (actor seed, the old
-- value), the BH-4762 shape: an operator's row is left alone, and a second
-- apply matches nothing.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.globs.schema','worker/jobs/schema.sql worker/*/schema.d/* *migrations/* worker/jobs/src/lib/core.js','BH-5430, BH-6011: paths of the schema signal, space-separated globs','seed','2026-10-13T00:00:00Z')
  ON CONFLICT(key) DO UPDATE SET value = excluded.value, note = excluded.note, updated_at = excluded.updated_at
  WHERE settings.actor = 'seed' AND settings.value = 'worker/jobs/schema.sql *migrations/* worker/jobs/src/lib/core.js';
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.size_lines','400','BH-5430: additions+deletions at or above this add the size weight','seed','2026-10-08T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.size_lines_big','1000','BH-5430: additions+deletions at or above this add the size weight a second time','seed','2026-10-08T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('queue_risk.size_files','15','BH-5430: changed files at or above this add the size_files weight','seed','2026-10-08T00:00:00Z');
