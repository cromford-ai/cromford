
-- ── BH-4155 (BH-4141.3): cost/lane caps as seed rows ───────────────────────
-- The DB copy of catalog/cost-caps.conf and catalog/lane-caps.conf, generated
-- from `bin/cost-caps-seed.sh --dry-run` (tests/caps-seed-rows.bh-4155-test.sh
-- S1 holds the two equal). Actor `registry-seed`, the actor that script writes
-- and the console's CAPS screen reads as the catalog value. bin/lib/cost-budget.sh
-- and bin/lib/lane-caps.sh read these rows ABOVE the committed file and BELOW
-- flags/<file> and an operator row. INSERT OR IGNORE, one row per statement, so
-- a re-apply never moves a cap an operator (or an earlier seed run) wrote.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conf.cost-caps.budget.project-4','95 5','BH-4155: seeded from catalog/cost-caps.conf','registry-seed','2026-10-04T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conf.cost-caps.budget.project-8','90 3','BH-4155: seeded from catalog/cost-caps.conf','registry-seed','2026-10-04T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conf.cost-caps.budget.project-6','100 3','BH-4155: seeded from catalog/cost-caps.conf','registry-seed','2026-10-04T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conf.cost-caps.budget.project-1','155 3','BH-4155: seeded from catalog/cost-caps.conf','registry-seed','2026-10-04T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conf.cost-caps.budget.project-3','95 5','BH-4155: seeded from catalog/cost-caps.conf','registry-seed','2026-10-04T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conf.cost-caps.budget.project-9','100 3','BH-4155: seeded from catalog/cost-caps.conf','registry-seed','2026-10-04T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conf.cost-caps.budget.project-2','100 5','BH-4155: seeded from catalog/cost-caps.conf','registry-seed','2026-10-04T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conf.cost-caps.budget.project-7','85 5','BH-4155: seeded from catalog/cost-caps.conf','registry-seed','2026-10-04T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conf.cost-caps.budget.project-5','85 10','BH-4155: seeded from catalog/cost-caps.conf','registry-seed','2026-10-04T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conf.cost-caps.ceiling','10000','BH-4155, BH-7876: seeded from catalog/cost-caps.conf','registry-seed','2026-10-04T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conf.cost-caps.default','100 5','BH-4155: seeded from catalog/cost-caps.conf','registry-seed','2026-10-04T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conf.lane-caps.default','50 20000','BH-4155: seeded from catalog/lane-caps.conf','registry-seed','2026-10-04T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conf.lane-caps.lane.alert-triage','5 20000','BH-4155: seeded from catalog/lane-caps.conf','registry-seed','2026-10-04T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conf.lane-caps.lane.medic','90 40000','BH-4155: seeded from catalog/lane-caps.conf','registry-seed','2026-10-04T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conf.lane-caps.lane.responder','150 60000','BH-4155: seeded from catalog/lane-caps.conf','registry-seed','2026-10-04T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conf.lane-caps.noise.alert-triage','10','BH-4155: seeded from catalog/lane-caps.conf','registry-seed','2026-10-04T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conf.lane-caps.noise.default','10','BH-4155: seeded from catalog/lane-caps.conf','registry-seed','2026-10-04T00:00:00Z');
