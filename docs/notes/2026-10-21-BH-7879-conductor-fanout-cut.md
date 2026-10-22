# The conductor's per-project fan-out lives in bin/lib/mc/tick-scope.sh (BH-7879)

Doc: MERGE-CONDUCTOR

BH-7879 (slice C4 of BH-6518) moved the fifth inline concern out of `bin/merge-conductor.sh`: the per-project fan-out. It is the held-page flush before the first worker forks (BH-1201, BH-1840), the project gate `MC_PROJ_GATE` (BH-6890), the `for P in $("$H/bin/fleet-conf.sh" --projects)` loop with one backgrounded subshell per project (the ETag and snapshot counter files, the full-tick lock of BH-5463, `tick_project`, `mc_proj_hub_unmark`, the `PR-SNAPSHOT` line, `gh_rest_etag_report "merge-conductor:$P"`), and the final `wait`.
The block is now `mc_tick_fanout` in `bin/lib/mc/tick-scope.sh`, below `mc_tick_prelude`. Its body is the old driver lines, byte for byte, with their comments. It uses no `local`, so `MC_PROJ_GATE`, `P` and `PIDS` stay global. `tick_project` reads `MC_PROJ_GATE`.

The driver calls `mc_tick_fanout` at the old place: after the parent `GH_ETAG_COUNT_FILE` export and its EXIT trap, and before the keyed early exit. The guard now also requires `declare -F mc_tick_fanout`. A box with the C3 `tick-scope.sh` and this driver refuses the tick with the same `CONDUCTOR MODULE MISSING` alert and `exit 1`. A box with this `tick-scope.sh` and the C3 driver runs as before: the old driver keeps its inline loop and never calls the function.

The lock-held `exit 0` is inside the per-project subshell, so it still ends that one project only. The function can return 1 on an empty fleet (`[ 0 -gt 0 ] && wait`). The driver has no `set -e`, so that value is ignored, as the old top-level line was.

`tick_project` did not move. BH-685 keeps it in the driver (`tests/mc/driver-complete-test.sh`).

Two knobs gained a `read_in` of `bin/lib/mc/tick-scope.sh`, because the driver no longer names them: `MC_FULL_TICK_SINGLE` (`catalog/lanes.d/merge-conductor.json`) and `MC_PROJ_TAKEBACK` (`catalog/lanes.d/merge-conductor.knobs.d/MC_PROJ_TAKEBACK.json`). `MC_PROJ_GATE` is now set only in `tick-scope.sh` and read with a default in the driver, so `tests/lanes-registry-test.sh` carries it in `PLUMBING`, as it does `MC_WORKERS_DONE_BY`. No value, default or settings row changed.

`tests/mc-tick-fanout.bh-7879-test.sh` pins the counter files, the snapshot and ETag lines, the project filters, the full-tick lock, the project gate, the held-page flush, the real driver's lock file, the new refusal path, and that the shim never defines the function. Two source pins moved with the code: `tests/gh-rest-etag.bh-1322-test.sh` section E and the E2E guard of `tests/merge-conductor-project.bh-7462-test.sh` now read `bin/lib/mc/tick-scope.sh`, with the same pattern and the same count. The C1, C2 and C3 suites' guard fixtures now stub `mc_tick_fanout`, so their mutations still drop the only refusing clause.

Next slices, one concern each: the post-fan-out fleet sweeps (`mc_rereview_gc` to `mc_tick_clock_end`), then `tick_project` and `pr_worker`, which need an explicit change to the BH-685 premise.
