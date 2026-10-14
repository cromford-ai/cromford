# The watchdog responder settles two known conditions without a model call

Doc: COST, watchdog-spec

## What was wrong

The responder costs about $2.5 a call. Two of the conditions it paid for have
a fixed answer that bash can already read off the evidence the prefetch
(BH-654) fetched:

- **evidence_missing.** The board could not be read for an item. The decide
  prompt forces `act` on a MISSING item, and the tooled pass is told to
  escalate it as "evidence unavailable". So one beat cost two calls.
- **not_owed.** The fetched ticket says `waitingOn=client` and no open PR
  matches the key. It has left the stale-owed set since the snapshot, and the
  only answer the model can give is `healthy / none`.

## What changed

- `bin/lib/responder-fix.sh` classifies each prefetched item from its
  evidence block (`rfix_classify`), maps the condition to a remedy through a
  settings row (`rfix_resolve`), and runs each (condition, project) group's
  remedy once under `timeout 60` (`rfix_pass`). A remedy that succeeds is
  journalled `<utc> P:K <condition> -> scripted:<remedy>` in
  `logs/responder.log`, and its keys are stamped in `state/responder/handled.json`
  (plus `brake:responder-handled` rows with `flags/alerts-db`).
- `bin/responder-fix/escalate-missing.sh` sends ONE strict `fleet_alert` beat
  per project, akey `responder:missing:<P>:<UTC hour>`, naming the items and
  why they could not be read. Its rc is beat's, so a beat that did not land
  sends the items to the model instead.
- `bin/watchdog-responder.sh` drops settled items from the item list, the
  evidence and the prompt. When nothing unknown is left, it logs
  `no model call this pass` and exits before the model-route lookup.

## The rows

Registered in `catalog/lanes.d/watchdog-responder.json` and exported by
`lane_env_apply`:

| settings key | default | values |
|---|---|---|
| `lane.watchdog-responder.responder_fix_evidence_missing` | `escalate-missing` | `model`, `none`, or a script name in `bin/responder-fix/` |
| `lane.watchdog-responder.responder_fix_not_owed` | `none` | same |

`model` puts a condition back on the old path. A junk value, or a name with no
script, is logged as `bad remedy row` and treated as `model`.

## What did not change

- Wedged queue jobs and every other class still go to the model.
- `RESPONDER_DRY=1` only journals `would run`. Its prompt is unchanged.
- `flags/responder-prefetch-off` has no evidence to classify, so it keeps the
  single tooled call.

## What is not measured yet

The saving depends on how many weekly passes are all-MISSING or all-not-owed.
Nobody has measured that on the hub yet. After deploy, check it with
`grep -E 'scripted:|no model call this pass' /root/harness/logs/responder.log`
and compare the lane's `triage/responder` cost rows over 7 days.

Tests: `tests/responder-fix.bh-2548-test.sh`.
