-- BH-6888 (BH-6881.4): the conductor's rebase on a lane-run machine as a
-- queued pool job. No table and no index: the dedup is the build_queue row by
-- its primary key (project, ticket_key).
-- The switch ships OFF. conductor_remote_spawn.<project> wins over the fleet
-- row when present; only the exact value 1 is on (bin/lib/mc/spawn-remote.sh).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conductor_remote_spawn','0','BH-6888: 1 = on a lane-run machine (MC_ON_MACHINE=1) with a pool app, the conductor enqueues its rebase as one build_queue row RB-<pr>-<head8> and reads the result back through the queue API; conductor_remote_spawn.<project> wins when present; anything but 1, no row or an outage is off (the hub runs the PR, deferred=rebase); the code default is off','seed','2026-10-15T00:00:00Z'),
  ('conductor_remote_retry_max','3','BH-6888: a machine-enqueued rebase row that ended failed (or done + REBASE_SETUP_FAILED) is put again while its attempt is below this; at the cap the machine hands the PR back to the hub; the code default is 3','seed','2026-10-15T00:00:00Z');
