-- ── BH-4985: the plan-time size gate's limits (the operator, 2026-10-06) ────────────
-- bin/size-threshold.sh reads size_gate.<axis>.<project> then size_gate.<axis>
-- before the box flag, the catalog and its own 1200/30 fallback. Actor `seed`,
-- not `registry-seed`: lane-gate files registry-seed rows under `.seeded`, which
-- no lookup reads. INSERT OR IGNORE, so an operator's edit on /config survives
-- every re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('size_gate.lines','1200','the operator 2026-10-14, #5520 split-chain report, #6025 (was 700 from 2026-10-06, #4985): plan-time size gate line limit (product lines); size_gate.lines.<project> overrides per project','seed','2026-10-14T00:00:00Z'),
  ('size_gate.files','30','the operator 2026-10-14, #5520 split-chain report, #6025 (was 20 from 2026-10-06, #4985): plan-time size gate file limit; size_gate.files.<project> overrides per project','seed','2026-10-14T00:00:00Z');

