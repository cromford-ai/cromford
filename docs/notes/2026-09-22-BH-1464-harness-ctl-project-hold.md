# 2026-09-22 — BH-1464: `harness-ctl.sh off|on <hub lane> --project <p>`

Doc: harness-control-plane

BH-1463 landed the reader: `lane_project_held <id> <project>` answers from the
`lane-off-<id>-<project>` pause_flags row, and five hub lanes declare
`per_project_hold` in `catalog/lanes.d/`. Nothing could WRITE that row.
`bin/harness-ctl.sh` refuses a project argument on a hub lane — deliberately,
since BH-1165 — so the hold existed and no operator could set one.

This is the CLI slice of #1419 and nothing else. The five lane scripts (#1465)
and the worker/console (#1466) are still to come, so a hold written today is
still read by nobody.

## What changed

`bin/harness-ctl.sh`, one file:

```
bin/harness-ctl.sh off <hub-lane> --project <p> "<reason>"
bin/harness-ctl.sh on  <hub-lane> --project <p> "<reason>"
```

- `lane_hold_ok <id>` / `hold_lanes` — two one-line predicates over the registry
  this tool already reads (`per_project_hold == true`). The lane list in the
  refusal is generated from the registry at call time, so a lane that gains the
  field tomorrow needs no edit in the CLI, the README or this note.
- `switch_name` mints the `lane-off-<id>-<p>` suffix when the lane's scope is
  `project` OR `lane_hold_ok` is true. Every other hub lane keeps the old
  refusal, because `flags/lane-off-alert-triage-project-3` would be a file nothing
  ever reads and a stop that stops nothing.
- `cmd_off` and `cmd_on` parse `--project <p>` immediately after the lane id and
  before the reason. On a hub lane without the field they exit 2 naming the
  lanes that do take it.

## Why the project is a FLAG and not a second positional

`off merge-conductor project-3 "spend"` is still refused, unchanged. That form is
the BH-1165 bug: with a free-form trailing reason it read `project-3` as the first
word of the reason and stopped the conductor FLEET-WIDE while printing a line an
operator reads as "I stopped project-3". A stop button whose blast radius depends on
how you spaced the sentence is not a stop button. `--project <p>` cannot be read
as anything else at any spacing, so it is the form that carries the new power;
the positional refusal now adds one clause pointing at it.

In the `--project` branch of `on`, `fleet.conf` is not consulted: that lookup
exists only to refuse a single trailing argument that might be a project rather
than a reason, and with the project explicit there is no ambiguity left to
resolve.

## Write ordering is the existing one

Both forms go through the same `flag_set` (`bin/lib/jobs/flags.sh`): the FILE
first, then `PUT /api/flags`. If the row write fails the command dies with the
existing message ("the flag file was written but the row was not — the box is
stopped, the page is not") and never prints an `OFF` line. `on --project` clears
exactly one row; `lane-off-<id>` and `all-off` still hold, which the `note:` line
already said and the suite now pins.

## The lanes, today

`blocked-resolver`, `review-autopilot`, `merge-conductor`, `merge-sweep`,
`main-red-pr-pair`. The registry is the source of truth for that list, not this
sentence: `jq '.lanes[]|select(.per_project_hold==true)|.id' catalog/lanes.json`,
or just run the refusal and read it.

## Verified

`tests/harness-ctl-project-hold.bh-1464-test.sh` — 32 assertions over the eight
cases the ticket names, against a scratch `$HARNESS` whose jobs-client stubs the
transport only and sources the REAL `flag_set`. One assertion beyond the eight:
on a PROJECT-scoped lane `--project <p>` is an alias of the positional form and
writes the same switch name, so there is one grammar for one switch rather than
a second rule to remember. Six deliberate mutations (the
`switch_name` exception, the `cmd_off` gate, `hold_lanes`, the two usage lines,
the `flag_set … || die`, and the project dropped in `cmd_on`) were each confirmed
red on the sections that own them before the tree was restored.
`tests/harness-ctl-test.sh` stays 35/0 — it is what pins the positional refusal.
