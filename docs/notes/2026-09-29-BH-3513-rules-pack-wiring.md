# The rules pack runs in the pre-push gate, HARNESS_SUITE_RUN and the evidence table

Doc: RUN-BUILD-GRAPH

## What changed

BH-3509 shipped the `bin/rules-pack.sh` contract and the `RULES_PACK_BLOCK` / `RULES_PACK_BUDGET_S` fly-pool knobs, with nothing calling it. BH-3513 (BH-3477.4) wires it in at three places.

- **Pre-push gate** (`prepr_scan` in `bin/lib/prepr-gate.sh`). After the orphan ratchet, the scan runs `bin/rules-pack.sh --tree . --base <base> --skip checks-tree,determinism --out <out>/rules-pack` under `timeout` of 3x `RULES_PACK_BUDGET_S`. Each stdout line is an in-diff `RULES-PACK <id>: <line>` finding. It takes the one existing fix turn, and the brief gets one extra bullet. rc 1 with no line, 2, 124, 125 or anything else is `rules-pack: could not run` in `prepr-scan.txt` and does not change the scan's rc. No executable pack is `rules-pack: skipped`.
- **`PREPR_PACK_STATE`** (`clean|red|could-not-run|skipped`) is written as `pack=` in `prepr.txt` and at the end of the `PREPR state=` line. It is `red` when a RULES-PACK line survives the fix turn, when the turn edited a pack rules path (the pack, its catalog, a ratchet baseline), or when a pack that was red could not re-run. The late pass keeps the first pass's value when its own pack could not run.
- **The block.** `rules_pack_block` runs at `# >>> rules pack block` in `bin/lib/rb/execute.sh` (after the push, before any reviewer) and in `bin/lib/rb/pr.sh` (after the late pass, before PR create). With a red pack and `RULES_PACK_BLOCK` 1 or unresolved, it writes `$BUILD/rules-pack-block.txt`, sends one alert through `bin/alert-line.sh`, calls `escalate_block rules-pack`, sets RESULT `REVIEW_BLOCKED rules-pack: ...` and exits 6. `RULES_PACK_BLOCK=0` logs one line and the PR opens with the "Pre-PR gate: unresolved" section.
- **HARNESS_SUITE_RUN** (`HARNESS_IMPACT_GATE_RUN` in `bin/lib/rb/gates.sh`). The full pack runs first, outside the gate's 1500 s timeout, and writes `RULES_PACK: <state> (rc N, Es of Bs)` plus up to 40 findings to the suite record. When it ran, its `suites.txt` goes to the gate as `bin/test-impact-gate.sh --skip-suites`. Those suites print `plan: <suite>  run by the rules pack (outside the cap)` and count neither against the cap nor as left to CI. A red pack turns a gate rc 0 into `HARNESS_EXIT: 1`. could-not-run never changes the rc.
- **Evidence table** (`bin/evidence-summary.sh`, text mode only). One `rules pack (bin/rules-pack.sh)` row from the first `summary.json` found under `prepr-late/rules-pack/`, `rules-pack/` or `rules-pack-lenses/`. The state comes from prepr's `pack=` when recorded. No summary means no row, and `--json` is unchanged.

## State on main today

The pack on main is still the BH-3509 stub, which answers 125 and writes no summary. So every build reads `pack=could-not-run`, nothing blocks, no suites are skipped, and there is no evidence row until the BH-3510 engine lands.

Suite: `tests/rb-prepr-rules-pack.bh-3513-test.sh`. Contract: `tests/rules-pack-contract.bh-3509-test.sh`.
