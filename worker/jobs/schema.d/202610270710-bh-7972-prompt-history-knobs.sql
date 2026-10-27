-- ── BH-7972 (BH-7940.4): the prompt history knobs ──────────────────────────
-- prompts.versions_list_max caps GET /api/prompts/:scope/:kind/versions
-- (routes/prompt-history.js; fallback 200, valid 1..1000).
-- retention.prompt_versions.days is the age floor of the prompt_versions.archive
-- retention rule (routes/retention.d/bh-7972-prompt-versions.js; 0 = off), so a
-- burst of saves never archives a version minutes old. The rule also keeps the
-- newest prompts.retention.keep_versions per key (seeded by BH-7940.0).
-- No table here, so no index. Only INSERT OR IGNORE: a re-apply is a no-op.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('prompts.versions_list_max','200','BH-7972: the most prompt versions GET /api/prompts/:scope/:kind/versions lists, newest first (1..1000).','seed','2026-10-27T07:10:00Z'),
  ('retention.prompt_versions.days','30','BH-7972: a prompt version must be older than this many days before retention archives it (also outside the newest prompts.retention.keep_versions, never a head). 0 = off.','seed','2026-10-27T07:10:00Z');
