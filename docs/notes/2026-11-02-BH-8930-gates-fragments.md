# BH-8930: gate fragments for bin/lib/rb/gates.sh (slice C0)

## What changed
- A gate in `bin/lib/rb/gates.sh` can live in its own file, `bin/lib/rb/gates.d/<slug>.sh`.
  The file holds a short header and then the verbatim marked block (`# >>> name` to `# <<< name`).
- The call site is one column-0 line in place of the block: `. "$RB_GATES_D/<slug>.sh"`.
  The `.` runs in the stage function's own scope. A fragment holds no `local`, `return` or `declare`.
- `rb_gates_d_check` is the first statement of `rb_gate_prelude`. It sets `RB_GATES_D` and
  reads the call sites off `gates.sh`. If a named fragment is missing, the build answers
  `BUILD_DEFERRED gates.d/<slug>.sh missing on <host>` with exit 3, before any claim or lock.
  It also fires one critical lane-alert with id `rb-gates-d-missing-<host>`.
- `tests/lib/rb-all.sh` replaces each call line with the fragment's block. A missing or
  unclosed fragment makes `rb_all` return 1 with no output file.
- Moved in this slice: `hotfix detect` (`gates.d/hotfix-detect.sh`) and `disk gate`
  (`gates.d/disk-gate.sh`). No suite reads these two blocks raw.

## Why
BH-7876 and BH-7921 both edited `gates.sh` and both collided. A gate in its own file is one
file per ticket. The call sites are the list, so there is no registry file to append to.

## Rule for later tickets
- To edit a moved gate: edit its fragment only.
- To add a gate: add a fragment and one call line.
- To move a gate: cut the block verbatim into its fragment and leave the call line. Re-point
  every suite that reads that block raw from `gates.sh` in the same PR.

## Known difference
The `rb_all` flatten of the pipeline differs from main's by exactly one line:
`rb_gates_d_check || exit 3` at the top of `rb_gate_prelude`.

## Verify
`HARNESS_TEST_SANDBOX=1 bash tests/rb-gates-fragments.bh-8930-test.sh`
