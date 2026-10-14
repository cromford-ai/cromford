# Five sourced-lib kill switches read as settings rows (BH-2429, BH-2409.3)

Doc: CONFIG, VERIFICATION-MAP

Five libs now read their kill switch through `lane_switch <name> file`, so a settings row
`switch.<name>.<box>` or `switch.<name>` settles it before the file does:

| switch | lib | predicate | ON means |
|---|---|---|---|
| `pool-account-routing-off` | `bin/lib/pool-account.sh` | `pool_account_armed` | prints `kill_flag`, rc 1 |
| `pr-create-rest-fallback-off` | `bin/lib/gh-pr-create.sh` | `_gpc_fallback_on` | rc 1 |
| `pr-merge-rest-off` | `bin/lib/gh-pr-merge.sh` | `_gpm_on` | rc 1 |
| `pr-dep-gate-off` | `bin/lib/pr-dep-gate.sh` | `pdg_enabled` | rc 1 (`PR_DEP_GATE=0` still stops it first) |
| `resume-disabled` | `bin/lib/resume-dead.sh` | `resume_dead_pass` | `return 0` before the ledger read |

**A subshell, on purpose.** Each lib is sourced into lanes that may not have lane-gate loaded, and
the resolver pulls in `bin/jobs-client.sh` (and its `flag_active`). So each lib calls `lane_switch`
inside `( … )` with `HARNESS` set to the lib's own root, and nothing it loads reaches the caller.
Its output is discarded, so nothing but a reason reaches `pool_account_armed`'s stdout.

**It never fails open.** If `lane-switch.sh` (or the `lane-gate.sh` it needs) cannot be sourced from
beside the lib, the seam answers rc 2 and the lib runs its old file test, verbatim. With no row
written, `file` mode reads `[ -f flags/<name> ]` only, which is what these libs read before
(pr-dep-gate's rc 2 fallback keeps its `-e`).

**Nothing changes until a row is written.** Merging writes no row. `bin/fly-pool.sh` sources
`pool-account.sh`, so no `switch.pool-account-routing-off` row should be written until the
fly-pool conversion (BH-2409's C1) has merged.

Registered in `catalog/switches.d/`, one reader each. Verified by
`tests/switch-convert-libs.bh-2429-test.sh`.
