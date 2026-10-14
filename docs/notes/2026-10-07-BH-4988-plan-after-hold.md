# BH-4988: plan-time fragment exemption and the After: hold

Doc: SCHEDULER

What changed: `bin/plan-overlap.sh` no longer defers a plan whose only
collisions are on fragment paths (Generated-files rows, or a bare fragment
directory against a path under it). Any other overlap now records
`After: <OTHER>` through the new `bin/plan-after.sh`. The pre-PLAN
`# >>> overlap not-before` gate then holds the ticket for free until OTHER has
no claim, live build dir, `job_claims` row or open PR, so it does not buy a
plan every ten minutes. The hold is read from the box-local marker, or, on a
box without one (every Fly pool re-offer), from the key's newest
`overlap_defer` job artifact, which now carries `choice` and `after`. Every choice is a `PLAN_HOTSPOT` line in the build's
`pipeline.log` and `logs/plan-hotspot.log`. Knobs: `lib.plan-hotspot.*`.

Also fixed: plan-overlap's fleet source called `fc_list_dir`, which nothing
defines (the lib's function is `fclaim_list_dir`). Fleet `job_claims` rows were
never read at plan time on any box until this change. `bin/overlap-schedule.sh`
still calls the old name and is unchanged here.

Tests: `tests/plan-hotspot-overlap.bh-4988-test.sh`.
