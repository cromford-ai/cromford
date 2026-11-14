-- ── BH-9582: the lead review is asked for on the PR event ──────────────────
-- Read by bin/lib/wake-class-pr-lead.sh (wc_pr_lead_dispatch, through
-- setting_get), once per wake drain that holds a pr opened / reopened /
-- ready_for_review / synchronize event.
-- lead_review.event_wake.enabled: 1 = ring the lead-review doorbell for that
-- PR head; 0 = off (the */15 cron still covers lead review).
-- lead_review.event_wake.reads_max: GitHub PR reads per drain (1..200, code
-- fallback 20); PRs over the cap are left to the */15 cron.
-- No table is created here (D1, not Supabase: no RLS, index or retention rule
-- applies). INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lead_review.event_wake.enabled','1','BH-9582: 1 = a pr opened/reopened/ready_for_review/synchronize wake rings the lead-review doorbell (bin/lib/wake-class-pr-lead.sh). 0 = off; the */15 cron still covers lead review.','seed','2026-11-14T07:58:00Z'),
  ('lead_review.event_wake.reads_max','20','BH-9582: GitHub PR reads per wake drain in bin/lib/wake-class-pr-lead.sh (whole number 1..200; code fallback 20). PRs over the cap are left to the */15 cron.','seed','2026-11-14T07:58:00Z');
