# The conductor's full-tick window lives in bin/lib/mc/tick-scope.sh (BH-6518)

Doc: MERGE-CONDUCTOR

BH-6518 slice C1 moved the second inline concern out of `bin/merge-conductor.sh`: the full-tick window (BH-5521). It reads `MC_FULL_TICK_BUDGET_S` and, on an unkeyed tick with no caller window, sets `MC_WORKERS_DONE_BY` and `MC_WINDOW_NEXT`.
The window is now `mc_full_tick_window` in `bin/lib/mc/tick-scope.sh`, below `mc_keyed_tick_parse`. Its body is the old driver lines, byte for byte. It uses no `local`, so `_mc_ftb`, `MC_WORKERS_DONE_BY` and `MC_WINDOW_NEXT` stay global, and `export -n` still clears the export attribute on the globals.
The driver calls it at the same place as before: directly after `mc_keyed_tick_parse`, because the window reads `MC_ONLY_KEYS`. The values, the readers (`mc_window_cap`, `mc_window_defer` in `bin/lib/fanin.sh`) and the `full tick: worker window …` log line did not change.

The C0 seam did not change. The guard now also requires `declare -F mc_full_tick_window`. A box with the C0 `tick-scope.sh` and the C1 driver refuses the tick with the same `CONDUCTOR MODULE MISSING` alert and `exit 1`. A box with the C1 `tick-scope.sh` and the C0 driver runs as before: the old driver keeps its inline block and never calls the function.

The knob `MC_FULL_TICK_BUDGET_S` in `catalog/lanes.d/merge-conductor.json` now carries `"read_in": "bin/lib/mc/tick-scope.sh"`, so `tests/lanes-registry-test.sh` and `tests/config-literal-lint.sh` look for it there. Its default (1500) and its settings row did not change.

`tests/mc-full-tick-window.bh-6518-test.sh` pins the window (eight cases), the real driver's unkeyed and keyed ticks, the new refusal path, and that the shim never defines the function.

Next slices, one concern each, same seam: C2 the flags/MODE block, C3 the budget and knob prelude, C4 the per-project loop, then the `tick_project` and `pr_worker` stages.
