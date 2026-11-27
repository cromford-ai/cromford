# BH-9994: the review lane publishes the verdict status on the head it reviewed

## The defect

On 2026-11-24 the Mergify queue on example-org/project-2 needed
`check-success~=^(lead-verdict|harness-verdict)$`. The review lane
(`bin/review-prs.sh`) approved #868 and #878 (peer harness) and #891 (human)
on their heads. No verdict status was written on those heads, so the three
PRs waited for hours. The queue was then reverted on that repo (PR #895).

Before this change only two writers published the status:

- `mc_enqueue_mergify` (`bin/lib/mc/queue.sh`), on harness-built PRs only.
- `bin/lead-verdict.sh post`, on a lead or human verdict row.

The conductor's external path (`xe_project`, `bin/lib/mc/external-enqueue.sh`)
sent `@mergifyio queue` for such a PR with no status and no alert.

## Who publishes what now

| PR | writer | when |
|---|---|---|
| harness-authored (`harness_pr_author_match`) | `mc_enqueue_mergify` | after the conductor's head-bound gates |
| lead or human verdict | `bin/lead-verdict.sh post` | on the verdict row |
| any other PR (peer, human) | `rvs_publish` (`bin/lib/review-verdict-status.sh`) | after the review lane's verdict, and on each later tick until it lands |

The author test keeps the first and the last writer apart: they never write
the same PR.

## Decision table (`rvs_publish <num> <sha> <verdict> <author> <served>`)

| case | result |
|---|---|
| advisory (trivial route) APPROVE, or a verdict that is not APPROVE / REQUEST_CHANGES | nothing |
| harness author | nothing |
| the row's `vs_sha` is this head already | nothing (one write per head) |
| `mc_queue_conductor_only` rc 1 (no Mergify queue) | nothing, no record (backfilled when a queue comes back) |
| APPROVE, served by a fallback lane | no POST, `vs_state=withheld-provenance` |
| APPROVE, `la_decide` rc 1 | no POST, `vs_state=withheld-authority` |
| APPROVE, `la_decide` rc 2 | no POST, no record (asked again next tick) |
| APPROVE, `lead_required` row is 1 and no lead MERGE stands | no POST, `vs_state=withheld-lead-required` |
| APPROVE, otherwise | `success` on `lr_clear_context` (`lead-verdict` when a lead or human MERGE stands, else `harness-verdict`) |
| REQUEST_CHANGES, a lead or human MERGE stands on the head | nothing (the lead outranks the lane) |
| REQUEST_CHANGES, otherwise | `failure` on `harness-verdict` |
| the POST fails (403, no App token) | one `verdict status NOT published` log line, no record; `merge_retry` tries again next tick |

On a POST that GitHub answered 2xx the state row
(`state/<project>.pr-reviews.json`) gets `vs_sha`, `vs_state` and `vs_ctx`, and
the log gets `verdict status <state> <ctx> published on <sha12>`. A new head
gets a new verdict row, which drops the old head's keys.

The two call sites in `bin/review-prs.sh`:

1. After the verdict state write and before the D1 verdict row. The conductor's
   G3 reads that row, so the status is on GitHub before the conductor can see
   the APPROVE.
2. In `merge_retry`, for an APPROVE on record on the current head, before the
   merge holds. This publishes on PRs approved before this change, and it
   retries a failed publish.

## The conductor alert

`xe_status_check` (`bin/lib/mc/external-enqueue.sh`) runs for an external row
that passed every autoenqueue gate. If the repo's `.mergify.yml` names
`harness-verdict` or `lead-verdict`, it reads the head's combined status. When
`vs_clear_row` does not say `success`, it calls `mc_status_unpublished_alert`
with the head as a 5th argument. The ledger mark is then
`status-unpublished <slug> <head>`: one alert per head, in the first tick that
sees it. A failed status read writes one conductor log line and no alert.
The 4-argument call from `mc_enqueue_mergify` keeps its per-repo, per-day mark.

## After merge (operator steps)

1. Confirm that the project-2 box serves the merge sha (`bin/fleet-propagate.sh`
   or the daily `update-runners.sh`).
2. Run `bin/mergify-sync.sh apply example-org/project-2`. It re-applies
   `config/mergify/repos/project-2.conf`, which is on main already.
3. Merge the PR that step 2 opens.
4. Check that #868, #878 and #891 show `harness-verdict=success` within one
   review-prs tick (30 minutes):
   `gh api repos/example-org/project-2/commits/<head>/status -q '.statuses[]|select(.context=="harness-verdict")|.state'`.

## Tests

- `tests/review-prs-verdict-status.bh-9994-test.sh` drives the real
  `bin/review-prs.sh` against a fake GitHub (R1-R13).
- `tests/mc/xe-status-missing.bh-9994-test.sh` drives the real `xe_project`
  (X1-X10).
