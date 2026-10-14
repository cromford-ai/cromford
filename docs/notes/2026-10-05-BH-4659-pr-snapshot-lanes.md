# BH-4659 (BH-4656.1): the conductor and batch-resolve read the PR snapshot; branch tips from one refs read

Doc: VERIFICATION-MAP, GH-REST

## Why

`merge-conductor.sh GET pulls/N` was about 1,550 calls an hour on the hub, its
`branches/ticket/bh-N` reads about 450, and batch-resolve's list about 470.
Most of those answered the same thing as the last tick. BH-4658 shipped the
shared snapshot. This slice moves those two lanes onto it.

## What changed

- `bin/lib/gh-pr-list.sh`: when `HPL_SNAPSHOT=1` and the snapshot is on
  (`_prs_on`), the open list comes from `prs_open_list` and each row's
  merge-state read from `prs_pr_get`. The mapping jq is one function both
  paths call. The page cap (`GH_PR_LIST_REST_PAGES` × 100) still applies.
  Without `HPL_SNAPSHOT`, or with `PR_SNAPSHOT=0`, the requests and the output
  are what they were.
- A stored body whose `mergeable_state` CI can still change (`blocked`,
  `unstable`, `has_hooks`) is never served: GitHub does not bump `updated_at`
  on a check run, so the key would not move when CI goes green and the
  conductor would read `BLOCKED` until something unrelated touched the PR.
  `_hpl_state_get` drops that row's key first and the read goes live. Contract
  gap, left for its own ticket because `bin/lib/pr-snapshot.sh` is off limits
  here: `prs_pr_get` still stores CI-dependent states. It should not, until the
  `pr` wakes sibling invalidates on `check_suite`/`status`.
- `bin/merge-conductor.sh` and `bin/batch-resolve.sh` source
  `bin/lib/pr-snapshot.sh` after `lane_env_apply` and export `HPL_SNAPSHOT=1`.
  The conductor also writes one `<owner/repo> PR-SNAPSHOT hit=<n> miss=<n>`
  line per project tick and calls `prs_gc`.
- `bin/lib/pr-snapshot-refs.sh` (new): `prs_branch_tip`, from one
  `GET git/matching-refs/heads/<prefix>/` per prefix an open PR uses, cached as
  `refs-<prefix>.json`. That is one GET, not `_gh_rest_list`, because the
  endpoint has no pages.
- `bin/lib/mc/rebase.sh`: `head_lag_tip` and `mc_branch_exists` ask it first.
  A tip that disagrees with the PR head is confirmed live, and "gone" is still
  only a live 404.

## Verify

- `HARNESS_TEST_SANDBOX=1 bash tests/pr-snapshot-lanes.bh-4656-test.sh`
- `HARNESS_TEST_SANDBOX=1 bash tests/mc-branch-refs.bh-4656-test.sh`
- On the hub, after deploy: `grep 'PR-SNAPSHOT' /root/harness/logs/merge-conductor.log | tail -3`
  and `ls /root/harness/state/pr-snapshot/example-org_cromford/refs-ticket.json`.
