-- The hotfix tier (the operator, 2026-10-07): a ticket labelled `hotfix` is sized against
-- size_gate.<axis>.hotfix.<project> then size_gate.<axis>.hotfix before the rows
-- above, so an emergency builds as one PR instead of being split. Its own
-- statement (BH-1000), INSERT OR IGNORE so an edit on /config survives re-apply.
-- No row (an unapplied schema) means the hotfix falls back to the 1200/30 chain.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('size_gate.lines.hotfix','1500','the operator 2026-10-07: plan-time size gate line limit for hotfix tickets (build as one PR, not split); size_gate.lines.hotfix.<project> overrides per project','seed','2026-10-07T00:00:00Z'),
  ('size_gate.files.hotfix','30','the operator 2026-10-07: plan-time size gate file limit for hotfix tickets; size_gate.files.hotfix.<project> overrides per project','seed','2026-10-07T00:00:00Z');

