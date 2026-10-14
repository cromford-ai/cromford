# BH-1201 — the conductor HOLDS its age pages while it is paused, and flushes them when the mode returns

`Doc: MERGE-CONDUCTOR, ALERTS-STATE-MACHINE`

## What was wrong

An operator who switched the merge conductor off was still paged by it. The hub's
`logs/ALERTS.log` carried 424 `mode=kill-switch` conductor lines between
2026-09-13 and 2026-09-21 — one per aged PR per state, about PRs nothing was
going to touch, because the lane's two AGE pagers had never read the lane's own
mode:

- `mc_stuck_check` (`bin/lib/mc/classify.sh`) called `mc_alert` unconditionally
  once the TTL and identity checks passed, and wrote its
  one-per-(PR, state, head) marker first — so the page was also SPENT. When the
  flags lifted, nothing re-sent it.
- the final `else` of `mc_budget_check` (`bin/lib/mc/log.sh`) did the same for
  every non-state-note state, then stamped the row's `alerted` field.

Muting them would have been worse than the noise: the page would have been
dropped, not deferred, and the reason a PR had been stuck for four hours would
have vanished with it.

## What changed

Under `MC_MODE=kill-switch` or `observe` those two pagers now HOLD. A held page
is a row in the contract's `conductor_held_pages` table (BH-1201.0), keyed on
`(repo, number, state, head, kind)`, and the local side effect that would have
spent the page — the `MC_STUCK_DIR` marker, the row's `alerted` mark — is NOT
written. The PR still owes exactly one page.

The tick's first act, before any project subshell forks, is
`mc_hold_tick_begin`: it reads what is held into a tick-keyed cache, and when the
mode is `merge` or `actions` it flushes the oldest `MC_FLUSH_MAX` rows — page,
then mark, then release, never release first. Rows past the cap stay held and go
out next tick (`flush: N held pages remain, next tick`). A held row whose PR
moved under the pause is released `moved` and never paged. The tick's last act is
`mc_hold_tick_end`: one summary line, the two published settings rows, and the
paused reminder.

## What pages in which mode

| Alert | merge / actions | observe / kill-switch |
|---|---|---|
| STUCK (`mc_stuck_check`: past the state's TTL) | pages once per (PR, state, head) | HELD; flushed on the first merge/actions tick |
| Budget age (`mc_budget_check`: READY, WAIT_CI, QUEUED, parks) | pages once per (PR, state entry) | HELD; flushed on the first merge/actions tick |
| State notes: HEAD_MOVED, STACKED_WAIT, NEEDS_REBASE, REBASING | log only (BH-979) | log only — never paged, so never held |
| DEPLOY_VERIFY not serving | pages | pages |
| MERGED unverified / landed while the conductor was off | pages | pages |
| `IDENTITY_NOT_PERMITTED` | pages | pages |
| CLOSED unmerged with its issue still open | pages | pages |
| CI_ABSENT_TWICE / CI_FLAKE_TWICE | pages | pages |
| contested hold | pages | pages |
| mergify degraded | pages | pages |
| PDG hold (parent PR unmerged) | pages | pages |
| BLOCKED_AGENT lane failure | pages | pages |
| PAUSED reminder | never | once per `MC_HOLD_REMINDER_S`, non-critical |

The right-hand column is what `tests/conductor-hold.bh-1201-test.sh` block 8
proves: nine direct `mc_alert` call sites reach the stub under
`MC_MODE=kill-switch`, unchanged.

## The rules this touches

- **`MC_MODE` unset is NOT a hold.** `bin/merge-sweep.sh`,
  `bin/blocked-resolver.sh`, `bin/review-prs.sh`, `bin/batch-resolve.sh` and
  `bin/run-build.sh` all source `bin/lib/merge-conductor-lib.sh` without it and
  page exactly as they did. Only `bin/merge-conductor.sh` exports it, beside
  `MODE`. The match is the two exact words — `unknown`, `Kill-switch` and
  `observe ` all page, because silently suppressing on a typo is the failure
  this lane exists to avoid.
- **A failed write is never a recorded hold.** `held_page_put` rc≠0 is logged
  with its rc and not counted; the row keeps owing its page and the next tick
  offers it again. A box with no jobs client logs one line and holds nothing.
- **One page per row, ever.** The flush refuses to page a row whose mark already
  stands (the crash-between-mark-and-release case) and re-attempts only the
  release. The mark a flushed BUDGET page SPENDS is the one `mc_budget_check`
  would compute for that row right now, which for a park means today's UTC day
  rather than the day it was held on: recording the held day verbatim would leave
  the row released with a mark nothing matches, and the project fan-out —
  seconds later, in the same tick — would page it a second time.
- **A `mark` that comes back from the API is a leaf name.** The conductor sends a
  basename, but the row is read back from a worker that stores any string it is
  given, and the flush opens `$MC_STUCK_DIR/<mark>` for writing as root on the
  hub. It is reduced with `basename` before either use, so a `../../` mark cannot
  write outside the marker directory and cannot name an existing file to flip the
  mark-already-stands guard and release a page that was never sent.
- **The tick counters and the published count answer different questions.** The
  `N PRs would have paged` log line is this tick's suppressions. The published
  `merge-conductor.held_pages` row and the reminder's "is holding N pages" are
  the set that IS held (the tick's cache: the worker's list plus this tick's
  additions, minus what the flush released) — otherwise every tick of a pause
  after the first reports 0 while the worker holds the whole backlog.
- **Both numbers are knobs, not literals.** `MC_FLUSH_MAX` (default 10, 1..100)
  and `MC_HOLD_REMINDER_S` (default 21600, 600..86400) are registered in
  `catalog/lanes.d/merge-conductor.json` and read only through `lane_knob`, so a
  settings row on the console moves them.

## State this adds

| Path | What |
|---|---|
| `conductor_held_pages` (D1) | the held rows themselves — owned by BH-1201.0 |
| `state/merge-conductor/tick/<tick>.held.tsv` | this tick's cache of what is held; pruned by `mc_tick_gc` |
| `state/merge-conductor/tick/<tick>.hold-count.<KIND>.<STATE>` | append-only counters the workers write and the tick end sums into the log line |
| `state/merge-conductor/hold-reminder-at` | the epoch of the last PAUSED reminder |
| settings `merge-conductor.mode` / `merge-conductor.held_pages` | published every tick, in every mode |

## How to see it

- `grep 'would have paged' logs/merge-conductor.log` — one line per tick while paused.
- `bin/harness-ctl.sh show merge-conductor` — the two published settings rows.
- `HARNESS_TEST_SANDBOX=1 bash tests/conductor-hold.bh-1201-test.sh` — the ten blocks.
