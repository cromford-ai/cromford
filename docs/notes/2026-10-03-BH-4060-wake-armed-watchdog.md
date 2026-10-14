# A watchdog for armed-but-silent wake classes, and the arming runbook (BH-4060)

Doc: EVENTS

## What changed

`bin/pipeline-health.sh` has a new block, `# >>> wake classes armed (BH-4060)`.
It pages once, keyed `wakearmed:hub`, when a `wake-lanes-<class>` flag is on and
`bin/wake-loop.sh` has not logged its `wake classes armed:` line for
`WAKE_ARMED_WATCH_S` seconds. That is a new knob on the `pipeline-health` lane,
`required: true`, registry default 3600, and 0 turns it off. The decision lives in
`bin/lib/wake-armed-watch.sh`. `wakearmed` is in `RETRACT_NS`, so the page
resolves when the line comes back or the flags go.

`docs/EVENTS.md` §9 has the operator runbook for arming the six classes one at
a time, and one line per tick-only lane from the #4060 audit saying why it stays
on a timer.

## What did not change

No class is armed and no cron moved. Arming is a hub data change
(`bin/jobs-client.sh flag-set wake-lanes-<class> on`), and the cron backstops
move only after a class has been seen firing for real. Both are later slices
of #4060.
