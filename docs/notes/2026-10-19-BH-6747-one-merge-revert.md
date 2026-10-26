# A one-merge red main is reverted without a bisect (BH-6747, BH-6541.4)

Doc: MERGE-CONDUCTOR, EVENTS

## What changed

- **Shortcut.** `verdict()` in `bin/main-red-bisect.sh` first lists
  `git rev-list --first-parent green..red`. If the list is exactly one commit
  and its subject is `Merge pull request #N from O/<branch>`, that merge is the
  culprit. The lane runs no P0, no P1 and no bisect. The episode gets `steps=0`
  and the new key `shortcut=one-merge`. Every other span (zero merges, two or
  more, one non-PR merge, a direct commit on the first parent) takes the old
  P0, P1 and bisect path. The still-red check, the pending file and the ledger
  rows are the same on both paths.
- **Wording.** `bin/lib/mrb-act.sh` reads `shortcut`. On a one-merge revert the
  PR body says `Merge <sha> (#N) is the only merge since the last green <sha>,
  so this reverts it without a bisect.`, the re-land ticket says `It is the
  only merge since the last green <sha>, so no bisect ran.`, and the warn alert
  ends `(the only merge since the last green; no bisect)`. A bisected revert
  keeps the old text. The labels (`fix-main-red`, `hotfix`) and the
  `Red suites:` line do not change. The revert PR has no empty `Bisect:` fence.
- **FREEZE_LIFTED.** `bin/main-red-recheck.sh` runs the detector as a child,
  not through `exec`. For each freeze file that was up before the detector
  started and is gone after it returned, it writes
  `<ts> main-red-recheck: FREEZE_LIFTED after=<min> flag=<name>` to
  `logs/main-red.log`. `<min>` counts from `raised=`, else `since=`, else the
  file mtime. It is floored and never negative. The lane exits with the
  detector's rc. A freeze that the hourly detector pass lifts writes no such line.

## Why

When a red main is one merge past the last green, the culprit is known. The
two probes cost up to two suite runs (`MAIN_RED_BISECT_SUITE_TIMEOUT_S` each)
before the revert opens. The `FREEZE_LIFTED` line measures how long a freeze
stays up.

## Knobs

No new knob. `flags/lane-off-main-red-bisect` and `MAIN_RED_BISECT_REVERT=0`
still stop the act. Suite: `tests/main-red-direct-revert.bh-6747-test.sh`.
