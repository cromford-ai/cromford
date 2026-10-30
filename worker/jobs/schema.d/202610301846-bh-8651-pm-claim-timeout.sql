-- BH-8651: minutes after which POST /api/pm/briefs/claim releases a `claimed`
-- PM brief row that no run finished (src/routes/pm-brief.js claimTimeoutMin).
-- No table: the release re-stamps the pm_briefs row and writes one
-- stage_events CLAIM_RELEASED row. A project row
-- lane.pm-groom.<project>.pm_claim_timeout_min wins over this one. 0 is off;
-- a value that is not 0 or 30..10080 is the code fallback 120. Catalog
-- fragment: catalog/lanes.d/pm-groom.knobs.d/PM_CLAIM_TIMEOUT_MIN.json.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('lane.pm-groom.pm_claim_timeout_min','120','BH-8651: minutes after which a claimed PM brief row that no run finished is released to the next claim (0 = off, else 30..10080); one stage_events CLAIM_RELEASED row per release','seed','2026-10-30T18:46:00Z');
