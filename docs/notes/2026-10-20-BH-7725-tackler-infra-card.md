# Tackler infra rules U8-U10 and the escalation card U12, in shadow (BH-7725)

Doc: HARNESS-COORDINATION, ALERTS-STATE-MACHINE

## What changed

- New collector `bin/lib/unblock/collectors/infra.sh`. It prints one JSONL
  stall record per hung Orgo box (`box-hung`), starved pool (`pool-starved`),
  respawn loop (`respawn-loop`) and conductor branch park (`branch-park`).
  0 model calls, 0 writes. All input goes through one seam,
  `unblock_infra_src`. An unreadable source is a `source-unreadable` record,
  never "nothing stalled".
- New rule files in `catalog/unblock-rules.d/`: U8 (box restart), U9
  (throughput knob), U10 (branch fix round), U12 (escalation card, the
  fallback). A predicate that reads null does not match: unknown is not false.
- New card library `bin/lib/unblock/card.sh`. It composes the U12 card (at
  most 900 chars, every field scrubbed), makes the bounded `stage.unblock`
  model call (claim before spend, at most 2 attempts), sends the card through
  `bin/lane-alert.sh --critical` only in act mode with `UNBLOCK_ACT=1`, and
  re-declares an open card once a day under the same alert id until it
  expires.
- New prompt `catalog/prompts/unblock-decide.md` and LLM site
  `catalog/llm-sites.d/7725-unblock.json`.
- New script `bin/unblock-reply.sh`. `bin/orchestrate.sh` runs it in a new
  block, `# >>> tackler reply intercept`, after the box request block and
  before the turn claim. `Tackler u-<6 hex> <n>` or `Tackler u-<6 hex> hold
  [note]` from an owner (`BOX_CHAT_OWNERS`) records the answer once per
  command id. Anything else runs the normal turn.
- New settings rows (schema fragment `202610201530-bh-7725-unblock-infra.sql`):
  `unblock.knob_allowlist` (the operator's five entries, 6294290004 item 3),
  `lane.unblock.unblock_box_hung_min` = 30,
  `lane.unblock.unblock_respawn_max_day` = 6.

## Why

Ticket #7725 is slice S3 of the PR Unblock Agent plan (PR #7721). It builds
against main without #7709, #7710, #7712 or #7722.

## What is not live yet

- No caller runs the collector or sends a card: `bin/unblock.sh` (UNB-0,
  #7722) and act mode (UNB-4, #7726) are not on main.
- The box_health and pool_status routes (#7710, #7709) and the decision ledger
  routes (#7722) do not exist yet. Until they do, the collector prints
  `source-unreadable` records for them, and a card answer replies "the
  decision ledger did not answer" and records nothing.
- `stage.unblock` has no model route row. Without one, `unblock_card_decide`
  makes no call and uses the deterministic fallback card.
