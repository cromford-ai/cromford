# BH-5006: close-out of scopes 1, 2 and 4, and the Acceptance 1 probe

Doc: MERGE-CONDUCTOR, OPERATING

#5199 shipped scope 3 of #5006 (the pool close-out custody sweep, see
`2026-10-07-BH-5006-pool-custody.md`). This note records the live state of
scopes 1, 2 and 4. It changes no code.

## What this PR does not close

This PR is slice C1 of #5006. It does not finish the ticket. Acceptance 1 is
not met, and it is not measured. #5006 stays open until a hub run records the
before and after counts with the steps in "HUB STEP" below.

## Where the 25 named PRs stand

The ticket says "Re-read live state before acting on each item ... skip anything
that has merged, been superseded, or has a fresh green head that's already
queued." The planning session read each PR at 2026-10-10 02:05-02:07Z. The
table gives that read. The build session (02:09Z) got HTTP 403 from the GitHub
API, so it could not re-read the CLOSED, queued and open rows. It did find a
`Merge pull request #N` commit on main (5e240b20) for each of the 14 MERGED
rows, and for #5237 and #5199.

| PR | Ticket scope | State at 2026-10-10 02:05Z | Owner or superseding PR |
|---|---|---|---|
| #4908 | 1 (requeue) | queued (`queued` label) | merge queue |
| #4887 | 1 (requeue) | MERGED | - |
| #4811 | 1 (requeue) | CLOSED | - |
| #4685 | 1 (requeue) | MERGED | - |
| #4614 | 1 (requeue) | open, CHANGES_REQUESTED | not lead-cleared, so out of scope 1; its own review loop |
| #4600 | 1 (requeue) | MERGED | - |
| #4108 | 1 (requeue) | MERGED | - |
| #4051 | 1 (requeue) | MERGED | - |
| #4029 | 1 (requeue) | MERGED | - |
| #4124 | 1 and 2 | MERGED | - |
| #4070 | 2 (rebase) | MERGED | - |
| #4702 | 2 (rebase) | MERGED | - |
| #4332 | 2 (rebase) | queued (`queued` label) | merge queue |
| #4675 | 2 (rebase) | MERGED | - |
| #4761 | 2 (rebase) | open, CHANGES_REQUESTED | its own review loop |
| #4895 | 2 (rebase) | open; main merged with no conflict at 37a7ea4e (operator, 01:03Z); APPROVE at 01:18Z | the operator's session and the conductor |
| #4803 | 2 (rebase) | open, conflicting at 7c0e6e76, standing bot BLOCK | conductor (parked 2026-10-09 14:00Z) |
| #4749 | 2 (rebase) | MERGED | - |
| #4747 | 2 (rebase) | MERGED | - |
| #4744 | 2 (rebase) | MERGED | - |
| #4701 | 2 (rebase) | CLOSED | - |
| #4649 | 2 (rebase) | MERGED | - |
| #4624 | 2 (rebase) | open, conflicting at ebf827c0, autopilot BLOCK | `bin/blocked-resolver.sh` (2026-10-09 04:24Z) |
| #4308 | 2 (rebase) | CLOSED | - |
| #4785 | 4 (BH-4084 docs) | CLOSED | #5237 (MERGED); issue #4084 is CLOSED |

Totals: 14 MERGED, 4 CLOSED, 2 queued, 5 open with a named owner.

This build did not requeue, rebase or close any PR. Each open PR has a live
owner, and a build session must not take a merge-path action
(rules/CLAUDE.md, iron guardrail 1). The automation that scope 2 asked for is
on main: #4108 (BH-3935, the stale-PR ladder), #4051 (the superseded-PR close)
and #4675 (the queue doctor).

## Scopes 3 and 4

- Scope 3 shipped in #5199, with `tests/pool-closeout-custody.bh-5006-test.sh`
  (Acceptance 2).
- Scope 4 shipped in #5237, the rebuild of #4785 per the #4084 comments.

## Acceptance 1: APPROVE+CLEAN+green PRs that are not queued

The probe is the `leadunqueued` section of `bin/pipeline-health.sh` (BH-3778,
BH-4055). It raises one ACTIVE key `leadunqueued:<repo>#<n>:<head12>` (or
`...:stale-review`) in `state/health-active.txt` for each open, non-draft PR
with a `lead-verdict` success older than `LEAD_MERGE_UNQUEUED_MIN` minutes and
no `queued` / `checking` label.

```bash
bin/pipeline-health.sh --sections leadunqueued
```

Its read for each candidate is:

```bash
gh api "repos/example-org/cromford/commits/<head-sha>/status"
```

The build box got HTTP 403 on that read. The planning session saw 403 for each
of the 31 open, non-draft PRs that are not queued. The build session saw 403 on
every GitHub API call. So this note records no count. The count is not
measured, and it is not 0.

## HUB STEP: measure Acceptance 1 on the hub

A bare line count of `state/health-active.txt` is not a measurement. The
section skips a repo that is not in `LEAD_REVIEW_AUTO_REPOS`, so a skip reads
as 0. On a failed read, `lu_carry` copies the standing keys forward, so a
carried key reads as a fresh one. `lu_carry` writes no log line. The only
carry cause that the log records is a low GitHub budget. Do these steps on the
hub, in `/root/harness`:

1. Confirm that `example-org/cromford` is in `LEAD_REVIEW_AUTO_REPOS` for
   the `lead-review-land` lane. This is the same read that the section makes:

   ```bash
   ( export HARNESS=/root/harness; cd "$HARNESS" && . bin/lib/lane-gate.sh && lane_env_apply lead-review-land >/dev/null 2>&1; printf '%s\n' "${LEAD_REVIEW_AUTO_REPOS:-}" )
   ```

   If the output does not contain `example-org/cromford`, record "skip"
   and stop. A count from that pass is not a count.
2. Write the start time to a variable: `T0=$(date +%s)`.
3. Run `bin/pipeline-health.sh --sections leadunqueued`. Record the exit code.
4. Read `state/health-active.stamp`. Its `at` field must be greater than or
   equal to `T0`. If it is not, the pass did not finish. Record "stale" and stop.

   ```bash
   jq -r --argjson t0 "$T0" 'if .at >= $t0 then "fresh n=\(.n)" else "stale" end' state/health-active.stamp
   ```

5. Look for a budget carry. If `logs/pipeline-health.log` has a
   "GitHub API budget low" line written after `T0`, the section carried every
   `leadunqueued:` key. Record "stale" and stop. The log writes this line
   once per budget fetch, so a missing line is not proof. Also read the budget:
   `gh api rate_limit --jq '.resources.core.remaining, .resources.graphql.remaining'`.
   If a value is below `( . bin/lib/gh-budget.sh && gh_budget_threshold )`, record "stale"
   and stop.
6. Make sure that the open-PR list read works:

   ```bash
   gh api 'repos/example-org/cromford/pulls?state=open&per_page=100' --jq 'length'
   ```

   If this read fails, the section carried the repo's keys. Record "stale" and
   stop. If more than 30 non-draft PRs without `queued` or `checking` are open,
   the section carried the PRs past the 30th. Record that the count is partial.
7. Count the keys:

   ```bash
   grep -c '^leadunqueued:example-org/cromford#' /root/harness/state/health-active.txt
   ```

8. No log line shows a per-PR carry. So for each key that step 7 counts, read
   its status by hand. Use the head in the key:
   `gh api repos/example-org/cromford/commits/<head-sha>/status`. A key whose
   read fails is a carry, not a measurement. Record it as "unread".
9. Do steps 1-8 before the merge and again one hour after the merge. Post both
   counts, the "unread" keys and the command outputs on #5006.
