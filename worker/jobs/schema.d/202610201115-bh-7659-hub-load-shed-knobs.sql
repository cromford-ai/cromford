-- ── BH-7659: the hub load shed knobs as settings rows ──────────────────────
-- Read by bin/hub-load-sample.sh through setting_get, row first, then env,
-- then the code default (the values below). The sampler writes the resolved
-- values into state/hub-load/verdict, so the spawners make no settings call.
-- hub_load.shed_lanes = 'catalog' is no override: the lane list is every
-- `"sheds": true` lane in catalog/lanes.d. Write an id list to override it.
-- No table is created here. INSERT OR IGNORE: an operator's row survives.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('hub_load.verdict_max_age_s','1800','BH-7659: seconds a hub load verdict stays fresh; an older verdict never sheds','seed','2026-10-20T00:00:00Z'),
  ('hub_load.shed','on','BH-7659: the hub load shed kill switch; off, 0 or false stop every shed','seed','2026-10-20T00:00:00Z'),
  ('hub_load.shed_lanes','catalog','BH-7659: the project lanes that shed while the hub is over; catalog = every "sheds": true lane, else a comma list of lane ids','seed','2026-10-20T00:00:00Z');
