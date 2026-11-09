-- ── BH-8364: the builds/ retention lane's rr-relay read cap ─────────────────
-- Read by bin/builds-retention.sh through setting_get. A missing row, an
-- outage or a bad value falls back to the code default 200. No table is
-- created here (D1, not Supabase: no RLS applies). INSERT OR IGNORE: an
-- operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('builds_retention.relay_reads_max','200','BH-8364: rr-relay reads per builds-retention run; a pool- dir whose sent relay json is parked and not consumed is kept (relay-parked). Past the cap the group is judged as before (relay_deferred). 0 = no reads. Code default 200','seed','2026-11-04T16:06:00Z');
