-- BH-7598 (slice C0): a person completes a 2FA step of a web-task run.
-- routes/web-task-human.js writes and reads it; bin/lib/web-human.sh is the
-- client. Contract: docs/notes/2026-10-23-BH-7598-web-task-human.md.
--
-- One row per human step a claimed web-task run asks for. D1 keeps the SHA-256
-- of the step nonce only, never the nonce. A code a person sends is AES-GCM
-- ciphertext (code_ct, code_iv, key_id: the web_vault key, aad
-- web-task-human:<id>) until the run polls it; that poll sets both columns to
-- NULL in the same UPDATE (used once). prompt holds the step text the run
-- asked with, never a code. A new ask of the same run sets the run's open step
-- to 'superseded', so its nonce is "old".
-- RETENTION: rule web_task_human_step.age in routes/retention.js, window
-- retention.web_task_human_step.days (30), under retention.dry_run. A row is
-- a short-lived request, not money or history, so it is deleted, not archived.
-- The window is longer than the largest answer TTL (7 days), so an open step
-- is never deleted while its nonce can still be answered.
CREATE TABLE IF NOT EXISTS web_task_human_step (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id INTEGER NOT NULL,
  project TEXT NOT NULL,
  site TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('code','approve')),
  prompt TEXT NOT NULL,
  nonce_hash TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('open','answered','consumed','cancelled','superseded')),
  created_at TEXT NOT NULL,
  wait_until TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  answered_at TEXT,
  answer_via TEXT,
  code_ct TEXT,
  code_iv TEXT,
  key_id INTEGER,
  consumed_at TEXT,
  tg_outcome TEXT,
  board_outcome TEXT
);
-- The answer lookup: nonce_hash=?. One step per nonce.
CREATE UNIQUE INDEX IF NOT EXISTS uq_web_task_human_nonce ON web_task_human_step(nonce_hash);
-- The supersede of an ask: run_id=? AND status='open'.
CREATE INDEX IF NOT EXISTS idx_web_task_human_run ON web_task_human_step(run_id, status);
-- The retention id read: created_at < ? ORDER BY created_at LIMIT ?.
CREATE INDEX IF NOT EXISTS idx_web_task_human_created ON web_task_human_step(created_at);

INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('web_task.human_wait_s','300','BH-7598: seconds a web-task run waits for a person to answer a 2FA step (10..3600) before it stops with waiting on human; the ask answer carries it as wait_until; WEB_TASK_HUMAN_WAIT_S on the box can only shorten it; the code default is 300','seed','2026-10-23T00:00:00Z'),
  ('web_task.human_poll_s','5','BH-7598: seconds between two polls of a waiting web-task run (1..60); the code default is 5','seed','2026-10-23T00:00:00Z'),
  ('web_task.human_answer_ttl_s','86400','BH-7598: seconds a 2FA step nonce takes an answer (60..604800), so a later answer is kept for the resume run; never before wait_until; the code default is 86400','seed','2026-10-23T00:00:00Z'),
  ('web_task.human_logins','operator','BH-7598: comma list of GitHub logins whose HUMAN-STEP-DONE: comment answers a web-task 2FA step; bots never count; the code default is the empty list (no board answers)','seed','2026-10-23T00:00:00Z'),
  ('retention.web_task_human_step.days','30','BH-7598: days a web_task_human_step row is kept before the hourly retention run deletes it (0 = off); keep it above the 7-day answer TTL maximum; the code default is 30','seed','2026-10-23T00:00:00Z');
