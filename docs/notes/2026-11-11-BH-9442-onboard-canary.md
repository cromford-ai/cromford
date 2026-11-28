# BH-9442 slice C0: a new repo builds no ticket until a canary PR is green
Doc: docs/onboarding-a-repo.md, docs/ONBOARDING.md

SLICE: C0 of #9442.

## Problem

project-12, project-13 and project-14 were onboarded about 2026-11-05. In the window
2026-10-27 to 2026-11-10 they merged 0 PRs and closed 16 unmerged. The same
"E2E Tests" / "Playwright E2E" checks were red on every PR and every rebuild.
Onboarding checked only the harness wiring. It never checked one PR of the
repo's own CI, and no build gate stopped the first build.

## What changed

- `bin/onboard-canary.sh` (new, hub lane `onboard-canary`). Verbs `--hold`,
  `--start`, `--tick`, `--weekly`, `--status`, `--override`. It opens one
  no-op PR (branch `harness/onboard-canary-<ymdHM>`, file
  `.harness/onboard-canary.md`), reads the check runs and commit statuses on
  its head sha, records a verdict, then closes the PR unmerged and deletes the
  branch. No model call.
- Settings rows: `onboard.<p>.canary` (JSON verdict with the head sha),
  `onboard.<p>.canary_gate` (`held` or `released`),
  `onboard.<p>.canary_override` (an operator reason, releases the gate),
  `onboard.<p>.canary_skip` (the weekly run skips the project).
- Build gate `bin/lib/rb/gates.d/onboard-canary.sh`, after the dispatch mode
  gate and before the budget gate. A `held` row with no override row ends the
  build `BUILD_DEFERRED onboard-canary held: <state> <sha12>` (exit 3). No row,
  a `released` row or an unreadable row admits the build.
- Entry points: the `ready` station of `bin/onboard-run.sh` and the new
  `== onboarding canary ==` block of `bin/load-project.sh` run `--hold`. Neither
  fails its step.
- `bin/review-prs.sh` does not review a `harness/onboard-canary-*` PR.
- Cron `cron/lanes/780-onboard-canary.cron`: `--tick` every 5 min, `--weekly`
  Monday 06:17Z. Knobs in `catalog/lanes.d/onboard-canary.json`:
  `ONBOARD_CANARY_TIMEOUT_MIN` (60), `ONBOARD_CANARY_NOCHECK_GRACE_MIN` (10),
  `ONBOARD_CANARY_CHECK_PAGES` (5).

## Effect on the fleet at deploy

Only `--hold` writes `held`. No project in the fleet has a gate row today, so 0
projects are held at deploy. A weekly red gives one alert and holds nothing.

## Rollback

`bin/harness-ctl.sh off onboard-canary` stops the lane. To release one held
project: `bin/onboard-canary.sh --override <p> <reason>`.

## Slices left

1. C1: run the builder gate once on a pool machine for the repo and record
   could-not-run faults by name.
2. C2: run the canary for project-12, project-13, project-14, cromford-web and project-7
   on the hub after deploy, and put the result table in a PR:
   `bin/onboard-canary.sh --start project-12 project-13 project-14 cromford-web project-7`,
   then `bin/onboard-canary.sh --status`.
