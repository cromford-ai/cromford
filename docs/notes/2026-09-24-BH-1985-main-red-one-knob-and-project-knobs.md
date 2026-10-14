# The main-red label has one settable row, alerts name it, and project knobs reach the console

Doc: harness-control-plane, mission-control-settings

## What changed

- **`MC_MAIN_RED_LABEL` on `merge-queue` and `review-prs` is `settable: false`.**
  Both lane knobs stay registered, so the lanes' `${MC_MAIN_RED_LABEL:-…}` read
  is still visible. They can no longer be written from `harness-ctl`, the
  console or `PUT /api/settings`, and lane-gate ignores an existing
  `lane.<lane>.mc_main_red_label` row with its throttled log line. The label is
  set in one place: the lib row `lib.main-red-label.mc_main_red_label`.
- **The two main-red alerts name the resolved label.** `bin/main-red-detector.sh`
  and `bin/main-red-pr-pair.sh` resolve it once through
  `bin/lib/main-red-label.sh` and say "land the fix as a PR labelled
  `<label>`" instead of a hardcoded `fix-main-red`. Without the lib they say
  `fix-main-red`. The lib ships in the same `bin/` tree, and an env read there
  would register as a knob of the lane (`tests/lanes-registry-test.sh` §7).
- **`harness-ctl set <lane> <ENV> <value> <project>` checks the project.** It
  must be the first column of a non-comment line in fleet.conf
  (`$FLEET_CONF`, default `$HARNESS/fleet.conf`), exact match. A typo is
  refused with the list of real projects. If fleet.conf can't be read, the
  write is refused. `set` without a project doesn't read fleet.conf.
- **Project tabs show per-project knobs of box and hub lanes.** A knob declared
  `project_scoped: true` on a non-project lane (today lane-reaper's
  `LANE_REAP_DEADLINE_SECS`) gets a knob-only row on each project tab, named
  `<name> (<scope> lane)`, with no per-project switch. The worker's
  `GET /api/lanes/status?project=<p>` now reports that project's row for those
  knobs.

## Why

BH-1770 follow-ups (#1985). A lane row for the label split it for one lane, which
is what BH-1770 set out to end. An alert that says `fix-main-red` on a box that
renamed the label points the operator at a label that doesn't exempt the fix
from the freeze. A typo'd project was written as a row no lane reads and printed
as `SET`. The per-project reap deadline could only be seen or set from the CLI.

## Not changed

`off`/`on`/`seed` with a project don't check fleet.conf. Box lanes the registry
doesn't declare for a tab still come back as `NOT IN REGISTRY` rows with a
toggle, on the hub tab and on every project tab. On a project tab that toggle
writes `lane-off-<id>-<project>`, and nothing reads that flag. On project tabs
this ticket replaces the row for a lane that has `project_scoped` knobs. Every
other box lane still has the dead toggle, and that needs its own ticket.
