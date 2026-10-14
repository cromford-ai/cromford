# The resolver's build-record discovery sources live only in bin/lib/br/discovery.sh (BH-6517)

Doc: MODULE-MAP

BH-6517 slice C0 moved the build-record discovery sources out of `bin/blocked-resolver.sh` into a new module, `bin/lib/br/discovery.sh`, byte for byte.
The 6 functions are `br_from_queue`, `br_from_builds`, `br_rebuild_outcome`, `br_rebuild_artifact`, `br_from_rebuilds` and `br_candidates`. `discovery.sh` is the only definition of each and is load-bearing.
`br_candidates` still calls `br_from_conductor` and `br_from_reviews` in the driver. The rebuild rung in the driver still calls `br_rebuild_artifact`. Every call happens at run time, after the driver has sourced the modules.
`BR_MODULES` is `"discovery keys ladder record"`, and `bin/lib/br/MODULES` is regenerated in the same order. A box with the new driver and no `discovery.sh` refuses the tick with one `RESOLVER MODULE MISSING: bin/lib/br/discovery.sh` line.
`tests/br/expected-map.tsv` has 6 new `mod` rows. `tests/br/driver-ceiling.tsv` caps the driver at 9055 lines (8905 plus 150) and 144 column-0 `br_*` definitions.
`tests/br-split-layout.bh-6517-test.sh` (D1-D6) pins the move, the `br_candidates` order, the refusal, the `opt/` overlap report and, with `BR_SPLIT_BASE`, that only the 6 sources left the driver.
5 suites that extracted a moved function from the driver text now read `tests/lib/br-corpus.sh`. Their assertions and counts did not change.
K6 of `tests/br-split-layout.bh-6461-test.sh` now leaves out the names a later top-level module defines, so it still pins the key family after this move.
The conductor hand-off sources (`br_prov_promote`, `br_unmapped`, `br_conductor_emit`, `br_handoff_rows`, `br_handoff_lines`, `br_rereview_inflight`, `br_from_conductor`) did not move. They are C1 of BH-6517. The `br_from_reviews` block is a separate "reviews" slice.
