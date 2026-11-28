-- ── BH-10209 C0: the subagent share of execute spend, its knobs ─────────────
-- conf.dora-digest.dora_subagent_share_days: the trailing days of the DORA
-- digest's subagent_share block (bin/dora-digest.sh fallback 7, the ticket's
-- "last 7 days"). conf.dora-digest.dora_subagent_stages: the fleet-cost.csv
-- stages it counts, joined with + (fallback execute). bin/dora-digest.sh reads
-- both through conf_rows as DORA_SUBAGENT_SHARE_DAYS / DORA_SUBAGENT_STAGES.
-- lib.transcript-cost.cost_transcript_subagent_dir: 1 = bin/transcript-cost.sh
-- sums <session>/subagents/*.jsonl (CLI 2.1.331); 0 = main file only. The
-- registry default in catalog/lanes.d/_lib.transcript-cost.knobs.d/
-- COST_TRANSCRIPT_SUBAGENT_DIR.json is the same 1.
-- No table: settings rows only, so no index and no retention rule apply.
-- INSERT OR IGNORE: an operator's row survives a re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('conf.dora-digest.dora_subagent_share_days','7','BH-10209: trailing days of the DORA digest subagent_share block; a positive integer, fallback 7','seed','2026-11-26T10:06:00Z'),
  ('conf.dora-digest.dora_subagent_stages','execute','BH-10209: fleet-cost.csv stages the subagent_share block counts, joined with +; fallback execute','seed','2026-11-26T10:06:00Z'),
  ('lib.transcript-cost.cost_transcript_subagent_dir','1','BH-10209: 1 = sum <session>/subagents/*.jsonl into the claude cost row and its sub_usd note token; 0 = main file only','seed','2026-11-26T10:06:00Z');
