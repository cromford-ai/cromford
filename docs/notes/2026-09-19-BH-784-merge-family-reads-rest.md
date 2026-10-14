# 2026-09-19 — BH-784: the merge family's decision reads go through REST, and a limited read decides nothing

Doc: MERGE-CONDUCTOR

## What changed

Every read the merge family makes a DECISION on now goes through
`bin/lib/gh-rest.sh` (the BH-780 contract) instead of `gh pr view` / `gh pr diff`
/ `gh issue view`, which speak GraphQL. The contract keeps three answers apart:

| rc | means | what the caller does |
|---|---|---|
| 0 | the API answered 2xx | act on the body. An empty list (`[]`) is a real "none" |
| 44 | HTTP 404 | ABSENT — act on it, but only where the repo is known to be visible |
| 75 | 403/429, any other non-2xx, network, a malformed slug, or an EMPTY body on a 2xx GET | UNVERIFIABLE — skip this tick, log it, leave state exactly as it is |

The five product files that changed: `bin/lib/merge-conductor-lib.sh`,
`bin/merge-conductor.sh`, `bin/merge-queue.sh`, `bin/merge-sweep.sh`,
`bin/tier2-merge-sweep.sh`, plus the vendored contract `bin/lib/gh-rest.sh`.
Each carries a `# gh-rest: no-graphql` marker, which is what the guard test
scans for.

## Why

#768, on 2026-09-18 between 02:49 and 03:05Z. `gh pr view` was rate limited and
answered EMPTY, with a non-zero exit code nobody checked. Every decision path in
the merge family read that silence as a fact about the PR — "no such PR", "not
open", "no label" — and acted on it: five real PRs were rewritten
RESULT_UNVERIFIED and TK-2302 was launched three times.

The two worst shapes, both reproduced in
`tests/merge-family-limited-read-repro.bh-784-test.sh`:

- `bin/merge-queue.sh` read an empty state, took `"" != OPEN` as an answer,
  deleted the queue row and wrote `dequeued: PR state=` into the ledger. A rate
  limit turned into a permanent claim about approved work.
- `bin/merge-sweep.sh` wrote the PR into `state/merge-sweep-done.txt` at the top
  of its merged branch, thirty lines before the issue close-out. A close that
  403'd left the record permanently done with the issue still open — and
  `sweep_seen` reads that file for ever, so nothing in the fleet would look at
  it again.

## The rule at each lane

- **`bin/merge-conductor.sh`** — a failed read leaves the `pr-state.tsv` row
  byte-identical and logs `row left as-is`. `ticket_open` answers rc 1 and logs
  `ticket_open UNKNOWN` on a 75, `ticket_open ABSENT (HTTP 404)` on a 44, so the
  close-out is skipped rather than guessed and never skipped in silence. A diff
  the iron-law scan could not read is `diff UNVERIFIABLE` and no merge.
- **`bin/merge-queue.sh`** — 75 logs `read UNVERIFIABLE … left queued this tick`
  and moves on. 44 counts up in `state/merge-queue/<project>/<n>.absent` and
  logs `ABSENT (HTTP 404) — left queued this tick (n consecutive)`. Neither
  dequeues. The head-bound gate holds a row whose head it cannot read (that read
  is the only thing standing in front of code no reviewer saw, and neither merge
  verb carries `--match-head-commit`) — except under `HEADBOUND_ENFORCE=0`,
  which stays warn-only by definition.
- **`bin/merge-sweep.sh`** — a failed PR read records nothing and says so
  (`ABSENT (HTTP 404)` or `read UNVERIFIABLE (HTTP nnn)`). A failed diff read is
  not scanned and not merged. The done-marker moved to the END of the merged
  branch and is written only when the issue close verified.
- **`mc_queue_state`** — the Mergify check-runs read is on the contract too, and
  it only runs for a `mergify` provider. A 403 there used to come back as the
  empty string, which reads as "Mergify has no check on this head" — the exact
  sentence that becomes `ejected`, a strike, a label strip and a dequeue. Now a
  check read that did not answer says `unknown` and the row stays where it is; a
  check read that ANSWERED with no queue check is still an ejection, and a queue
  label read from a 200 is still a fact. On `github` and `none` providers the
  witness does not run at all: `isInMergeQueue` is GraphQL-only, so there is
  nothing there to find.
- **`bin/tier2-merge-sweep.sh`** — a failed read enqueues nothing.

## Close-out order, everywhere

Comment → close → re-read → marker. `mc_close_shipped` in the conductor lib is
the one implementation both merge lanes call. It returns 0 only after a fresh
GET says the issue is `closed`, so `closed issue #n` is never written off a
PATCH that 403'd. It then delegates the `ai-build` strip to
`issue_close_shipped` (`bin/lib/issue-state-lib.sh`) with an EMPTY body, so the
BH-637 §3b rule — the split-child exemption, the switch, the label read — stays
in one place for all four close paths.

## The three state files

| file | written | removed |
|---|---|---|
| `<record>/issue-commented` | after a 201 on the close-out comment | never — it is what makes a retry silent on the thread |
| `<record>/issue-close-owed` | before the first close attempt, and when the merge verb returned 0 and the verifying read did not answer — in both cases ONLY for an issue-driven project | after `gh_rest_close` answers 0, or when a later pass finds the record belongs to a board project after all |
| `state/merge-queue/<project>/<n>.absent` | on each consecutive 404 for that row | on any rc-0 read, and with the row itself |
| `<record>/issue-close-alerted` | when a record owes a close whose issue cannot be named, so the ALERTS line is written once per record rather than once per pass | never |

The conductor (`*/5`) and the sweep (`*/10`) both close issues for the same
merge and share the build record, so whichever comments first, the other stays
silent.

**A board project owes no issue close.** `sweep_issue_for` answers three things,
not two: 0 with the repo and the number, 2 for "nothing is owed here" (the
project's `board_prefix` is not `-`, so its ticket lives on the product board
and is closed through the app's API), and 1 for "a close is owed and the project
or the number cannot be derived". Only 0 and 1 mark a record owed. Collapsing 2
into 1 would strand the merges of most of the fleet — project-1, project-2, project-3
and project-4 are all board-driven — behind a retry that can never succeed: never
recorded, no beat, no ledger row, no deploy request, and a log line every ten
minutes sending someone after an issue that does not exist. The rc-1 case is
still never recorded (recording it would retire the debt by forgetting it), but
it now pages once in `logs/ALERTS.log` instead of only talking to this sweep's
own log.

## The gap this leaves, on purpose

When `gh pr merge` returns 0 and the verifying read is 403, the sweep records
NOTHING, marks `issue-close-owed` if the project is issue-driven, and re-reads
next pass. On that later pass it
runs the close-out retry only — **the deploy request and the ship beat are not
re-issued for that merge**. One log line names it; deploy-train's 20-minute
self-source floor is what covers the deploy, the same net the conductor leans on
when GitHub publishes no merge commit sha.

## Knobs

`MQ_ABSENT_ALERT_AFTER` (env, default 3) — how many consecutive 404s on one
queue row before this box writes ONE `logs/ALERTS.log` line naming the project,
the PR and the row path. It never dequeues on any count. No other env var is
introduced by this change.

## Verbs deliberately left alone

Four `gh` write verbs carry `# gh-guard-allow` with a reason: the three
`gh pr merge` call sites (the queue's train and serial landings, the sweep's),
the conductor lib's own merge verb, and the three `gh run rerun` CI writes.
They are writes, not decision reads, and the merge verbs are gated elsewhere.
`mc_hotfix_proof`'s comment read is tagged and left for #854. Log lines that
merely quote `gh pr edit` / `gh pr merge` in prose are tagged as prose.

## Still owned elsewhere

- `bin/lib/issue-state-lib.sh` — still GraphQL under the hood; BH-781 owns it.
  Its failure under a cap is reported as `strip-deferred`, and the issue is
  verifiably closed either way.
- `bin/lib/gh-pr-list.sh` — still does the bulk GraphQL list with
  `isInMergeQueue`. That field has no REST equivalent, which is why
  `mc_queue_state` answers `unknown` for a `github`-provider PR that reads OPEN
  rather than guessing "ejected". The native-queue ejection witness stays that
  list's job.
- `bin/blocked-resolver.sh` (BH-783), `bin/run-build.sh` and `bin/fly-pool.sh`
  (BH-781), the launch gates (BH-782), `mc_hotfix_proof` (#854), and the guard
  test plus `docs/verification-map/gh-rest.md` (#780).

## How to drive it

```
HARNESS_TEST_SANDBOX=1 bash tests/merge-family-limited-read-repro.bh-784-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/conductor-limited-read.bh-784-test.sh
LIMITED_READ_MUTATE=1 HARNESS_TEST_SANDBOX=1 bash tests/conductor-limited-read.bh-784-test.sh   # must FAIL
```
