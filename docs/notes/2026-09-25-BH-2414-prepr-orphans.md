# The pre-PR gate runs CI's orphan ratchet

Doc: RUN-BUILD-GRAPH

## What was wrong

On 2026-09-25 three pool PRs opened with CI red for the same reason. #2382 (BH-2331), #2388 (BH-2323) and #2402 (BH-2328) each added two console-ui files that only a node test imported, by a relative path. `bin/test-impact.sh orphans --check` wants the path named in a `tests/*.sh` suite, so CI failed with `adds 2 orphan script(s)`. The builder's pre-PR gate (BH-1706) runs `bin/checks-run.sh --tree .` and `bin/test-determinism-lint.sh`, but never the ratchet, so it passed all three.

## What it does now

`prepr_scan` in `bin/lib/prepr-gate.sh` also runs `bin/test-impact.sh orphans --check`, the command CI runs, from the worktree root. `TI_BASE` is the build's merge-base with `<base>`. CI sets `TI_BASE` to the PR's base sha on the merge ref, and the merge-base is the local equivalent. It is also the base the gate already lists the build's files from.

- Each new orphan is an `ORPHAN <path> <reason>` finding, and so is a committed `catalog/test-impact-orphans.txt`. An ORPHAN finding is always the build's own, because the ratchet only reports orphans that are new against the base.
- The findings take the existing path: one fix turn (`RB_PREPR_FIX_TURNS`) with the lines verbatim and the rooted-path rule in the brief, then a re-scan, then `fixed` or `red`.
- A ratchet that exits 2 or more, times out (600 s), or reports rc 1 with nothing parseable makes the scan `could-not-run`.
- A repo without `bin/test-impact.sh` skips the ratchet alone.
- The late pass (BH-2021) goes through the same scan, so it runs the ratchet too.

`prompts/build-discipline.md` D41 gives the builder the rule up front: every new source file, console-ui included, must be named by rooted path in a `tests/*.sh` suite, following `tests/cost-breaker-console.bh-2331-test.sh`.

Suite: `tests/rb-prepr-orphans.bh-2414-test.sh`.
