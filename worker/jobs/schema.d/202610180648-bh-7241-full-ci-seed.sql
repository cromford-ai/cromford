
-- ── BH-7241: the full-ci label at PR open, on for project-6-os ──────────────
-- project-6's CI (ci.yml, scripts/ci/lane.mjs) reads the `full-ci` label to run
-- its full lane. bin/lib/rb-full-ci-label.sh adds it at PR open when this row
-- is set; every other project has no row and stays off. INSERT OR IGNORE, so a
-- re-apply never moves a value an operator wrote.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lib.rb-full-ci-label.project-6-os.full_ci_label','full-ci','BH-7241: project-6 CI reads this label to run its full lane; the builder adds it at PR open','seed','2026-10-17T00:00:00Z');
