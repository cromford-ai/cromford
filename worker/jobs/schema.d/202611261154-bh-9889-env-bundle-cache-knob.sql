-- ── BH-9889 (C0): the hub cache of the pool env bundle ──────────────────────
-- pool.env_bundle_cache_max_h: the max age in hours of the hub's last good env
-- bundle per project ($HARNESS/state/bundle-cache/<project>.raw, mode 600). Read by
-- bin/fly-envbundle.sh --pool only, when the owning box does not answer (ssh
-- rc 255). Range 0..168; 0 = off (no read, no write); a bad value reads 24 with
-- one WARN. No row: env POOL_ENV_BUNDLE_CACHE_MAX_H, then 24.
-- No table is created here, so no index or RLS applies.
-- INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('pool.env_bundle_cache_max_h','24','BH-9889: hours a hub cache of the pool env bundle may serve a spawn when the owning box does not answer (ssh rc 255); 0..168, 0 = off','seed','2026-11-25T21:12:00Z');
