-- ── BH-7725 (UNB-3): the Tackler infra family's settings rows ───────────────
-- unblock.knob_allowlist: the ONLY settings keys rule U9 may propose to change
-- (comma list, * is a glob), and only inside the knob's registry [min,max]
-- (catalog/lanes.d/<lane>.knobs.d). the operator 6294290004 item 3 set it to exactly
-- these five entries. Spend, CI shard and review caps stay with the operator.
-- lane.unblock.unblock_box_hung_min / unblock_respawn_max_day: the U8 and U9
-- thresholds (code defaults 30 and 6 in bin/lib/unblock/collectors/infra.sh).
-- No unblock.project.*.mode row: act mode (UNB-4, #7726) stays off.
-- No table is created here. INSERT OR IGNORE: an operator's row survives.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('unblock.knob_allowlist','lane.fly-pool-tick.pool_tick_max_parallel,hub_load.shed,lane.fly-pool.*.pool_record_read,lane_placement.*,conductor_remote_spawn.*','BH-7725: the settings keys Tackler rule U9 may propose to change, always inside the registry [min,max]; spend, CI shard and review caps stay with the operator (6294290004 item 3)','seed','2026-10-20T00:00:00Z'),
  ('lane.unblock.unblock_box_hung_min','30','BH-7725: minutes a running Orgo box must be ssh-unreachable before rule U8 may restart it','seed','2026-10-20T00:00:00Z'),
  ('lane.unblock.unblock_respawn_max_day','6','BH-7725: respawns of one ticket key in a day above which rule U9 sees a respawn loop','seed','2026-10-20T00:00:00Z');
