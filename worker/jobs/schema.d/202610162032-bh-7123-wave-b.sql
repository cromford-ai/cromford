-- ── BH-7123 wave B: no follow-up chains ──────────────────────────────────────
-- review.followup_chain: 0 (default) = bin/lib/gh-shim/issue-write.sh refuses a
-- `gh issue create` from a build whose own ticket is a follow-up (first body
-- line `Follow-up-of: #<n>`, or the QA marker `<!-- findings-followup-of: -->`),
-- and bin/lib/group-findings.sh comments on a follow-up instead of filing a
-- follow-up of it. 1 = the guard is off (chains allowed). Read through
-- setting_get at the shim; an unreadable row is 0. Operator flip:
-- bin/jobs-client.sh setting-set review.followup_chain 1 "<why>" (audited in
-- config_changes). Settings rows only; no new table; D1/SQLite, no RLS.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('review.followup_chain','0','BH-7123: 0 = a ticket that is itself a follow-up files no follow-ups (gh shim + group-findings refuse); 1 = chains allowed','seed','2026-10-16T16:00:00Z');
