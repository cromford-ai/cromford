-- ── BH-7876: the project-6-os daily spend ceiling as a seed row ─────────────
-- The DB copy of catalog/cost-caps.conf's `daily project-6-os 5000` line (the operator,
-- 2026-10-21, ticket comment 6326016557), keyed the way bin/lib/cost-budget.sh
-- _cb_row reads it and bin/cost-caps-seed.sh writes it. Actor `registry-seed`,
-- so tests/caps-seed-rows.bh-4155-test.sh S1 holds it equal to the catalog and
-- POST /api/cost-caps/seed keeps it (a seed row absent from the body is pruned).
-- INSERT OR IGNORE: the operator row the operator already wrote is never moved.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conf.cost-caps.project-6-os.daily_usd','5000','BH-7876: seeded from catalog/cost-caps.conf','registry-seed','2026-10-21T00:00:00Z');
