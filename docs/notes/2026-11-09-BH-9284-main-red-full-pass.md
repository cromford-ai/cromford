# BH-9284: the main-red full pass waits for the lock, and the pair lane reads every fleet repo

Date: 2026-11-09

## What was wrong

- From 2026-11-06 19:00Z the merge conductor's hourly full pass of
  `bin/main-red-detector.sh` never completed. It took
  `locks/main-red-detector.lock` with `flock -n` at minute 00. The */5 recheck
  (`bin/main-red-recheck.sh`, `--flagged-only`) held the lock at that minute.
  Nothing alerted.
- On 2026-11-08 two project-6 PRs failed the same job with the same first
  error. `bin/main-red-pr-pair.sh` read only `$HARNESS_REPO`, so it raised
  nothing.

## What changed

1. `bin/main-red-detector.sh --wait-lock`: a scheduled full pass (no repo
   arguments, not `--flagged-only`, not `--explain`) waits up to
   `MAIN_RED_FULL_PASS_LOCK_WAIT_S` (default 90 s) for the lock. The
   conductor (`bin/lib/mc/tick-scope.sh` `mc_tick_main_red`) passes the flag.
   The recheck never waits. The choice (wait, not a minute-00 skip of the
   recheck) is in the script header, section `THE FULL PASS WAITS`.
2. A waited pass that still loses logs
   `full pass: reason=lock-held — waited <n>s for locks/main-red-detector.lock`.
3. A completed full pass stamps the ledgers row `main_red_full_pass/last`
   (file `state/main-red/full-pass.last` with no row store). When a waited pass
   gives up and no pass completed in `MAIN_RED_FULL_PASS_STALE_MIN` (default
   120) minutes, ONE warn alert `main-red-full-pass-stale` names the last
   completed pass and the last `reason=lock-held` line. The next completed pass
   resolves it.
4. `MAIN_RED_PAIR_REPOS` unset or empty now means every fleet.conf repo plus
   `$HARNESS_REPO`, the list the detector reads. Repo arguments, then a
   hand-set value, win. The lane logs `repos: <n> (from args|env|fleet.conf)`.

## Knobs

- `lib.main-red-detector.main_red_full_pass_lock_wait_s` (90, 0 = no wait)
- `lib.main-red-detector.main_red_full_pass_stale_min` (120, 0 = off)

## Limits

- The watch runs only when a waited full pass gives up. If the conductor stops
  calling the detector at all, this watch is silent.
- The pair lane now reads every fleet repo per tick, each
  capped by `MAIN_RED_PAIR_MAX_PRS`.

Tests: `tests/main-red-detection.bh-9284-test.sh`.
