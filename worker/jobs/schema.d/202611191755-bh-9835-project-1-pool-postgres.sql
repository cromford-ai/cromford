-- BH-9835: the throwaway Postgres (BH-5962) ON for the project-1 pool suite run.
-- Why: with no lane.fly-pool.project-1 rows the suite ran with no DATABASE_URL,
-- went red with a Prisma DB signature, and sp_build_post recorded
-- `could-not-run: DATABASE_URL (suite rc 1)` for TK-353, TK-406 and TK-329
-- (2026-11-19). The setup row pushes the repo's prisma schema into the empty
-- throwaway, so a red suite is the code's red, not an empty database.
-- Reader: bin/lib/pg-test.sh pgt_knob -> lane_knob fly-pool <ENV> project-1
-- (bin/lib/lane-gate.sh). The URL is always 127.0.0.1 (pgt_env, pgt_local_url).
-- No major row: the registry default 16 is the only major the pool image holds.
-- Off: set lane.fly-pool.project-1.pool_test_postgres to 0.
-- INSERT OR IGNORE: a row an operator already wrote is kept.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane.fly-pool.project-1.pool_test_postgres','1','BH-9835: throwaway Postgres for the project-1 pool suite run. Reader: bin/lib/pg-test.sh pgt_enabled (fallback 0 = off).','seed','2026-11-19T17:55:00Z'),
  ('lane.fly-pool.project-1.pool_test_setup_cmd','prisma db push','BH-9835: push the repo prisma schema into the throwaway before the suite. Reader: bin/lib/pg-test.sh pgt_setup (fallback empty = no setup).','seed','2026-11-19T17:55:00Z');
