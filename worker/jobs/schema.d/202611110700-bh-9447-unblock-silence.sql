-- BH-9447: the silence default. Five settings rows, no table. One writer per
-- row: this fragment. The reader of every row: bin/lib/unblock/silence.sh
-- (unblock_silence_promise, unblock_silence_sweep), called from
-- bin/lib/unblock/card.sh. The columns are core.d/bh-9447-unblock-silence.js.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('unblock.silence_auto.cromford','on','on | off. on: a Tackler card of this project whose recommended option is a lever in unblock.silence_safe_levers runs it after unblock.silence_auto_after_min minutes with no answer. No row, or any other word = off (the code fallback). Only cromford is seeded (the operator, 2026-11-10).','seed','2026-11-11T07:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('unblock.silence_safe_levers','lead_rerequest,update_branch,fix_round,rebuild,requeue','Comma list of the act.sh levers that may run on silence. The reader drops every never-auto class or action of act.sh gate 1 (one warn alert) and every name act.sh does not know. No row = this same list (the code fallback).','seed','2026-11-11T07:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('unblock.silence_auto_after_min','120','Minutes a card stays unanswered before its safe recommended lever runs (5..4320; else the fallback 120).','seed','2026-11-11T07:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('unblock.silence_auto_day_cap','10','Most silence runs per project per UTC day; the worker refuses the claim over it (1..1000; else the fallback 10).','seed','2026-11-11T07:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('unblock.silence_rereview_priority','5','The lead review priority of a lead_rerequest that runs on silence (1..9; else the fallback 5, the same as ARCHIE_CARDS_REREVIEW_PRIORITY).','seed','2026-11-11T07:00:00Z');
