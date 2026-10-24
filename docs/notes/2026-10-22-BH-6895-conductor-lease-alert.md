# The per-project conductor alerts when a run misses its lease (BH-6895)

Doc: MERGE-CONDUCTOR

## What changed

A merge-conductor run on a lane-run machine (`bin/merge-conductor-project.sh`)
ends rc 0 with `PROF mc-project state=LEASE_LOST` when it lost the project
lease mid-run, and with `state=LEASE_HELD` when another holder had the lease
and nothing ran. Before this change the hub gate read both as a clean `done`
row. It wrote no log word and no ALERTS line.

Now `mc_proj_newest` (`bin/lib/mc/project-placement.sh`) gives such a row the
detail `lease-lost` or `lease-held`. The gate's `done` arm then:

1. writes the row id to `state/merge-conductor/project-fly/<project>.lease-seen`,
2. logs one line `<project> project-fly: row <id> ended LEASE_LOST — lease miss`
   (`project-box(<name>)` on a box placement),
3. writes one ALERTS line, `--id mc-project-lease-<project>`, severity warn.

Each row alerts once. The alert has its own stamp `<project>.lease-alert-at` and
the same window as the other gate alerts (settings row `mc_project_fly.alert_s`,
fallback 3600 s). A no-capacity or machine-failed alert never holds it.

Routing does not change: the gate enqueues the next row as before. A
`LEASE_LOST` row with `deferred=<word>` stays a deferred row (the take-back
runs) and does not alert. `LEASE_UNAVAILABLE` already ends rc 75 and counts in
the machine-failed streak.

## For the rollout (#6895)

The 24 h gate before `lane_fallback.merge-conductor.<project>` goes `off` needs
0 lease conflicts. Check it with:

    grep -E '<project> project-(fly|box).*lease miss' /root/harness/logs/merge-conductor.log

If the alert fires and the run was a landing write, set
`lane_placement.merge-conductor.<project>` to `hub` and stop the rollout.

Test: `tests/merge-conductor-lease-alert.bh-6895-test.sh`.
