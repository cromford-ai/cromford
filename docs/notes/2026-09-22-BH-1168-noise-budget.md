# BH-1168: the alert-triage lane now stops on a noise budget, not only on a dollar cap

**The gap.** A session that concludes `handled=0 escalated=0` costs full price
and produces nothing. On 2026-09-20 that was 150 of 192 sessions at ~$4 each,
and on the 16:10–21:20Z tail it was every one of the 11 sessions the clamped
session cap let through. BH-1039's dollar cap catches that only after the day's
money is gone, and the $5/day `lane alert-triage` row BH-1164 set catches it
sooner only by being small enough to hurt a legitimate day too. The bound that
was missing is on the thing that is actually wrong: the lane is finding nothing.

**What shipped.** A per-lane, per-UTC-day noise budget, in the same shape as the
dollar cap, as part (3) of #1164.

- `bin/lib/lane-caps.sh` gains `lane_noise_cap`, `lane_noise_count`,
  `lane_noise_record` and `lane_noise_cap_tripped`, plus a third
  `lane_caps_knobs` row. Resolution is env `LANE_NOISE_CAP_<LANE>` → the conf's
  `noise <lane>` row → its `noise default` row → the built-in
  `LANE_CAPS_DEFAULT_NOISE=10`. `0` means stopped, `off` means unbounded, and a
  value that is neither a whole number nor `off` is IGNORED and named — the same
  three readings the dollar cap already had.
- `catalog/lane-caps.conf` gains a NEW directive, `noise <name> <n|off>` (and
  `noise default`), with `noise alert-triage 10` and `noise default 10`. It is a
  separate directive rather than a fourth column on `lane` rows on purpose: the
  shipped parser reads a row as `kw a b c`, so a fourth column on a box whose
  library is one sync behind would land `40000 10` in `$c`, refuse the byte
  column and silently drop medic to the 20000 default. A `noise` row on an old
  library is named as one legacy row and changes nothing else.
- `bin/alert-triage.sh` checks the budget TWICE — at the top of the tick, before
  any collection, and again before each family's call, so the tick that crosses
  the budget stops inside itself rather than buying `TRIAGE_MAX_FAMILIES-1` more
  sessions. After each bought session it parses `handled=`/`escalated=` from the
  session's own output and calls `lane_noise_record`.
- `catalog/lanes.d/alert-triage.json` carries the knob row
  (`LANE_NOISE_CAP_ALERT_TRIAGE`, `zero_means: "off"`), so it reaches
  `bin/harness-ctl.sh show alert-triage` like every other bound.

**The decisions a reviewer should check.**

- **Reset, not decay.** Any session with `handled>0` or `escalated>0` sets the
  count to 0. The ticket allowed either; reset needs no second timestamp and is
  the reading least likely to stop a lane that is doing real work.
- **Both fields or nothing.** A session with no parseable summary neither bumps
  nor resets. A broken runner must not be able to stop the lane, and it must not
  clear a real count either. Only bought sessions reach the record at all —
  settlement, the cliff refusal (rc 79) and the gate refusal (rc 74) all
  `continue` above it.
- **Fail open.** A missing counter is a real 0. A counter that is present and
  unreadable answers rc 2, the lane RUNS, and `logs/lane-caps.log` says so. A
  bound that stops the de-noising layer because it could not read a file would
  fire in exactly the situation the layer exists for.
- **Built-in 10, not `off`.** Same reason BH-1164 dropped the dollar fallback to
  $50: the number that binds on the box furthest behind has to be the tight one.
  Whenever the built-in binds, `lane_noise_cap` says so once per lane per day.
- **Only alert-triage is wired.** It is the only lane that concludes a
  `handled=N escalated=N` verdict; medic and responder get the library and no
  call site until they carry one.

**State and paging.** The counter is `state/lane-noise-<lane>.count`, ONE file
per lane holding `<YYYY-MM-DD><TAB><n>`, written `tmp`+`mv` under a sub-second
`flock` (a dedupe around one read-modify-write, never held across a session).
Another day's stamp reads 0 and is overwritten, so nothing accumulates and
nothing needs pruning. The stop pages ONE `NOISE BUDGET` line per lane per UTC
day, appended before `flags/alerted-lane-noise-<lane>-<day>` is touched, so the
worst crash outcome is a duplicate line rather than a silent stop. Nothing is
dropped: families past the budget are re-spooled at their pre-tick stamp exactly
as an rc-74 refusal re-spools them.

**How to drive it.** `tests/triage-noise-budget.bh-1168-test.sh` — section L is
the library (resolution, counter, reset, trip, fail-open, knob row), section A is
the real `bin/alert-triage.sh` end to end with only `agent-call.sh`, `ssh`,
`flock` and `timeout` stubbed. On a live hub: `logs/alert-triage.log` shows
`STOPPED on the lane's noise budget`, `logs/ALERTS.log` at most one
`NOISE BUDGET` line a day, `state/lane-noise-alert-triage.count` moving with the
sessions, and `logs/lane-caps.log` carrying the built-in-default line on a box
without the conf row.

Doc: lane-volume-caps, zero-means-off
