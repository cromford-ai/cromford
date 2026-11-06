-- BH-9063 (C0): the suite ledger's trust knob and the retention windows of
-- its two tables. Data only: no new table, so no RLS applies (D1 is SQLite).
-- INSERT OR IGNORE keeps an operator's value. The code fallbacks equal these
-- values (test/suite-results-retention.bh-9063.test.js R4).
--
-- lib.suite-reuse.suite_reuse_trust  class|image, read by
--   src/lib/suite-trust.js on every POST /api/suite-results/lookup. class =
--   the BH-5354 I1 rule (own ctx only; a ci caller sees ci rows only). image =
--   match (repo, suite, fingerprint) in every class and ctx. Any other value
--   turns reuse off. Reads under image use idx_suite_results_fp
--   (src/lib/core.d/bh-9063-suite-results-fp.js); under class they use
--   idx_suite_results_key or the primary key, as before.
-- retention.suite_results.days  14: POST /api/retention/run, rule
--   suite_results.age (src/routes/retention.d/bh-9063-suite-ledger.js), reads
--   ids by idx_suite_results_updated. retention.dry_run applies.
-- retention.suite_reuse_runs.days  60: rule suite_reuse_runs.age, reads ids by
--   idx_suite_reuse_runs_created. 60 = SAVED_DAYS_MAX, Mission Control's
--   longest SUITE REUSE range.
-- Rollback: set a window to 0 (the rule is off) or the trust row to class.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lib.suite-reuse.suite_reuse_trust','class','BH-9063: class|image; class = a lookup matches its own ctx and a ci caller sees ci rows only; image = match repo+suite+fingerprint in every class and ctx; any other value turns reuse off','seed','2026-11-05T00:00:00Z'),
  ('retention.suite_results.days','14','BH-9063: days a suite_results row is kept after its last write (rule suite_results.age); 0 = rule off','seed','2026-11-05T00:00:00Z'),
  ('retention.suite_reuse_runs.days','60','BH-9063: days a suite_reuse_runs row is kept (rule suite_reuse_runs.age); 60 = Mission Control SUITE REUSE max range; 0 = rule off','seed','2026-11-05T00:00:00Z');
