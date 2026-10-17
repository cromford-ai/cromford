# BH-7262: product stage on for seven projects, and a per-run USD cap

Doc: COST

## What changed

- Four new context files: `prompts/product-project-6-os.md`,
  `product-project-5.md`, `product-project-9.md` and
  `product-project-8.md`. Their facts come from the harness triage
  prompts and fleet.conf. Where those are silent, the file tells the stage
  session to read the repo CLAUDE.md at run time. The project-6 repo was not
  readable from the build box (HTTP 403).
- `catalog/lanes.d/run-product.json`: `.boxes` adds `project-6-os`, `project-9`,
  `small` and `project-5`. `cadence` lists the seven offsets in use.
- New knob `PRODUCT_RUN_USD_CAP` (float, default 0 = unlimited), in its own
  file `catalog/lanes.d/run-product.knobs.d/PRODUCT_RUN_USD_CAP.json`.
- `bin/lib/product-run-cap.sh`: `product_run_cap_check <stage>` replaces the
  placeholder. It sums this run's product-stage rows in `logs/cost.csv` for
  this project. At or over the cap it writes one project log line and one
  ALERTS line (through `bin/alert-line.sh`) and returns 1, and `cap_stop`
  ends the cycle with rc 0.

## Why

Parent BH-7244 turns the PM agent on across the fleet. The cap bounds what one
weekly cycle can spend, on top of the per-day `LLM_USD_CAP_DAY`.

## Not changed

- `stats.cost_stage` does not get `pm`. The lane-stage ratchet
  (`tests/lib/lane-stage-check.py`) requires the registered set to equal the
  stages the lane's script calls, and no run-product call site uses `pm` yet.
  The cap already counts `pm` rows.
- `bin/run-product.sh` is unchanged.

## How to check

`HARNESS_TEST_SANDBOX=1 bash tests/product-fleet-enable.bh-7244-test.sh`
