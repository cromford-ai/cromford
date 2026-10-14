# Approved external PRs reach the merge queue (BH-4580, BH-4572.1)

Doc: MERGE-CONDUCTOR, MERGIFY

## Why

project-4 had 19 PRs from its engineer, each APPROVED by `bin/review-prs.sh` on
its current head and `mergeable_state=clean`, none merged. review-prs hands a
Mergify-repo APPROVE to the merge conductor (`mc_queue_conductor_only`), but
the conductor lists only `HARNESS_PR_AUTHORS` PRs (`harness_pr_list`,
`mc_is_harness_pr`). Nothing consumed the hand-off.

## What changed

- `bin/lib/mc/external-enqueue.sh` (new): `xe_project <project> <slug>
  <provider> <pbase>`. The conductor calls it right after `ae_project`. It makes
  ONE REST read, `pulls?state=open&per_page=100`, and keeps the rows whose author
  is NOT `harness_pr_author_match`. Each row goes through `_ae_offer` with
  `AE_EXTERNAL=1`. A 75 on the list read skips the tick with a log line and is
  never read as "no PRs". A page of 100 is logged as first-page-only.
- `bin/lib/autoenqueue.sh`: `ae_project` is split into `_ae_init`, `_ae_offer`
  and the loop. Harness rows behave as before. With `AE_EXTERNAL=1`, `_ae_gates`
  skips GR (the conductor's READY mark, which an external PR never gets) and
  runs IL instead, after G5: `mc_iron_law_scan` on the head's diff. An unread
  diff, or no scanner on the box, refuses. G1-G8 are unchanged. `AE_POSTED` and
  `AE_DEFERRED` are shared, so harness and external rows share one
  `MC_AUTOENQUEUE_CAP` per tick, and the overflow is DEFERRED.
- `bin/review-prs.sh`: `tg_holds` (BH-4579) is asked before `merge_step` on the
  fresh verdict and in `merge_retry`. A tier-2 APPROVE merges unless
  `tier_gate_mode[.<project>]=human`, or the row cannot be read. A held retry is
  not counted as an attempt. Header, reviewer prompt ("2 = higher-risk class
  (reported, not gated)") and the beat line ("handed to the merge queue" on a
  Mergify repo, otherwise "left for the merge step") now say what happens.

## What it does not do

- No tier is read on the external path.
- An iron-law hit on an external PR stays unenqueued, with one log line per
  head. There is no adjudication marker for a PR with no build record.
- On a non-Mergify repo with `flags/conductor-owns-merges` on, nothing lands an
  external PR. The review-prs comment says so.

## Check it

`HARNESS_TEST_SANDBOX=1 bash tests/mc/external-pr-enqueue.bh-4572-test.sh`.
On the hub: `grep 'AUTOENQUEUE' logs/merge-conductor.log | grep 'external PR'`.
