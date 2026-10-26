# BH-8418 (UNB-8): Tackler contract drift on main

Doc: MERGE-CONDUCTOR

## What changed

- **The schema describes the grammar the loader takes.** `catalog/unblock-rules.d/_schema.json`
  now allows `match.kind` as a kind, a non-empty list of kinds or `"*"`; dotted `key` paths
  (`proposal.key`); `action.name` or `action.verb` (exactly one); and the top-level keys
  `never_auto`, `after` and `delegate_in_act`. U8, U9, U10 and U12 did not validate before.
- **U8 and U9 send act.sh's argument names.** U8 `box_restart` sends `{box_id}` (it sent
  `{box}`). U9 `setting_set` sends `{key, value, old, min, max, why}` (it sent
  `{key, new, note}`). Before, act.sh refused both with rc 1 and the tick recorded
  `failed bad-input`. act.sh appends "roll back by setting <old>" to `why`, and U9's `why`
  already holds the collector's rollback note, so the setting note names the old value twice.
- **`uo_class_of` looks a rule up by its `.id`.** It read `<rule_id>.json`, so U8-U12
  (file `U8-box-restart.json`, id `U8`) had no class in the override demote and in the
  weekly report (`unclassified`). Two files with one id give rc 1 (fail closed).
- **The tick loads what it dispatches to.** `bin/unblock.sh` now loads
  `bin/lib/merge-conductor-lib.sh` (mc_attempt_has and mc_requeued_mark: before, the
  queue collector read `requeued_on_head` and `ejected_on_head` as null, so U1-U3 never
  matched), `bin/lib/fix-round-queue.sh` (act.sh's U10 arm), and the seam modules
  `rules judge card`. `judge.sh` is BH-7724 (#7753) and loads when it is on the tree.
- **`ubt_stage_card` exists.** The escalate seam was named in the tick and defined
  nowhere, so every escalate decision (29 on cromford) was deferred and never claimed.
  It is in `bin/lib/unblock/card.sh`: it refuses unless `UBT_CLAIMED_KEY` is the decision's
  key (the tick sets it after its claim), then runs the existing decide, compose and send.
  In shadow it spends one `stage.unblock` call per new escalation key and sends no alert.
  `unblock_card_decide` takes the tick's model as an optional 4th argument.
- **One suite pins it.** `tests/unblock-rules-contract.bh-8418-test.sh` runs every rule
  file through the schema, the loader and the tick with the real act.sh, and the U2/U3
  tick with the real conductor libs. Each rule needs a sample record in
  `tests/fixtures/unblock/bh-8418/records.json`. #7753's U5-U7 and U11 files need records
  there and act.sh-shaped args (U5 sends `findings`, post_block reads `lines`; U11's
  `clear_block` is not an act.sh action).

## Stale text, not edited here

`catalog/llm-sites.d/7725-unblock.json` says the card has no caller on main, and
`catalog/context-budgets.d/7722-unblock.json` marks the card seam PENDING. Both are now
out of date: `ubt_stage_card` is the caller.
