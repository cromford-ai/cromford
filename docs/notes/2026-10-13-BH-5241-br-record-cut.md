# The resolver's record layer lives only in bin/lib/br/record.sh (BH-5241)

Doc: MODULE-MAP

BH-1176 put a byte-identical copy of the record layer in `bin/lib/br/record.sh` and left the inline copy in `bin/blocked-resolver.sh`. The inline copy won.
BH-5241 slice C1 deleted the inline record block (364 lines, 23 column-0 definitions of 22 names) from the driver. `record.sh` now holds that block byte for byte.
`record.sh` gained 9 functions that only the driver held: `br_rows_count`, `br_cap_rows`, `br_row_closed`, `br_set_flag`, `br_push_field`, `br_has_field_value`, `br_shape`, `br_fix_cap`, `br_rebuild_cap`. It is now the only definition of all 22 and is load-bearing.
`tests/br/expected-map.tsv` has no `lib` row left: the 13 old record rows are `mod`, and the 9 new names are 9 new `mod` rows.
`tests/br/driver-ceiling.tsv` caps the driver at 9755 lines (9605 plus 150) and 159 column-0 `br_*` definitions.
`tests/br-split-layout.bh-5241-test.sh` B7 checks that a real driver tick sources `record.sh`, and that `br_shape` and `br_fix_cap` answer through it.
12 suites that extracted record functions from the driver text now read `tests/lib/br-corpus.sh`. `tests/blocked-resolver-dequeue-brief.bh-3719-test.sh` also builds origin/main's side from origin/main's corpus, so it stays green after this merges.
The indented `br_event` override in the driver's main loop is out of scope and did not change.
