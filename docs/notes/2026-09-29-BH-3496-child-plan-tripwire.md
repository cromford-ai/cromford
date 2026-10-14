# The child plan cost tripwire checker, cpt_check (BH-3496)

Doc: RUN-BUILD-GRAPH

## What changed

This is BH-3478.4, the checker behind the `# >>> child plan tripwire (BH-3478)`
hook that BH-3492 added to `bin/lib/rb/plan.sh`. The hook already sourced
`bin/lib/child-plan-tripwire.sh` when it was readable and logged
`CHILD_PLAN_TRIPWIRE skipped (no checker)` when it was not. Now the file exists.

`cpt_check <project> <child> <parent>` sums the `cost_rows` of stages `preplan`
and `plan` for the child and for the parent (four reads of
`GET /api/metrics/cost-rows?project=&ticket=&stage=&limit=2000`) and prints one
line, which the hook writes to `$BUILD/pipeline.log`:

- `FIRE <child_usd> <parent_usd> <pct> <thr>` when child x 100 > thr x parent
- `OK <child_usd> <parent_usd> <pct> <thr>`
- `OFF` when the knob is 0
- `UNMEASURED <why>`: bad arguments, no jobs client, knob unreadable, an
  invalid knob, a read that failed, was unparseable or came back as a full
  2000-row page, or a parent with no spend to compare against.

The threshold is the settings row `child_plan_tripwire_pct`. With no row it
is 50. An outage is UNMEASURED, not 50. A value that is not a non-negative
number is UNMEASURED and gets one line in `logs/child-plan-tripwire.log`; it is
never clamped.

On FIRE it reads ledger `child_plan_tripwire` / `"<project> <child>"`. If that
says `fired`, it stops. Otherwise it writes ONE warn alert through
`bin/alert-line.sh` (id `child-plan-tripwire:<project>:<child>`) and then puts
the ledger row `fired`. It never blocks the build.

## Where it differs from the plan

The plan had a direct `>> ALERTS.log` fallback for a box with no
`bin/alert-line.sh`, registered by a baseline file under
`tests/alert-writers-ratchet-baseline/`. The alert-writers ratchet runs in
delta mode on every PR and does not read baseline files; it went red on that
shape (checked on this branch). So there is no fallback: with no
`alert-line.sh`, or no root, there is no alert and no ledger PUT, and the next
build of that child tries again. The FIRE verdict still reaches
`pipeline.log`.

## Checking it on a box

- `grep CHILD_PLAN_TRIPWIRE /root/harness/builds/<project>-<KEY>-*/pipeline.log`
- `grep child-plan-tripwire /root/harness/logs/ALERTS.log`
- `bin/jobs-client.sh ledger-get child_plan_tripwire "<project> <KEY>"`

Suite: `tests/child-plan-tripwire.bh-3496-test.sh`.
