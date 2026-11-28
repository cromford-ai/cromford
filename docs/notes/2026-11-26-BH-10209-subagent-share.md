# BH-10209 slice C0: the subagent share of execute spend

Doc: COST, DORA

Slice C0 of BH-10209 (session economics, part 1). It makes the subagent part of a claude cost row measurable and reports it in the DORA digest.

## Why

CLI 2.1.331 writes a subagent transcript to `<project>/<session>/subagents/agent-<id>.jsonl`. `bin/transcript-cost.sh` did not read that directory. So every claude cost row left out the subagent spend, and no row could tell the subagent part apart.

## What changed

- `bin/transcript-cost.sh` sums `<session>/subagents/*.jsonl`. The knob `COST_TRANSCRIPT_SUBAGENT_DIR` (settings row `lib.transcript-cost.cost_transcript_subagent_dir`, default 1) turns it off with 0. `--no-subagents` also drops it.
- An entry is subagent spend when it comes from any file but the primary one, or carries `isSidechain:true`. `--peak` and the model column read the main session only.
- New flag `--subagent-usd` appends one last field: the priced dollars of the subagent entries. `--format json` adds `subagent_usd` and `subagent_files`.
- `bin/agent-call.sh` `cost_row_source` passes `--subagent-usd`. A transcript-priced row puts `sub_usd:<x>` first in its note (`cost_sub_usd_token` in `bin/lib/cost-row.sh`). Envelope, grok and codex rows carry no token: "not measured".
- `bin/dora-digest.py` adds `fleet.subagent_share` to `state/dora/<date>.json` and one message line (`bin/dora_subagent.py`). Knobs: `DORA_SUBAGENT_SHARE_DAYS` (7) and `DORA_SUBAGENT_STAGES` (`execute`, joined with `+`). Seed rows: `worker/jobs/schema.d/202611271242-bh-10209-subagent-share-knobs.sql`.

## Effect on cost rows

A claude row's `cost_usd` rises by the subagent part that was missing. A cost cap set against the old undercount trips earlier by that share. `COST_TRANSCRIPT_SUBAGENT_DIR=0` restores the old sum on a box.

## Not in this slice

The `model_routes` role for execute subagents (C1, after 7 days of measured rows), the waste lane (C2), the digest equation terms (C3) and the effort test (C4).
