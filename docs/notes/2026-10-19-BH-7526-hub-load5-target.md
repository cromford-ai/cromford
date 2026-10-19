# BH-7526: the hub load5 target in the CPU table, and three hub-only reasons

Doc: docs/notes/2026-10-17-BH-7252-lane-cpu-rank.md

BH-7526 (BH-7406.1) carries three items of #7252 that no merged slice
delivered: "Hub load5 under 24 after the moves (state the before/after)",
"move the next lane, one lane per PR" and "lanes that must stay on the hub get
a one-line reason in the lane registry".

## The target line

`bin/lane-cpu-rank.sh` adds one line to the table, right after the
`Load (load1/load5): ...` line:

    Hub load5 target: under 24 (row lane_cpu_rank.load5_target). Before: 52.42 at 2026-10-17T09:30:45Z. After: start <x>, end <y>. Target met: yes|no|unknown.

- Target: settings row `lane_cpu_rank.load5_target` (seeded 24). A missing,
  unreadable, non-numeric or zero value uses the code default 24, and the line
  says `(code default)`.
- Before: row `lane_cpu_rank.load5_before` (seeded 52.42, the hub load5 at the
  first lane flip, #7252 #issuecomment-6252072531) and
  `lane_cpu_rank.load5_before_at` (seeded 2026-10-17T09:30:45Z). No row or a
  non-numeric value prints `Before: not set`. A malformed timestamp is left out.
- After: load5 at the start and at the end of the 1 h window.
- `Target met: yes` only when both after reads are numbers and both are under
  the target (strict). A read that is NA prints `unknown`, never `yes`.

The log line does not change. The rows are read once per run.

## The hub-only reasons

Seeded as `lane_placement.<lane>.hub_only` rows. The table prints them in the
"hub-only reason" column:

| lane | reason |
|---|---|
| lane-cpu-rank | samples the hub's own /proc; on another machine it measures that machine |
| lane-move | reads the hub's pipeline-health and lane-snapshot-publish logs and state/lane-move/ to judge a move |
| lane-snapshot-publish | applies lane-run write-backs into the hub's tree and publishes the hub's snapshots |

`lp_decide` reads a `hub_only` row only when the lane is placed `fly`. None of
these three has a `lane_placement` row or a `bin/lib/lane-move/<lane>.sh`
module, so no placement and no lane-move gate changes. Other lanes get their
reason in their own move ticket.

## Moving the next lane

This PR moves no lane. One ticket moves one lane, one per PR: #7423
stuck-work, #7424 dequeue-watch, #7425 untriaged-wake, #7426
watchdog-responder, #7427 review-autopilot. #7522 fixes the lane-move bug
behind the "no runs in the before window" FAIL reports.

## How to measure again

The table posts once per issue. To get a new after number, set the issue row
to a new issue:

    bin/jobs-client.sh setting-set lane_cpu_rank.issue <n>

The seeded row is 7406. The first table with the target line posts there after
the next 14:05Z run.
