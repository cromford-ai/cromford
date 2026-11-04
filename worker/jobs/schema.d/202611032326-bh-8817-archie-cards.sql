-- BH-8817 (C0): Tackler cards go to Archie first. Four settings rows, no table.
-- One writer per row: this fragment. The readers: bin/lib/unblock/card.sh
-- (unblock_card_route, unblock_card_sweep) and bin/lib/budget-stop.sh (the
-- agent-call stage-day cap of stage archie-card).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('unblock.route_to','archie','archie | operator. archie: an act-mode Tackler card goes to bin/archie-cards.sh first, with no DM; operator restores the direct critical DM at once. Unreadable or any other word = operator (the code fallback).','seed','2026-11-01T03:30:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('unblock.archie_answer_max_min','60','Minutes an archie-routed card may stay open before Tackler pages the operator (5..1440; else the fallback 60).','seed','2026-11-01T03:30:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('unblock.archie_claim_lease_min','15','Minutes Archie holds a claimed card before the timeout sweep may take it (1..240; else the fallback 15).','seed','2026-11-01T03:30:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('budget.stage.archie-card.day_usd','10','BH-8817: the BH-4489 per project per UTC day USD cap of the archie-card stage (Archie card triage). Assumed: no measured rows for a new stage.','seed','2026-11-01T03:30:00Z');
