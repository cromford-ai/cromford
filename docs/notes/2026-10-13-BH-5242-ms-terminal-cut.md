# The sweep's terminal-cache helpers live only in bin/lib/ms/terminal.sh (BH-5242)

Doc: MODULE-MAP

BH-5242 slice C0 created `bin/lib/ms/`, the module directory of `bin/merge-sweep.sh`, in the shape of `bin/lib/mc/`: `load.sh` (the bootstrap), `module-map.sh` (a symlink to `../module-map.sh`) and the generated `MODULES`.
It moved one concern: `sweep_record_fp`, `sweep_terminal` and `sweep_relog_line` (the terminal-skip cache helpers, BH-710) moved byte for byte into `bin/lib/ms/terminal.sh`. The driver has no inline copy.
The cache state (`TERM_CACHE`, `NOW`, `_TERM` and its load loop) stays in the driver, because `mm_load` sources at function scope.
The driver loads `bin/lib/ms/` in the new `# >>> sweep modules` block, after the lane gate and before the lock and any GitHub call. If the load fails, the tick exits 1, writes `refusing the tick` to `logs/merge-sweep.log` and one `SWEEP MODULE MISSING` line to `logs/ALERTS.log`.
The driver has 18 column-0 function definitions (was 21). `tests/ms/driver-ceiling.tsv` caps it, and `tests/ms/expected-map.tsv` maps the three names to `terminal`.
`tests/ms-split-layout.bh-5242-test.sh` holds the layout and drives a real tick. 29 suites that copy the sweep alone into a scratch `bin/` gained one line that copies `bin/lib/ms/` beside it. No assertion changed.
`catalog/pr-self-check.tsv` row `body-d1` lists `bin/lib/ms/*`, so a PR that edits sweep logic in a module still gets the kill-knob call-out.
