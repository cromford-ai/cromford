-- ── BH-7710: box_ssh_state (does the hub reach each box over ssh) ─────────────
-- One row per registry box. The hub lane bin/box-ssh-probe.sh ssh's every box
-- with a tailnet IP every 2 minutes (`ssh root@<ip> true`) and posts the rc,
-- plus the count of pool env bundle ssh failures for that IP inside the
-- pool-tailnet window (state/pool-tailnet/<ip>.fails, bin/lib/pool-tailnet.sh).
-- GET /api/box-health joins it with the registry, the heartbeats and the VM
-- state for the MCP box_health and box_restart tools.
-- Routes: worker/jobs/src/routes/box-ssh.js.
-- Note: docs/notes/2026-10-20-BH-7710-box-health-mcp.md.
--
-- INDEXES. The upsert ON CONFLICT(box) uses the PRIMARY KEY autoindex
-- (sqlite_autoindex_box_ssh_state_1). The GET reads every row (LIMIT 201) of a
-- table that holds one row per box.
-- no-index: box_ssh_state one row per registry box (about 12); the PRIMARY KEY serves the upsert and the GET reads every row
--
-- RETENTION. The table does not grow: each tick overwrites the box's one row.
-- A box that leaves the registry keeps its last row; GET /api/box-health lists
-- registry boxes only, so that row is never shown. No scheduled delete.
--
-- probed_at and last_ok_at are the worker clock, never the hub clock.
-- last_ok_at is the probed_at of the newest report with probe_rc 0; the upsert
-- keeps it across failed reports. D1 has no RLS; the worker bearer guards /api/*.
CREATE TABLE IF NOT EXISTS box_ssh_state (
  box TEXT PRIMARY KEY,
  tailnet_ip TEXT,
  probe_rc INTEGER NOT NULL,
  probed_at TEXT NOT NULL,
  last_ok_at TEXT,
  lane_fails INTEGER NOT NULL DEFAULT 0,
  lane_window_s INTEGER NOT NULL DEFAULT 900,
  lane_last_fail_at TEXT,
  updated_at TEXT NOT NULL
);
