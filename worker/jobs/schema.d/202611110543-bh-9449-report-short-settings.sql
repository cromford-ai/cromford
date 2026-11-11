-- ── BH-9449: the short daily factory report (Telegram) ────────────────────────
-- Additive only: no table, no DROP, no UPDATE. INSERT OR IGNORE, so a re-apply
-- never resets a value an operator changed. One statement per seed
-- (bin/harness-sync.sh applies the file statement by statement, BH-1000).
-- Read by bin/archie-fm-report.sh (afr_knob) and passed to afr_render_short
-- (bin/lib/archie-fm-report/render.sh). Each reader names its row at its code
-- fallback; the fallbacks equal these seeds (tests/archie-fm-report-short.bh-9449-test.sh A13).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('report.spend_min_usd','5.00','BH-9449: the daily Telegram factory report lists a project by name when its day spend is over this many USD (or over report.spend_cap_pct of its cap); the rest are one "N other projects" line. Read by bin/archie-fm-report.sh, code fallback 5.00','seed','2026-11-10T23:10:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('report.spend_cap_pct','50','BH-9449: the daily Telegram factory report lists a project by name when its day spend is over this percent of its day cap (or over report.spend_min_usd). Read by bin/archie-fm-report.sh, code fallback 50','seed','2026-11-10T23:10:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('report.spend_unknown_min_usd','1.00','BH-9449: the daily Telegram factory report shows the spend key unknown, with its call count, when it is over this many USD (a pricing or attribution defect). Read by bin/archie-fm-report.sh, code fallback 1.00','seed','2026-11-10T23:10:00Z');
