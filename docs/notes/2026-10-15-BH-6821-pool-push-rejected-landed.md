# A pool "push rejected" is compared with the remote before it is terminal (BH-6821)

Doc: FLY-POOL-RESPAWN-CAP

## The gap

BH-5566 was fully built by the pool. Its head `f56eba45f` was already on
GitHub, and only the PR step did not run. The machine answered
`BUILD_DEFERRED push of ticket/bh-5566 rejected`. The reap
(`bin/fly-pool.sh`, BH-1075) treats every such line as terminal: it wrote
`state/pool/<p>/<KEY>.terminal`, opened no PR and closed the row `failed`.
fly-dispatch then claimed the key again from the coordination DB, and the row
stayed `claimed` for 3.5 h with nothing building it.

## What changed

- `bin/lib/rb/pr.sh` (`# >>> pr push`): the rejected line names the head the
  build made: `BUILD_DEFERRED push of <branch> rejected at <40-hex sha>`.
- `bin/lib/pool-push-rejected.sh`, sourced by `bin/fly-pool.sh`. On a
  push-rejected line the reap reads the remote branch head and one REST compare
  of `<built>...<branch>`. The built head is the sha in the line, else the
  relayed `reviewed-sha` (an older image). With neither, nothing is read.
  - `identical` or `ahead`: the push landed. If the ticket HOLD reads clear,
    the hub opens the PR with `gh_pr_create_ladder` (the ladder `pr.sh` uses),
    with a body made of the plan's `## Why`, the relayed `evidence.md` and an
    `## Opened by the hub` section that names both shas. `RESULT` line 1 becomes
    `PR_CREATED <url> (opened by the hub …)`, the old line stays as line 2, and
    the reap's PR_CREATED gate verifies the PR and closes the row `done`. No
    terminal is written.
  - `behind`, `diverged`, or a 404 (GitHub does not know the built sha): the
    first time, ONE build is requeued with `continue_branch:<branch>` in the
    queue file and the row meta, and `state/pool/<p>/<KEY>.push-diverged`
    records the strike. A second divergence inside `POOL_PUSH_DIVERGE_TTL_S` is
    the terminal, plus one ALERTS line that names both shas.
  - An unreadable ref or compare, a held or unreadable HOLD, or a PR create
    that failed on every rung: the terminal, as before.
- The terminal file carries `ticket_id` (`pool_terminal_write`, optional 5th
  argument). `ticket-meta.json` joins the reap's relay list (the PR title).
- `bin/lib/queue-row-job.sh` carries `continue_branch` into the job file and
  refuses (rc 3, row `failed`, one ALERTS line) a value outside
  `[A-Za-z0-9._/-]`. `fly/builder-runner.sh` passes it to `run-build.sh` as
  `TARGET_BRANCH` when no open PR's head was adopted, so the build starts from
  the remote head (continue mode).
- `bin/lib/pool-claim-guard.sh`, sourced by `bin/fly-dispatch.sh`: a key with
  `state/pool/<p>/<KEY>.terminal` is never claimed. The flag-off rows loop says
  `refused claim of <KEY>: push-rejected terminal (…)` and, on a pool project,
  writes the hub job file WITHOUT a claim, so fly-pool's terminal gate
  (BH-5006) re-arms it on a moved head or a RETRY. The rows-only pick skips the
  key. A refused `queue_claim` logs the row status (`row is failed`).
- `bin/lib/br-pool-terminals.sh`, called once per `bin/blocked-resolver.sh`
  run: one line per terminal, and ONE comment on the ticket's GitHub issue
  (issues-lane projects with a `ticket_id` only) that names the branch and the
  head. The `.terminal-noted` sentinel is the one `pool_terminal_noted` uses,
  so a ticket gets one comment whichever lane posts first. At most
  `BR_POOL_TERMINAL_MAX` (default 20) posts per run; observe mode posts
  nothing. The resolver's lane-run manifests carry `state/pool/$p/*.terminal`
  (ro) and `state/pool/$p/*.terminal-noted` (rw).

## Knobs

| Knob | Default | Effect |
|---|---|---|
| `POOL_PUSH_LANDED_OPEN` (fly-pool) | 1 | 0 = every push rejection is terminal, as before BH-6821 |
| `POOL_PUSH_DIVERGE_TTL_S` (fly-pool) | 604800 | a divergence strike older than this counts as a first one |
| `BR_POOL_TERMINAL_MAX` (env) | 20 | resolver comment posts per run |

## Check it on the hub

```
grep -E 'push-rejected [A-Z]+-[0-9]+: (landed|diverged)|terminal .*push rejected' /root/harness/logs/fly-pool.log
grep 'refused claim of' /root/harness/logs/fly-dispatch.log
grep 'push-rejected terminal on' /root/harness/logs/blocked-resolver.log
```

## Tests

`tests/pool-push-rejected-landed.bh-6821-test.sh`,
`tests/fly-dispatch-terminal-claim.bh-6821-test.sh`,
`tests/blocked-resolver-pool-terminals.bh-6821-test.sh`.
