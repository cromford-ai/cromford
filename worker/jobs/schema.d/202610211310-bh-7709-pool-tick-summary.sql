-- ── BH-7709: pool_tick_summary (why a pool project's queued rows do not spawn) ─
-- One row per pool project. The hub lane bin/pool-tick-summary.sh reads the
-- tail of logs/fly-pool.log every 2 minutes, finds each project's last tick,
-- and posts its header counts, one decision per row key, what stopped the tick
-- or the last start, the last hour's env bundle failures and max-ticks waits,
-- and today's respawns. GET /api/pool/status returns one project's row, flat,
-- to the MCP pool_status tool and to the BH-7725 unblock collector.
-- Routes: worker/jobs/src/routes/pool-tick.js.
-- Note: docs/notes/2026-10-21-BH-7709-pool-status-mcp.md.
--
-- INDEXES. The upsert ON CONFLICT(project) and the GET WHERE project = ?1 use
-- the PRIMARY KEY autoindex (sqlite_autoindex_pool_tick_summary_1).
-- no-index: pool_tick_summary one row per pool project (about 5); the PRIMARY KEY serves the upsert and the GET
--
-- RETENTION. The table does not grow: each run overwrites the project's one
-- row. A project that leaves the pool keeps its last row; pool_status shows its
-- age and `stale`. No scheduled delete.
--
-- summary_json holds keys, classes, counts and times only, never log text.
-- reported_at is the worker clock. D1 has no RLS; the worker bearer guards /api/*.
CREATE TABLE IF NOT EXISTS pool_tick_summary (
  project TEXT PRIMARY KEY,
  reported_at TEXT NOT NULL,
  summary_json TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
