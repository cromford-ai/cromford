-- BH-7541: one row per verdict route that gave up on a D1 overload
-- (lib/d1-giveup.js). The route sends a Sentry event only on every Nth
-- give-up of a streak (HARNESS_D1_GIVEUP_REPORT_AFTER, default 3). Fixed size:
-- one row per route name, upserted in place, so it has no retention job.
-- no-index: d1_overload_streaks one row per route name (2 rows), PK lookup only
CREATE TABLE IF NOT EXISTS d1_overload_streaks (
  route TEXT PRIMARY KEY,         -- "GET /api/verdict"
  consecutive INTEGER NOT NULL,   -- give-ups in the current streak
  first_at TEXT NOT NULL,         -- first give-up of the streak
  last_at TEXT NOT NULL           -- latest give-up
);
