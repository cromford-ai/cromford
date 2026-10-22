# The conductor's main-red detector call and fleet sweeps live in bin/lib/mc/tick-scope.sh (BH-7879)

Doc: MERGE-CONDUCTOR

BH-7879 (slice C5 of BH-6518) moved the last two inline blocks out of the top level of `bin/merge-conductor.sh`:

- `mc_tick_main_red`: the BH-636 main-red detector call and the BH-6890 fleet-sweeps decision. It sets `MC_FLEET_SWEEPS` to 1, or to 0 on a keyed tick (`MC_ONLY_KEYS`) or a one-project tick (`MC_ONLY_PROJECT`). On a fleet-sweep tick with `MC_MAIN_RED_DETECT` not 0 it runs `bin/main-red-detector.sh` once under `locks/main-red-detect-tick.lock`.
- `mc_tick_sweeps`: the 14 housekeeping calls from `mc_rereview_gc` to `mc_dv_reap`, in the same order.

Both are in `bin/lib/mc/tick-scope.sh`, below `mc_tick_fanout`, between `# >>> fleet sweeps (BH-7879)` markers. Their bodies are the old driver lines, byte for byte, with their comments. Neither uses `local`, so `MC_FLEET_SWEEPS` stays a global: the driver's keyed exit and `mc_tick_fanout` read it.

The driver calls `mc_tick_main_red` at the old place, before the parent `GH_ETAG_COUNT_FILE` export, and `mc_tick_sweeps` after the keyed early exit. The tick end stays in the driver: `gh_rest_etag_report merge-conductor`, `mc_hold_tick_end`, `mc_tick_clock_end`, `hb_done` and `exit 0`. `tests/hub-overload-queue.bh-7139-test.sh` pins `mc_tick_clock_end` in the driver source.

The guard now also requires `declare -F mc_tick_main_red` and `declare -F mc_tick_sweeps`. A box with the C4 `tick-scope.sh` and this driver refuses the tick with the same `CONDUCTOR MODULE MISSING` alert and `exit 1`, before any GitHub read. A box with this `tick-scope.sh` and the C4 driver runs as before: the old driver keeps its inline blocks and never calls the new functions.

The detector's lock-held `exit 0` is inside its subshell, so it still ends that subshell only. Both functions can return non-zero (the last `if`, or `mc_dv_reap`). The driver has no `set -e`, so that value is ignored, as the old top-level lines were.

Two knobs gained a `read_in` of `bin/lib/mc/tick-scope.sh`, because the driver no longer names them: `MC_MAIN_RED_DETECT` (`catalog/lanes.d/merge-conductor.json`) and `MC_ONLY_PROJECT` (`catalog/lanes.d/merge-conductor.knobs.d/MC_ONLY_PROJECT.json`). No value, default, log line, lock path or settings row changed.

`tests/mc-tick-sweeps.bh-7879-test.sh` pins the six fleet-sweeps decision cases, the detector call and its skips, the order of the 14 sweeps, the real driver's detector call before the first project line, the stale per-tick counter file that `mc_tick_gc` removes, a keyed and a one-project tick that run neither, the new refusal paths, and that the shim never defines either function. The C1 to C4 suites' guard fixtures now stub both functions, so their mutations still drop the only refusing clause.

After this slice the driver's top level is the lib sourcing, `mc_init`, and one call line per tick stage. The only functions the driver defines are the five BH-685 KEPT names (`flag_on use_token reset_token pr_worker tick_project`, `tests/mc/driver-complete-test.sh`). That is BH-685's definition of a driver, so this is the last slice of BH-7879. A move of `tick_project` or `pr_worker` needs a new ticket that changes the BH-685 premise.
