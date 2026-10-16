# BH-6976 (BH-6545.3): three pollers read wakes, their full poll is a backstop

Doc: none

## What changed

Three GitHub pollers now read the wake mirror before they read GitHub. Between
backstops, only a wake for the item makes the lane read GitHub for it again.
Each lane keeps its full poll as a backstop of at least 30 min.

| Lane | Reads it stops repeating | Wake kinds it reads | Backstop knob (default) |
|------|--------------------------|---------------------|-------------------------|
| `bin/orphan-reconcile.sh` | `issues/N/comments` (thread) and `issues/N` (blocker), per issue | `issue`, `pr` on N | `ORPHAN_WAKE_BACKSTOP_S` (1800) |
| `bin/decompose-parent-close.sh --cooled` | the whole GitHub-board pass (`issues?labels=ai-build`, `pulls?state=all`, parent reads) | `issue` on a key in `state/parent-close-<project>.keys` | `PARENT_CLOSE_BACKSTOP_S` (1800) |
| `bin/stuck-work.sh` (`swf_pr_facts`) | `commits/<sha>/check-runs` and `commits/<sha>/status`, per PR | `checks <head>`, `pr <n>` | `STUCK_WORK_CI_QUIET_TTL_S` (1800) |

The wakes come from `prs_wake_seen` (`bin/lib/pr-snapshot-wakes.sh`). It reads
the worker's wakes table into a local mirror and never acks a wake, so
`bin/wake-loop.sh` keeps its own cursor.

## The rule (`bin/lib/wake-backstop.sh`, `wb_due`)

First match wins. rc 0 = read now, rc 1 = skip.

| # | Condition | Answer |
|---|-----------|--------|
| 1 | `WAKE_BACKSTOP=0`, or backstop 0 | rc 0 `off` |
| 2 | last epoch empty, not digits, 0 or ahead of now | rc 0 `no-state` |
| 3 | age < floor | rc 1 `floor` |
| 4 | age >= backstop | rc 0 `backstop` |
| 5 | no `prs_wake_seen` after the lib tried to load `bin/lib/pr-snapshot.sh` | rc 0 `no-feed` |
| 6 | keys file missing; a `retry` line; more than 200 keys | rc 0 `no-keys` / `retry` / `many-keys` |
| 7 | `prs_wake_seen` rc 0 for a key and kind; rc 2 for one | rc 0 `wake:<kind>:<key>` / `no-feed` |
| 8 | every answer rc 1 | rc 1 `quiet` |

A backstop of 1-1799 reads as 1800. One line per UTC day goes to
`logs/wake-backstop.log` when that happens. A feed that cannot tell (rc 2) is a
read, so a feed outage restores the old cadence and never hides a change.

## Per lane

- **orphan-reconcile.** Pass 1 keeps each rc 0 thread and blocker read in
  `state/orphan-reconcile/<owner>_<repo>/<thread|blocker>-N.{json,meta}`. The
  meta is `<updatedAt|->\t<epoch>`, the epoch taken before the read. A cached
  copy is used only when the open list's `updatedAt` for N is the cached one
  (threads), and `wb_due` with floor 0 answers `quiet`. A 44 or 75 answer is
  never cached. A hit is not a read, so `ORPHAN_THREAD_FETCH_MAX` and
  `ORPHAN_BLOCKER_FETCH_MAX` still cap reads only. The run summary has one more
  word, `cache=<hits>/<reads>`. `wb_gc` deletes cache files older than 3 days
  on each run.
- **decompose-parent-close --cooled.** The 600 s `PARENT_CLOSE_COOLDOWN_S` is
  now the floor. Past it, a GitHub board runs the pass only on an `issue` wake
  for a key in `state/parent-close-<project>.keys`, a `retry` line, or the
  backstop. The pass writes the keys file at its end: every open child with a
  `Part of #P` line, and P. A close that did not land adds `retry`. A quiet
  exit leaves `state/parent-close-<project>.last` alone. A `wake:*` or
  `backstop` pass logs `parent-close: pass on <reason>` in the project log. An
  in-app board (no repo) and a hand run (no `--cooled`) are not changed. A dry
  run does not write the keys file.
- **stuck-work.** `_swf_ci_hit` keeps every check it had. When `prs_wake_seen`
  answers rc 1 for both `checks <head>` and `pr <n>`, the age limit is
  `max(STUCK_WORK_CI_TTL_S, STUCK_WORK_CI_QUIET_TTL_S)`. An rc 2 keeps
  `STUCK_WORK_CI_TTL_S` (900). `STUCK_WORK_CI_TTL_S=0` is still no cache.

## Knobs

Settings rows through the lane registry. The code default is the fallback.

- `lib.wake-backstop.wake_backstop` (`WAKE_BACKSTOP`, 0-1, default 1): the kill
  switch for lanes A and B.
- `lib.wake-backstop.orphan_wake_backstop_s` (`ORPHAN_WAKE_BACKSTOP_S`, 0-7200,
  default 1800; 0 = off).
- `lib.wake-backstop.parent_close_backstop_s` (`PARENT_CLOSE_BACKSTOP_S`,
  0-7200, default 1800; 0 = off).
- `lane.stuck-work.stuck_work_ci_quiet_ttl_s` (`STUCK_WORK_CI_QUIET_TTL_S`,
  0-7200, default 1800; 0 = off).

## Before numbers

The wave-1 report at plan time (fleet D1 `gh_ledger`, 24 h since
2026-10-15T12Z, 33 merged PRs), from the plan of this ticket:

| lane | class | counted | calls |
|------|-------|---------|-------|
| orphan-reconcile.sh | issues/N/comments | 2377 | 3816 |
| orphan-reconcile.sh | issues/N | 1800 | 3345 |
| decompose-parent-close.sh | pulls | 2010 | 2010 |
| stuck-work.sh | commits/SHA/check-runs | 1717 | 2207 |

The build box could not read the fleet ledger (`fleet read failed
(http=none)`), so these are not re-measured at build time.

## How to measure after

On the hub, 24 h after the deploy:

```
bin/gh-budget-report.sh --window 24h
```

Compare the four rows above. The after numbers are not measured yet.
