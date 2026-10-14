# A split child gets a replan check once its blockers merge (BH-3955)

Doc: RUN-BUILD-GRAPH, MODEL-ROUTES

## What changed

New `bin/replan-check.sh <project> <ticket> <key> <build-dir>`, called from
`bin/lib/rb/plan.sh` right after the rollout hook and before the plan.

It runs only for a split child: the title is `<KEY>.<n>: …` with n >= 1, the
body has a `Part of #<parent>` line outside code fences, it has at least one
`Blocked-by: #<n>`, and the build is not stacked (`STACK_ON` empty). Every
blocker must be merged: the issue is CLOSED and a PR on `ticket/<prefix>-<n>`
has `merged_at`. A read that fails counts as not merged. Anything else is
`skip <why>` in `$BUILD/replan-verdict`, one pipeline.log line, no model call
and no DECISION line.

For an eligible child it gathers, with byte caps (`REPLAN_DIFF_MAX` 12000 per
blocker, `REPLAN_DIFF_TOTAL` 30000, `REPLAN_FINDING_MAX` 3000,
`REPLAN_COMMENTS_MAX` 4000) and a `truncated: yes|no` header:

- each blocker PR's file patches;
- `review.md` and `preview-qa*.md` from this box's newest build record of the
  blocker, when it has one;
- parent comments created after the child issue was.

Then one call on the `replan` model route (a new seed in
`worker/jobs/schema.sql`, copied from `triage.light` rung 0) through
`bin/agent-call.sh replan`, billed to the `fly-pool` lane like every other
build call. The answer's last `REPLAN:` line decides:

| Answer | What happens |
|---|---|
| `REPLAN: keep` | the plan runs as today |
| `REPLAN: amend` + `AMEND-BEGIN`…`AMEND-END` | the amendment rides the plan prompt (`REPLAN_LINE`), a pre-plan is not adopted, and after the plan the amendment is posted on the child as the App (without an App token it is skipped, logged and marked `replan-comment-skipped`, never `replan-commented`) |
| `REPLAN: escalate :: <decision>` | `thc_run hold` puts the `hold` label on, one `fleet_alert` beat (`line` + `project`, the fields `bin/beat.sh` reads) names the decision, and the build ends `PLAN_BLOCKED` with `BLOCKED: REPLAN escalate :: <decision>` as plan.md line 1. If the hold fails there is no beat, one ALERTS line instead, and plan.md says the label was NOT applied |

No evidence, no route, a failed call or an answer off that contract is `keep`
with the reason, and the build continues. Every non-skip verdict is one
`DECISION: <KEY> :: replan-<verdict> :: <reason>` line through
`bin/decision-log.sh` (gate `replan`, scope `child`).

## Dedup

The D1 ledger row kind `replan`, key `<project> <KEY>`, holds `<verdict> <fp>`
(fp = sha256 of the child body, the blockers' merge SHAs and the parent comment
ids); an amend keeps its amendment in the row's detail so a later build reuses
it without a call and without a second comment. Only a cleanly parsed answer is
written, and an escalate only once its hold is on. A stored escalate whose
`hold` label is gone means a human answered it: that build records `keep` and
is not escalated again on the same evidence. New evidence buys a new call.

## Who owns each step of an escalation (D45)

| Human action | New owner | Test |
|---|---|---|
| decide the child needs a human | `bin/replan-check.sh` verdict | R2, E1-E4 |
| park the ticket | `thc_run hold` (the `hold` label) | R2, R2b |
| tell the operator what to decide | one `fleet_alert` beat, only after the hold | R2, R2b |
| stop this build | `PLAN_BLOCKED` from the plan.sh block | W2 |
| keep it parked on later ticks | the `hold` label every launcher reads | existing hold suites |
| un-park after answering | a human removes the label (unchanged), and the ledger keeps it from re-escalating | R2c |

## Census

The call is the `replan-check` site in `catalog/llm-sites.json` (stage
`replan`, lane `fly-pool`), and `worker/jobs/schema.sql` also seeds its
`stage.replan` runner route (one claude rung), the way every catalogued stage
has one.
