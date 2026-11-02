# BH-8736: the Tackler reads stuck tickets from the ticket ledger (lifecycle 6/6)

Doc: PR_UNBLOCK_AGENT_PLAN

Before this change the Tackler (`bin/unblock.sh`) collected stalls only from open
PRs, boxes and pools. A ticket with no open PR made no stall record, so the
Tackler missed every 2026-10-28 case.

## What changed

- New collector family `lifecycle` (`bin/lib/unblock/collectors/lifecycle.sh`).
  It reads `GET /api/lifecycle/stuck` through `lifecycle_stuck` (#8731). It keeps
  the phases `ejected`, `abandoned` and `plan_blocked`, oldest `phase_at` first, at
  most `UNBLOCK_LIFECYCLE_ROWS_MAX` (50) per project per tick. It reads the
  ticket history (abandon count, PR) and, for an ejected ticket, the PR. A failed
  read is `null` plus a name in `unknown`, and a null never matches a rule.
  Records carry `subject_kind: "build"` and `subject: "<project>:<KEY>"`.
- Three rules in `catalog/unblock-rules.d/`:
  - `U14-REQUEUE` (ticket-ejected, PR open, not merged, head known): `requeue`,
    then the ticket moves `ejected -> in_queue`, actor `lifecycle`.
  - `U14-REBUILD` (ticket-abandoned, `abandons <= rebuild_max`): `rebuild` = move to
    `planned` (actor `lifecycle`), then `bin/launch-fastpath.sh`.
  - `U14-ASK` (ticket-plan-blocked with a stored question): `ask` = one critical
    card with the question text, no model call.
- `act.sh` gains the `rebuild` and `ask` actions and the `escalated` outcome
  (ask only). `requeue` takes an optional `ticket_key`.
- `bin/unblock.sh` records the ask card on the decision row (`UB_ACT_CARD`).
- `bin/unblock-reply.sh`: an answer `1` to a `U14-ASK` card moves the ticket to
  `planned` (actor `lifecycle`) BEFORE the answer is recorded. If the move fails,
  the answer is not recorded and the owner can send it again.
- `bin/stuck-work.sh`: the ticket facts read is retired behind
  `STUCK_WORK_TICKET_FACTS` (default 0). Set the row
  `lane.stuck-work.stuck_work_ticket_facts=1` to restore it.
  `bin/lib/stuck-work/facts-ticket.sh` stays on the tree for that rollback.

## Once per stuck episode

Every U14 rule keys on `project`, `ticket_key`, `episode` (= `phase_at`) and the
rule id. The ledger's UNIQUE `decision_key` is the dedup: a second tick over the
same stuck row answers 409 and acts on nothing. A new `phase_at` (a new
ejection, a new abandon) is a new episode and a new key.

## A second abandon

`U14-REBUILD` takes `abandons <= rebuild_max` (`UNBLOCK_LIFECYCLE_REBUILD_MAX`,
default 1). A second abandon matches no U14 rule and falls to the fallback
escalation (U12, or an unkeyed escalation when the record has no head). It never
rebuilds. `UNBLOCK_LIFECYCLE_REBUILD_MAX=0` escalates the first abandon.

## Knobs

| Knob | Default | Range | Read in |
|---|---|---|---|
| `UNBLOCK_LIFECYCLE_ROWS_MAX` | 50 | 1-200 | collectors/lifecycle.sh |
| `UNBLOCK_LIFECYCLE_REBUILD_MAX` | 1 | 0-5 | collectors/lifecycle.sh |
| `UNBLOCK_ASK_QUESTION_MAX` | 2000 | 1-2000 | bin/lib/unblock/act.sh |
| `STUCK_WORK_TICKET_FACTS` | 0 | 0-1 | bin/stuck-work.sh |

No schema change. U14-REBUILD uses the class `triage-launch`, as U13-STARVE does.

## Dependency on #8731

`bin/lib/jobs/lifecycle.sh` (#8731) is on main. `bin/unblock.sh` and
`bin/unblock-reply.sh` source it when it is readable. Every caller still checks
`declare -F` and fails closed when it is absent: the collector is counted FAILED,
`rebuild` and `ask` answer `failed lifecycle-libs-not-loaded`, a `U14-ASK` answer 1
is not recorded. The contract:
`lifecycle_stuck <project>` prints `{rows: [...]}`;
`lifecycle_transition <project> <key> <to_phase> <actor> <reason> [pr]` prints the
route's body; the rc is 0 (2xx), 9 (409 with `.current`), 2 (404) or 1 (other).
The history route answers `{events: [{id, to_phase, pr, ...}]}`, newest first.

## The PR read (rebuild r2)

The first build (#8762) read the PR with `pull=$(gh_rest ...)`. A command
substitution loses `GH_REST_STATUS`, and `tests/gh-rest-no-subshell-lint.sh`
refuses it. The collector now writes the body to a temp dir
(`$TMPDIR/ucl.XXXXXX`, one per call, removed before it returns), and a failed
read logs its `GH_REST_STATUS` and `GH_REST_REASON` on stderr.

## Assumptions (from the plan)

- U4's label exclusion: read as "ejected PRs no longer depend on U4".
  `U14-REQUEUE` owns an ejected ticket's PR whatever its labels. The U4 filter
  in `collectors/queue.sh` stays.
- Option 1 on the ask card means "I answered on the issue thread, plan it
  again". The answer path stops at `planned`; the relaunch is #8734's.
- A ticket key may carry a `.<n>` suffix (as `launch_fastpath` allows).

Test: `tests/unblock-lifecycle.bh-8736-test.sh`.
