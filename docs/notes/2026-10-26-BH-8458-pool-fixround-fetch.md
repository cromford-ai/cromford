# BH-8458: pool fix rounds fetch the PR branch, carry the git error, and alert on a worktree-add streak

## Cause

`fly/Dockerfile` bakes the pool repo with `git clone --depth 50`. `--depth`
implies `--single-branch`, so the clone's `remote.origin.fetch` maps
`refs/heads/main` only. `br_fix_round` ran `git fetch -q origin`, which follows
that refspec, so `origin/ticket/<key>` never existed. The lease fell back to the
head gh reported, and `git worktree add -B brfix/<ck> origin/ticket/<key>`
failed with `fatal: invalid reference`. The reason said "see the git error in
logs/blocked-resolver.log", and that log was on the machine the reap destroyed.
project-6-os FXR-1087, FXR-1095, FXR-1096 and FXR-1097 (2026-10-26) each ended
`setup-blocked` with 0 model tokens.

## Fix

1. `br_fix_round` fetches `+refs/heads/<branch>:refs/remotes/origin/<branch>`
   after the plain fetch. This runs on every placement (pool and box). A failed
   by-name fetch is not a stop: the lease guard and the worktree add decide as
   before, and the fetch's own error rides in the reason if the add fails.
2. A failed `worktree add` puts `git: <line>` in the setup-blocked reason.
   `br_git_why` scrubs every token shape (`bin/lib/token-redact.sh`) and keeps
   the last `fatal:`/`error:` line (160 chars). If the scrub cannot load, a fixed
   text goes out instead of the raw stderr. The reason travels in
   `FIX_RESULT setup-blocked <b64>` to the hub, and `br_fix_adopt` logs it.
3. `br_wt_streak` (called from `br_fix_adopt`) counts the results whose decoded
   text starts `worktree add failed for origin/`, per project, in
   `state/blocked-resolver/<project>/wt-fail-streak`. At `BR_WT_FAIL_STREAK`
   (settings row, default 3, 0 = off) it sends one alert, id
   `br-wt-streak:<project>`, which names the kill knob
   `lane_placement.blocked-resolver-fix.<project>=box`. A `done`, `terminal` or
   `rebuild-fresh` result deletes the file and resolves the alert. Other results
   leave the count. Nothing changes the placement by itself.

`BR_OPT_OFF=bh-8458-wt-streak` turns off the streak and the git line (the reason
then carries `git: ` with no text). The by-name fetch stays.

## Not fixed here

- A stacked child on a single-branch clone: `origin/<parent>` does not resolve
  either, so the round merges main. Same cause, separate defect.
- A `hop_rung=mechanical` round runs `mc_rebase` before `br_fix_round` and does
  not get the by-name fetch.

## Check

`grep -E 'WT-STREAK|worktree add failed' logs/blocked-resolver.log` on the hub.
Suite: `tests/br-pool-fixround-fetch.bh-8458-test.sh`.
