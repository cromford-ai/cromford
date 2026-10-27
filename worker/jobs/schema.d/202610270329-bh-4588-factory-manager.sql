-- ── BH-4588 (BH-4574.6): manager authority and the daily factory report ─────
-- Additive only: no table, no DROP, no UPDATE. INSERT OR IGNORE, so a re-apply
-- never resets a class an overrule moved back to ask_first or a knob an
-- operator changed. One statement per seed (bin/harness-sync.sh applies the
-- file statement by statement, BH-1000).
--
-- MANAGER AUTHORITY. One archie_classes row per guardrail lever, seeded
-- delegated: a decision on a lever class is mode auto (Archie acts and reports
-- after). One overrule puts the class back to ask_first, the BH-4067 rule. No
-- slug matches archie-autonomy.js PROTECTED_RE (worker test W-AUTH pins it).
-- The protected classes (merge, production, deploy, spend, client-board,
-- unclassified) keep their CHECK and stay never delegable: they now mean the
-- hard limits only (a direct merge, a push to main, a production DB write, a
-- deploy outside the deploy lanes, a spend-cap raise, a client-visible write).
INSERT OR IGNORE INTO archie_classes (class, never_delegable, state, streak, updated_at, note) VALUES
  ('lever-enqueue',0,'delegated',0,'2026-10-23T00:00:00Z','BH-4588: enqueue a PR into the merge queue on any fleet project, client repos included');
INSERT OR IGNORE INTO archie_classes (class, never_delegable, state, streak, updated_at, note) VALUES
  ('lever-dequeue',0,'delegated',0,'2026-10-23T00:00:00Z','BH-4588: dequeue a PR from the merge queue on any fleet project');
INSERT OR IGNORE INTO archie_classes (class, never_delegable, state, streak, updated_at, note) VALUES
  ('lever-fix-round',0,'delegated',0,'2026-10-23T00:00:00Z','BH-4588: start an agent fix round on a PR');
INSERT OR IGNORE INTO archie_classes (class, never_delegable, state, streak, updated_at, note) VALUES
  ('lever-rebuild',0,'delegated',0,'2026-10-23T00:00:00Z','BH-4588: rebuild a ticket fresh');
INSERT OR IGNORE INTO archie_classes (class, never_delegable, state, streak, updated_at, note) VALUES
  ('lever-rebase',0,'delegated',0,'2026-10-23T00:00:00Z','BH-4588: rebase a PR branch onto main and push it with lease (never to main)');
INSERT OR IGNORE INTO archie_classes (class, never_delegable, state, streak, updated_at, note) VALUES
  ('lever-re-review',0,'delegated',0,'2026-10-23T00:00:00Z','BH-4588: ask for a new review of a PR head');
INSERT OR IGNORE INTO archie_classes (class, never_delegable, state, streak, updated_at, note) VALUES
  ('lever-hold-label',0,'delegated',0,'2026-10-23T00:00:00Z','BH-4588: add or remove a hold label');
INSERT OR IGNORE INTO archie_classes (class, never_delegable, state, streak, updated_at, note) VALUES
  ('lever-pause-row',0,'delegated',0,'2026-10-23T00:00:00Z','BH-4588: write or clear a pause row through the jobs API');
INSERT OR IGNORE INTO archie_classes (class, never_delegable, state, streak, updated_at, note) VALUES
  ('lever-iron-law-ack',0,'delegated',0,'2026-10-23T00:00:00Z','BH-4588: record an iron-law acknowledgement');
INSERT OR IGNORE INTO archie_classes (class, never_delegable, state, streak, updated_at, note) VALUES
  ('lever-ticket',0,'delegated',0,'2026-10-23T00:00:00Z','BH-4588: file or comment on an ai-build ticket on the harness board');
INSERT OR IGNORE INTO archie_classes (class, never_delegable, state, streak, updated_at, note) VALUES
  ('lever-alert-ack',0,'delegated',0,'2026-10-23T00:00:00Z','BH-4588: ack or resolve an alert row');

-- THE REPORT AND THE STOP-THE-LINE BEAT. Read by bin/archie-fm-report.sh
-- (bin/lib/archie-fm-report/) and GET /api/archie/factory-report
-- (src/routes/archie-factory.js); each reader names its row at its code fallback.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.report.send_hour_utc','7','BH-4588: the UTC hour from which bin/archie-fm-report.sh sends yesterday''s factory report (0-23), once per day through archie-tg-send fm-report:<day>','seed','2026-10-23T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.report.stuck_max','20','BH-4588: stuck items listed by GET /api/archie/factory-report (1-200); the counts are never capped, and a longer list says truncated','seed','2026-10-23T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.report.actions_limit','300','BH-4588: archie_actions rows GET /api/archie/factory-report returns for one day (1-500); a larger ?limit= is a 400, and a longer day says truncated','seed','2026-10-23T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.stl.main_red_min','60','BH-4588: minutes a main-red-* alert stays open before Archie sends ONE stop-the-line beat for it','seed','2026-10-23T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.stl.queue_stall_min','60','BH-4588: minutes a mc-window-stall-* alert stays open before Archie sends ONE stop-the-line beat for it','seed','2026-10-23T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.stl.box_down_min','15','BH-4588: minutes a pool-box-* alert stays open before Archie sends ONE stop-the-line beat for it','seed','2026-10-23T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.stl.spend_spike_min','0','BH-4588: minutes a ph-costrate_*, ph-overcap_* or budget-stop_* alert stays open before Archie sends ONE stop-the-line beat for it','seed','2026-10-23T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.stl.beats_per_tick','3','BH-4588: stop-the-line beats bin/archie-fm-report.sh sends in one tick (1-50); the rest wait for the next tick, never dropped','seed','2026-10-23T00:00:00Z');

-- INDEX. The report's queue read: merge_queue_batches WHERE finished_at >= ?1
-- AND finished_at < ?2 GROUP BY outcome. Before this index that read scanned
-- the table. test/archie-factory.bh-4588.test.js W5 EXPLAINs it at volume.
CREATE INDEX IF NOT EXISTS idx_mq_batches_finished ON merge_queue_batches(finished_at);
