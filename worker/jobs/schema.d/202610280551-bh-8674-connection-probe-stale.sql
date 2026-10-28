-- ── BH-8674: the /connections LAST PROBE stale bound ───────────────────────
-- connections.probe_stale_min is the age in minutes after which the console's
-- /connections screen shows a probe age as stale (console-ui
-- src/lib/connections.js probeStaleMin; fallback 120, a value that is not a
-- finite number >= 1 is ignored). The connection-probe lane runs hourly, so
-- 120 is one missed run plus margin.
-- No table here, so no index. Only INSERT OR IGNORE: a re-apply is a no-op.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('connections.probe_stale_min','120','BH-8674: minutes after which /connections shows a probe age as stale (lane connection-probe runs hourly, so 120 = one missed run).','seed','2026-10-28T05:51:00Z');
