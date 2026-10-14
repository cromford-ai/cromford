# BH-4660 (BH-4656 part 3): stuck-work reads CI and comment threads only on change

Doc: VERIFICATION-MAP

## Why

`bin/stuck-work.sh` runs every 5 minutes on the hub. Each pass re-read every
open PR's `commits/<sha>/status` and `commits/<sha>/check-runs`, every
`Blocked-by` issue, and every ai-build ticket's whole comment thread: about
1,750 calls an hour on the shared App bucket, almost all of them answering
what the last pass already knew.

## What changed

- **`bin/lib/stuck-work/facts-pr.sh`.** `swf_pr_facts` loads
  `bin/lib/pr-snapshot.sh` on first use and takes the open list from
  `prs_open_list`, falling back to `gh_rest_pr_list_all` when the lib is not
  there. Fields 6, 7 and 12 (lead status, its time, the Mergify phase) are
  cached per PR at `state/stuck-work/ci/<owner_repo>-<n>`, one line
  `<head>\t<updated_at>\t<epoch>\t<lead_status>\t<lead_status_at>\t<mergify>`.
  Both reads are skipped only when head and `updated_at` equal the line's,
  `prs_wake_seen <repo> checks <head>` and `prs_wake_seen <repo> pr <n>` are
  both not rc 0, and the line is younger than `STUCK_WORK_CI_TTL_S`. A read
  that answered `?` is never cached, and neither is a list row with no
  `updated_at`.
- **`bin/lib/stuck-work/facts-ticket.sh`.** A blocker that is itself in the
  open ai-build list this pass read is `open` with no `issues/<b>` read. The
  thread is cached at `state/stuck-work/thread/<owner_repo>-<n>.json` (sorted by
  `created_at`, then `id`) and `.meta` (`<max updated_at>\t<full-read
  epoch>\t<last-read epoch>`; the ticket named two fields, and the third is
  what the wake check needs once a `since=` read has happened). A full read
  happens with no cache or once the last full read is `STUCK_WORK_THREAD_FULL_S`
  old. Otherwise `prs_wake_seen <repo> issue <n> <last read>` at rc 1 reads
  nothing, and rc 0, rc 2 or no `prs_wake_seen` reads
  `comments?since=<max updated_at>` and merges by `id`, the newer `updated_at`
  winning. A failed read is `issue_hold=?`, never the cached answer.
- **Knobs** (`catalog/lanes.d/stuck-work.json`): `STUCK_WORK_CI_TTL_S`
  (0..3600, 900, 0 always reads) and `STUCK_WORK_THREAD_FULL_S` (0..86400,
  1800, 0 always reads in full), settings keys `lane.stuck-work.<env lowercased>`.
- The cache root is `${HARNESS:-${H:-}}`. Under `HARNESS_TEST_SANDBOX=1` only an
  explicit `HARNESS` counts, so a suite never writes into a live tree.

## Known limits

- A deleted comment stays in the cached thread until the next full read, so a
  deleted HOLD can keep `issue_hold=1` (and a deleted RESUME keep it at 0) for
  up to `STUCK_WORK_THREAD_FULL_S`, 30 minutes by default.
- With no wake feed (`prs_wake_seen` rc 2), a Mergify run that moves without
  changing the PR's `updated_at` is seen at most `STUCK_WORK_CI_TTL_S` late.
- `ci/` files of merged PRs are not removed. One small file per PR; losing the
  directory costs reads, never correctness.

## Checking it

`tests/stuck-work-reads.bh-4656-test.sh`. On the hub after deploy,
`bin/gh-ledger-report.sh --last 1h` should show the `stuck-work.sh` rows for
`commits/SHA/status`, `commits/SHA/check-runs`, `issues/N` and
`issues/N/comments` falling.
