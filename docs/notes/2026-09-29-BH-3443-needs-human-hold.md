# The waiting-on-human hold: the marker, the lane skip lines, the real placer (BH-3443)

Doc: RUN-BUILD-GRAPH, TRIAGE-STATE

## What changed

This is slice 2 of 5 of BH-3433. BH-3348 paid $6.53 in rebuilds of a review
block that only the hub could clear. Each rebuild ended on the same step. Now a
ticket like that is parked on the issue until a person does the step.

### `bin/lib/hold.sh`: the marker and its release

Three new exported regexes:

- `HOLD_NEEDS_HUMAN_RE`: a comment line that starts `NEEDS-HUMAN:` followed by
  text.
- `HOLD_HUMAN_DONE_RE`: a line that starts `HUMAN-STEP-DONE:`, or a
  `## Hub probe … PASS` heading.
- `HOLD_NH_TAG_RE`: the placer's hidden `<!-- nh-fp:<hex> -->` tag.

`decide` now asks, in order: needs-human, lift, abandon, done, hold. The marker
is asked first so the placer's own comment, which names `RESUME` in its release
line, never reads as a lift.

A bot comment is heard only for a needs-human marker that carries the tag. The
placer posts as the App, which is a Bot. A harness close-out that quotes a
marker line has no tag and holds nothing. A bot `HUMAN-STEP-DONE:` never
releases. A person can type a marker by hand, with or without the tag.

The recency law, newest decisive comment first (the `hold` label, `closed` and
`label-absent` are still decided before any comment):

| Thread (newest on the left) | Verdict |
|---|---|
| marker | `held	hold:waiting-on-human <at> <action>` (action capped at 160) |
| done, marker | `clear	lifted-by-human-step <done at>` |
| done, done, marker | lifted, at the done directly above the marker |
| RESUME, marker | `clear	lifted-by-comment <at>` |
| marker, done, marker | held again on the newest marker |
| done, marker, HOLD | `held	hold:comment` (a done never lifts a person's HOLD) |
| done, marker, ABANDON | `held	abandon:comment` |
| done, HOLD (no marker) | `held	hold:comment` (a lone done is neutral) |
| done, marker, and a title `(HOLD)` | `held	hold:title` |

Only comments are read for the marker. A title or body that describes the
feature quotes both words and holds nothing. `hold_is_pause` already matched
`hold:`, so every lane that reads a hold (fly-pool, run-build, hold-push,
ticket-ownership, mc/rebase, triage-state, orphan-reconcile, the resolver)
pauses on it with no edit. `hold_classify_thread` (PR threads) is unchanged.

### `bin/needs-human-hold.sh`: the placer

`bin/needs-human-hold.sh <project> <issue> <fp> <action> <source>` replaces
the stub. In order:

1. Checks argv (5 args, a numeric issue, a hex fp), else rc 2.
2. Checks the kill switch `lane_switch needs-human-hold-off`
   (`catalog/switches.d/needs-human-hold-off.json`). When it is on, logs and
   exits 0.
3. Checks for an issues board (`board_prefix` `-`). Anything else, including an
   unknown project, exits 0.
4. Pre-reads with `hold_check`. Unreadable is rc 75. Already stopped by state
   (closed, de-labelled, the `hold` label) is rc 0 with no marker. Already
   waiting with the same `nh-fp` on the newest marker is rc 0, nothing posted.
5. Masks `ghp_`/`gho_`/`sk-` tokens in the action.
6. POSTs the marker as the App.
7. Re-reads the thread. Anything but `hold:waiting-on-human` is one
   `[needs-human] could not place hold on <p>#<n>` alert and rc 1.
8. Only then sends the one ask:
   `[needs-human] <p>#<n> needs a human: <action> — <issue url>`.

It has no `/root/harness` default. With no `HARNESS` it reads no switch and
writes no log. With one, it logs to `logs/needs-human.log`.

### The lanes say why they skipped

`bin/orphan-reconcile.sh`, `bin/lib/triage-state.sh` (`_ts_owned`) and
`bin/blocked-resolver.sh` (`br_hold_gate`) each log
`… #<n> skip :: waiting on human: <action>` for a ticket held this way.

### `bin/blocked-resolver.sh`: park instead of rebuild

The new function is `br_needs_human_park`. It runs for `rescue-giving-up` (the
first REVIEW_BLOCKED) and `rebuild-review-blocked` (a rebuild that ended
REVIEW_BLOCKED). It reads the RESULT line: `.rebuild_result` for the second
reason, else the record's `RESULT`. When the line carries
` NEEDS_HUMAN:<fp>:<action>`, the lifecycle is:

1. Calls the placer (`… resolver`). `br_hold_gate` then parks the row HELD, and
   the resolver records `hold-needs-human` and `nh_placed` (`<fp> <sha12 of the
   RESULT line>`). No rung is spent and nothing is enqueued.
2. On every tick, `br_hold_recheck` re-reads the ticket. A HELD row with
   `nh_placed` is also re-offered by the rebuild-outcome source, the same way a
   HELD `rebuild-fresh-failed` row already was.
3. A `HUMAN-STEP-DONE:` clears the row. `nh_placed` matching the same RESULT
   makes the rung `rebuild-fresh`. For `rebuild-review-blocked` that replaces
   `abandon-rebuild`: the human did the step, so the ticket re-enters. The
   marker is never posted twice.

Other placer outcomes:

- rc 75: no rung, retried next tick.
- rc 1, or nothing placed (the switch is on): the rung runs as before.
- Observe mode: logs `WOULD place a needs-human hold`.

## What usually lies

- The orphan reconciler's python fallback (`HOLD_LIB=0`, a box mid-sync) does
  not know the marker. Only the lib path parks on it.
- A `HUMAN-STEP-DONE:` over a marker that sits over a person's HOLD leaves the
  HOLD standing. That is the law, not a bug. `RESUME` lifts both.
- None of this is dormant. `nh_on_block` (BH-3444) is live on main: every
  classified `REVIEW_BLOCKED` on an issues board appends ` NEEDS_HUMAN:<fp>:<action>`
  (`bin/lib/rb/review.sh`) and calls this placer with source `review`, from
  whichever build box, pool machine or hub ran the review. The resolver path
  then places with source `resolver` and parks the row. When both fire, the
  `nh-fp` pre-read keeps it to one comment. Merging this slice turns the real
  placer on everywhere at once, and that is intended: BH-3433 is on by default
  with a kill switch. `lane_switch needs-human-hold-off` stops both sources, and
  a needs-human block then takes the resolver ladder as it did before.

## Verify

`tests/hold-needs-human.bh-3443-test.sh`, `tests/needs-human-hold.bh-3443-test.sh`,
`tests/orphan-reconcile-needs-human.bh-3443-test.sh`,
`tests/resolver-needs-human.bh-3443-test.sh`. On a box after deploy:
`grep 'skip :: waiting on human' logs/<project>.log logs/blocked-resolver.log`.
