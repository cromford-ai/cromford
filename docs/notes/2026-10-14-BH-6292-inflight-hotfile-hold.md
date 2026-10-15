# A plan that shares a hot file with any open ticket PR is held (BH-6292)

Doc: BUILD-CONCURRENCY

## Why #5465 did not hold the 2026-10-12 pairs

The plan-time defer had two sources. Neither one saw an unrelated ticket that
was in review or in the merge queue.

1. `bin/plan-overlap.sh` reads only builds that are running: live build dirs,
   claim files, queue `claimed` rows and `job_claims` rows. A ticket whose
   build finished and whose PR is open is in none of them.
2. `bin/plan-sibling.sh check` (BH-4988 r2, #5465) reads open PRs, but only the
   PRs of siblings. A ticket with no `Part of #P` line exits at once.

So two unrelated tickets that both edit one hot file built in parallel, and
their PRs conflicted at merge. That was the 13-PR conflict set of 2026-10-12
18:39Z.

## What changed

- `bin/plan-sibling.sh inflight <project> <build-dir>` is a new verb. The
  `# >>> plan overlap` block of `bin/lib/rb/gates.sh` calls it third, when
  `plan-overlap.sh` and `plan-sibling.sh check` both said build.
  - Candidate files: the list `check` uses, plus the edited paths of the
    plan's `## Shared files` section (`psib_shared_files`; a line that says
    "named only" is skipped).
  - Hot list: the first `PLAN_INFLIGHT_HOT_TOP` rows (default 10) of
    `$BUILD/.hotspots.txt`, which `rb_plan` writes. No new hotspot fetch.
  - No candidate file on the hot list: build, no GitHub read. A file that is
    not on the hot list never holds a ticket through this verb.
  - Else it reads the open PRs on `ticket/<prefix>-<n>[-rN]` or
    `agent/<PREFIX>-<n>`, oldest first, at most `PLAN_INFLIGHT_MAX_PRS`
    (default 40). It skips the ticket's own number and the stack base. File
    lists are cached at `state/plan-inflight/<project>/<pr>.<head_sha>`.
  - The first PR that changes a hot candidate file wins. The verb prints
    `OVERLAP_DEFER <KEY> vs <OTHER> files=[p,p]` and exits 1. OTHER keeps a
    `-rN` suffix, so `open_pr_for_key` finds that PR. The gates block then
    takes the existing After: path.
  - Every choice is one `PLAN_INFLIGHT <KEY> ...` line in pipeline.log and
    `logs/plan-hotspot.log`.
- `plan-sibling.sh note` also posts for a non-child when pipeline.log has
  `PLAN_INFLIGHT <KEY> choice=after`. The comment starts with
  `Blocked-by #<n>` with NO colon, so no dependency parser reads it as a hard
  `Blocked-by:` line. Dedupe is the existing `sequenced <project> <KEY>:<OTHER>`
  mark.
- The wait cap. `plan-after.sh check` prints `EXPIRED <OTHER>` (rc 0) when a
  hold reaches `PLAN_AFTER_MAX_MIN`. The `# >>> overlap not-before` block writes
  that key to `$BUILD/after-expired` and logs `AFTER_CAP`. `inflight` skips that
  key, so the ticket dispatches and no new 360-minute hold starts.
- A hotfix (`HOTFIX=1`) is never held. The plan overlap block runs no check and
  logs `PLAN_OVERLAP skipped hotfix`. The After: hold is skipped and logs
  `AFTER_HOLD skipped hotfix`. The pool's pre-spawn After: hold
  (`bin/fly-pool.sh`, arm 3b) also skips `plan-after.sh check` for a queue row
  with `hotfix:true`. It logs `<KEY> is a hotfix: After: hold not checked`, and
  the row spawns. Without this skip the machine never boots, so the gates.sh
  skip never runs.

## Knobs

`catalog/lanes.d/_lib.plan-sibling.knobs.d/`: `PLAN_INFLIGHT_HOT_TOP` (0 = off,
max 50) and `PLAN_INFLIGHT_MAX_PRS` (1..300). Both read through
`lib_env_apply plan-sibling <project>`. No settings row is seeded.

## Open question (Q1)

The hot list window is `CONFLICT_HOTSPOTS_DAYS` (default 30, lane
`conflict-hotspots-fleet`), not the 7 days the ticket names. A per-project row
key is 65 characters, over the 64 limit of `_lg_setting_key`. A global row
`lane.conflict-hotspots-fleet.conflict_hotspots_days=7` changes the window on
every box of that lane. This change seeds no row; the code works with either.
