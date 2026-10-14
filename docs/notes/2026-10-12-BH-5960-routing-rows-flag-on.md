# flag_on reads a ported routing name from its row (BH-5960)

Doc: DB-COORDINATION-SPEC

## What changed

- `_flag_on_eval` in `bin/lib/flag-on.sh` has a new step for the routing
  families (`builder-fly`, `fly-pool`, `fly-pool-app`). After `routing_sync`,
  a ported name with a worker configured (`JOBS_URL` and `HARNESS_SECRET`)
  answers from `flag_active`: the harness_flags row and its last-good cache.
  Otherwise the `flags/` file answers, as before.
- The ported-name read is one helper, `_flag_on_from_row <name> <unknown-rc>`.
  The paused / automerge-disabled path calls it with `<unknown-rc>` 0. Its
  answer does not change: `flag_active` never returns "unknown" for those names.
- The routing path calls it with `<unknown-rc>` 1. When the worker is down and
  nothing is cached, a routing name reads OFF. A routing flag is not a stop
  switch. BH-4154's `_routing_has` reads an unknown routing flag as absent too.
- The value (`flag_value fly-pool-app <p>`) comes from the cache of the scope
  that answered: `fleet` when `FLAG_ROW_SCOPE` is `fleet`, else the name's
  default scope.
- A routing read never writes `state/flags-cache/<name>.json` or the
  `.outage` marker, and never writes an ALERTS line.

## Why

BH-4154 (PR #4546) ports these names to harness_flags rows and
`bin/flags-import.sh` deletes their files. Before this change the routing case
answered from the file before the ported-name branch could run. So after #4546
`flag_on fly-pool <p>` read OFF and `flag_value fly-pool-app <p>` printed
nothing, for every caller (`bin/fly-dispatch.sh`, `bin/fly-pool-tick.sh`,
`bin/free-slots.sh` and others). This change must merge before #4546.

## Effect on main today

None. On main `FLAG_PORTED_RE` does not match the routing names, so the new
step is skipped and the file answers.

## Verify

`HARNESS_TEST_SANDBOX=1 bash tests/flag-on-routing-rows.bh-5960-test.sh`
(R1-R11; the suite ports the names the way #4546 does).
