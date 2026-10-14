# The resolver's ladder lives only in bin/lib/br/ladder.sh (BH-5241)

Doc: MODULE-MAP

BH-1176 put a byte-identical copy of the ladder classifier in `bin/lib/br/ladder.sh` and left the inline copy in `bin/blocked-resolver.sh`. The inline copy won.
BH-5241 deleted the inline copy (7 functions, 229 lines) and moved `br_regen_rung` (119 lines) into `ladder.sh` byte for byte. `ladder.sh` is now the only definition of those 8 functions.
`bin/lib/br/ladder.sh` and `bin/lib/br/record.sh` carry `# module:` headers, and `bin/lib/br/MODULES` is generated. The driver keeps its literal `BR_MODULES` loop and its refusal.
`tests/br/driver-ceiling.tsv` caps the driver at 10077 lines and 182 column-0 `br_*` definitions. Each later slice lowers both rows.
`tests/br-split-layout.bh-5241-test.sh` checks one module per `br_*`, no top-level/`opt/` overlap, the ceiling, and `BR_MODULES` == `MODULES`. With `BR_SPLIT_BASE=<rev>` it proves the move is pure: the set of `br_*` bodies is unchanged.
Suites that extract a `br_*` function by name now read `tests/lib/br-corpus.sh` (the driver plus the modules), not the driver alone.
