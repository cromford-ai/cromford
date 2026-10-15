# The build tripwire alerts and never stops a build (BH-6705)

Doc: COST, CALL-GUARD

## Decision

the operator, 2026-10-14: "Remove the build cost check trip wire. It should never stop
a build." On the same day the operator set the settings row
`lib.build-tripwire.build_tripwire` to `0` by hand and released the two
`paused` ledger rows. This change puts the decision into code, so a reset
settings table or a new project cannot bring the stop back.

## What changed

The spend and repeat rules (`tw_eval`) and the expected-spend figure
(`tw_expected`) do not change. What a trip does changes. Four stop points are
removed:

| Stop point before | Now |
|---|---|
| The live meter (`bin/lib/cost-live.sh`) killed the claude session when `tw_check_build` answered rc 0. | `tw_check_build` answers rc 1 on every path, so the meter never kills. |
| `tw_trip` wrote `$BUILD/TRIPWIRE`, and `CC()` (`bin/lib/rb/plan.sh`) ended the build `BUILD_REFUSED TRIPWIRE_PAUSED`. | `tw_trip` writes `$BUILD/tripwire-alert.txt`. `CC()` does not read `TRIPWIRE`, so a leftover marker in a resumed build dir does not stop it. |
| `tw_trip` wrote the ledger row `build-tripwire "<project> <KEY>" = paused`, and the launch guard (`bin/lib/rb/gates.sh`, `tripwire paused skip`) answered `BUILD_REFUSED SKIP_TRIPWIRE`. | `tw_trip` writes status `alerted`. A leftover `paused` row gets one `pipeline.log` line and the build runs. |
| `bin/agent-call.sh` refused a build call rc 74 `AGENT_CALL_REFUSED tripwire` when `$BUILD/TRIPWIRE` existed. | The block is removed. |

A trip now writes, once per build dir (claim file `.tripwire.claim`):

- one critical page: `TRIPWIRE (alert only, build continues) <p>/<KEY> <rule>: ...; alert_row=written|FAILED; diagnosis <dir>/tripwire-alert.txt`;
- the ledger row `alerted`, which the daily digest Tripwires section reads;
- `$BUILD/tripwire-alert.txt`: the verdict line, the diagnosis, and `alert_row: written|FAILED`.

After the first trip, `tw_check_build` returns at once on the claim file, so
the live meter does not re-measure the build every minute.

## The switch

`BUILD_TRIPWIRE` now defaults to `0` (`catalog/lanes.d/_lib.build-tripwire.json`,
lib fallback `${BUILD_TRIPWIRE:-0}`). Its meaning is the alert switch:

- `1`: measure and alert.
- `0`: measure nothing, alert nothing.

No value of any tripwire knob stops a build. To turn the alert on:

```bash
bin/jobs-client.sh setting-set lib.build-tripwire.build_tripwire 1
```

## Not changed

The `$OUT.tripwire` handling in `bin/agent-call.sh` stays. Its only writer is
the live meter, which writes it only when `tw_check_build` answers rc 0, and
that answer no longer exists. Old `paused` rows stay as data. Nothing deletes
them.

## Suites

`tests/build-tripwire-alert-only.bh-6705-test.sh` (new). Premise changes in
`tests/build-tripwire.bh-3501-test.sh`, `tests/tripwire-seams.bh-3481-test.sh`,
`tests/budget-stop-tracer-test.sh` and `tests/cost-row-attribution.bh-3986-test.sh`.
