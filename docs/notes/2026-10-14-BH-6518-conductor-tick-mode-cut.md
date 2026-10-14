# The conductor's flags/MODE block lives in bin/lib/mc/tick-scope.sh (BH-6518)

Doc: MERGE-CONDUCTOR

BH-6518 slice C2 moved the third inline concern out of `bin/merge-conductor.sh`: the flags/MODE block (BH-1201, BH-1672). It reads the four fleet flags through `flag_on` and the fleet merges pause through `pause_active`. It sets `KILL`, `ACTIONS`, `MERGES`, `MODE` and the exported `MC_MODE`.
The block is now `mc_tick_mode` in `bin/lib/mc/tick-scope.sh`, below `mc_full_tick_window`. Its body is the old driver lines, byte for byte. It uses no `local`, so the five values stay global, and `export MC_MODE` still exports the global.

`flag_on` did not move. BH-685 keeps it in the driver (`tests/mc/driver-complete-test.sh`). `mc_tick_mode` calls it by name at run time, so the driver calls `mc_tick_mode` at the old place, directly after the `flag_on` definition. The values, their readers (`tick_project`, `pr_worker`, `mc_hold_mode` and `mc_hold_tick_end` in `bin/lib/mc/log.sh`) and the two log lines (`merge flag set without the actions flag …`, `PAUSED(merges) fleet …`) did not change.

The guard now also requires `declare -F mc_tick_mode`. A box with the C1 `tick-scope.sh` and the C2 driver refuses the tick with the same `CONDUCTOR MODULE MISSING` alert and `exit 1`. A box with the C2 `tick-scope.sh` and the C1 driver runs as before: the old driver keeps its inline block and never calls the function.

The project-level MERGES/MODE lowering in `tick_project` did not move. It belongs to the `tick_project` slice.

`tests/mc-tick-mode.bh-6518-test.sh` pins the mode (ten cases, with the export attributes), the real driver's merge-without-actions refusal and its no-flag tick, the new refusal path, and that the shim never defines the function. `tests/mc-full-tick-window.bh-6518-test.sh` D3 now stubs `mc_tick_mode`, so its mutation still drops the only refusing clause.

Next slices, one concern each, same seam: C3 the budget and knob prelude, C4 the per-project loop, then the `tick_project` and `pr_worker` stages.
