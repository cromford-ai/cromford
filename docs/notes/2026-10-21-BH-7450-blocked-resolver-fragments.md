# BH-7450: new optional resolver code goes to bin/blocked-resolver.d/

Doc: CONFLICT_HOTSPOTS

What changed:

- `bin/blocked-resolver.sh` sources every regular `bin/blocked-resolver.d/*.sh`
  once, in `LC_ALL=C` name order. The block is directly after the optional
  module loop and before `# THE DISPATCHER STOPS HERE (BH-5913)`.
- The block is fail-open, like the optional loop. A fragment that does not
  parse, or whose source returns non-zero, is one `say` line. The tick goes on.
- `BR_OPT_OFF` also skips a fragment. The comma item is the fragment file
  name without `.sh`.
- `catalog/list-files.tsv` has a row for `bin/blocked-resolver.sh`.
  `bin/list-file-lint.sh` refuses a PR that grows the driver with no new file
  under `bin/blocked-resolver.d/`.
- The PR ships zero fragments. The 13 `BR_OPT_MODULES` modules, their list and
  the top-of-file lib source lines stay where they are.

Why: the driver had 18 replayed conflicts in 30 days. Each new optional rung
appended one word to the `BR_OPT_MODULES` line and one comment pair above it.
Two builds that each add a fragment file now merge with no conflict.

Line ceiling: the driver is at its `tests/br/driver-ceiling.tsv` ceiling
(9055 lines). The edit is net 0 lines. The 9 per-module comment lines above
`BR_OPT_MODULES` moved out; the line above the list now points to
`bin/lib/br/opt/README.md`, which documents each of the 13 modules.

How to add a fragment:

1. Add `bin/blocked-resolver.d/<key>-<name>.sh` (for example
   `bh-7612-foo-rung.sh`). Define functions only.
2. Add one call site in the driver:
   `command -v br_x >/dev/null 2>&1 && br_x ...`.
3. Run `HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-frags.bh-7450-test.sh`.
   Its checker refuses a bad name, a syntax error, a name the driver or
   `bin/lib/br/` already defines, and one name in two fragments.
