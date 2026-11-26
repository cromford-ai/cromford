-- ── BH-10102: the console fetch_log window and response size as knobs ───────
-- Each value equals the code fallback in bin/fetch-log.sh (FL_TAIL_FALLBACK,
-- FL_RESP_FALLBACK) and the registry default in
-- catalog/lanes.d/_lib.fetch-log.json. No table: settings rows only.
-- INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lib.fetch-log.fetch_log_tail_bytes','5242880','BH-10102: newest bytes of a log (or of the match/since/until result) one fetch_log reads; ceiling 16777216 in code','seed','2026-11-25T15:23:00Z'),
  ('lib.fetch-log.fetch_log_response_bytes','98304','BH-10102: most bytes of one encoded log_tail beat; under the 131072-byte argv limit of beat.sh and curl -d','seed','2026-11-25T15:23:00Z');
