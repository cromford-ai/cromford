# The conductor's tick prelude lives in bin/lib/mc/tick-scope.sh (BH-6518)

Doc: MERGE-CONDUCTOR

BH-6518 slice C3 moved the fourth inline concern out of `bin/merge-conductor.sh`: the tick prelude. It sets the spend budgets (`REBASE_BUDGET`, `REREVIEW_BUDGET`, `MERGE_BUDGET`), the isInMergeQueue knobs (`MC_LIST_INQUEUE`, `MC_INQUEUE_PROBE_TTL_SECS`, `MC_INQUEUE_STATES`), `REREVIEW_CAP` and the day's `CAPFILE`, the exports the detached lanes re-read, and the exported `MC_TICK_ID`.
The block is now `mc_tick_prelude` in `bin/lib/mc/tick-scope.sh`, below `mc_tick_mode`. Its body is the old driver lines, byte for byte, with their comments. It uses no `local`, so every value stays global, and each `export` still exports the global.

The driver calls `mc_tick_prelude` at the old place: after `mc_init` (it reads `MC_STATE_DIR`) and `hb_start`, and before `use_token`. The guard now also requires `declare -F mc_tick_prelude`. A box with the C2 `tick-scope.sh` and the C3 driver refuses the tick with the same `CONDUCTOR MODULE MISSING` alert and `exit 1`. A box with the C3 `tick-scope.sh` and the C2 driver runs as before: the old driver keeps its inline block and never calls the function.

`use_token` and `reset_token` did not move. BH-685 keeps them in the driver (`tests/mc/driver-complete-test.sh`), and `tests/gh-budget-rest-test.sh`, `tests/gh-token-test.sh` and `tests/gh-default-identity-test.sh` read them from the driver source by name.

Six knobs in `catalog/lanes.d/merge-conductor.json` gained a `read_in`, because the driver no longer names them: `MC_MERGE_BUDGET`, `MC_REBASE_BUDGET`, `MC_REREVIEW_BUDGET` and `MC_REREVIEW_DAILY_CAP` point at `bin/lib/mc/tick-scope.sh`; `MC_REBASE_TIMEOUT_SECS` and `MC_REREVIEW_TIMEOUT_SECS` point at `bin/lib/mc/log.sh`, where their defaults are set. No value, default or settings row changed.

`tests/mc-tick-prelude.bh-6518-test.sh` pins the defaults, the env overrides, the export attributes, the real driver's cap file, the new refusal path, and that the shim never defines the function. The C1 and C2 suites' D3 fixtures now stub `mc_tick_prelude`, so their mutations still drop the only refusing clause.

Next slices, one concern each, same seam: C4 the per-project loop, then the `tick_project` and `pr_worker` stages.
