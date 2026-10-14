
-- ── BH-5750: box_commands_v2 ──
-- box_commands with a wider type CHECK: the five BH-2518 types plus the nine
-- Mission Control box controls (Orgo restart/stop/resize/retire/launch and
-- their price quotes, the Fly pool cap and onboard). A CHECK cannot change in
-- place on D1 (an edited CREATE TABLE IF NOT EXISTS is a no-op, BH-1555) and a
-- rebuild needs a DROP, so this is a new table. The worker reads and writes
-- only this one; box_commands stays as it is and is never dropped. The copy
-- below keeps every history row and its id, and INSERT OR IGNORE makes a
-- re-apply a no-op. All nine new types land here at once so no later change
-- needs a third table.
-- D1 has no RLS. The worker bearer auth guards /api/*.
CREATE TABLE IF NOT EXISTS box_commands_v2 (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  box TEXT NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('backup_now','fly_machine_stop','fly_machine_destroy','harness_sync','cli_update','orgo_restart','orgo_stop','orgo_resize_quote','orgo_resize','orgo_retire','orgo_launch_quote','orgo_launch','fly_pool_cap','fly_onboard')),
  target TEXT NOT NULL DEFAULT '',
  args TEXT,
  reason TEXT NOT NULL CHECK (length(trim(reason)) > 0),
  status TEXT NOT NULL CHECK (status IN ('requested','claimed','ok','fail')),
  requested_by TEXT,
  requested_at TEXT NOT NULL,
  claimed_by TEXT,
  claimed_at TEXT,
  finished_at TEXT,
  detail TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS box_commands_v2_open ON box_commands_v2(box, type, target) WHERE status IN ('requested','claimed');
CREATE INDEX IF NOT EXISTS box_commands_v2_box_status ON box_commands_v2(box, status, id);
INSERT OR IGNORE INTO box_commands_v2 (id,box,type,target,args,reason,status,requested_by,requested_at,claimed_by,claimed_at,finished_at,detail)
  SELECT id,box,type,target,args,reason,status,requested_by,requested_at,claimed_by,claimed_at,finished_at,detail FROM box_commands;
