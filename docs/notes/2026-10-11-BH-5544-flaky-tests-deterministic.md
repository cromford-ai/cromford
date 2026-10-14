# Three flaky tests made deterministic (BH-5544)

Doc: TESTING

## What changed

- `tests/rules-pack.bh-3510-test.sh` R8 runs the full pack with
  `RULES_PACK_BUDGET_S=300`, so each component's timeout is 600 s
  (`bin/rules-pack.sh`: 2x the budget). R8 asserts that no component returned
  rc 124, and it names each one that did. It still asserts the budget fields
  agree with each other, and it never asserts the runner's speed. R16 still
  proves a hung component is cut off (`124 could-not-run` at a 2 s cap). The
  default budget of 60 stays pinned by R14b and by
  `tests/rules-pack-budget.bh-4220-test.sh` B3. `RP_R8_BUDGET_S` shrinks the
  R8 budget for a red-first check only.
- `tests/review-prs-parallel.bh-5284-test.sh`: the agent-call stub's barrier
  has no total time bound now. It waits while new calls keep starting, and it
  gives up only after `RPP_BARRIER_STALL_POLLS` polls of 0.1 s (default 600,
  at least 60 s) with no new start. A give-up writes
  `$T/log/barrier-gaveup` (`<n> of <want> started`), and later calls of the
  tick skip the barrier. R1 and R6 assert that the file is empty. R6 also
  reads the pool's own tick line: `running=12 started=12`.
- `tests/review-prs-parallel-slow.bh-5311-test.sh` S1 runs the BH-5284 suite
  at `RPP_GH_DELAY_S=0.6` (was 0.1): the load that turned the old barrier red.
- `bin/test-trace-safety.sh` starts every test, in both the `--gate` arm and
  the bare arm, through `env --default-signal=PIPE` (else a perl reset, the
  same pair as `bin/remote-gate.sh` `_rg_dfl_pipe`). A CI step starts with
  SIGPIPE ignored, a process inherits that through every exec, and bash cannot
  reset it. If neither GNU env nor perl exists and SIGPIPE is ignored at
  entry, the runner prints one `CHECK-NOTE` and starts tests unchanged.
  `tests/trace-safety-sigpipe.bh-5544-test.sh` (P0-P6) pins this.

## Evidence (measured 2026-10-11 on the build box, main cc75af7c)

- R6: `RPP_GH_DELAY_S=0.6` on main gave `FAIL: R6 peak in-flight=10 (want all
  12): 1 2 3 4 5 6 7 8 9 10 9 9`. The planner saw `peak 9` on its box. The
  30 s total barrier ran out while the pool's serial pre-gates still started
  workers. After the change: 35 passed, 0 failed at 0.6.
- R8: a full pack took 30 s on this box; the slowest component,
  `jobs-client-modules`, took 26 s (the planner measured 40 s on its box). At
  a 10 s cap, `alert-writers`, `jobs-client-modules` and `determinism` hit
  rc 124 and main's R8 went red on `could_not_run`. CI runs the suite traced
  and loaded, about 2x slower, so the old 120 s cap was in reach.
- SIGPIPE: `env --ignore-signal=PIPE bash -c 'yes 2>/dev/null | head -n1
  >/dev/null; echo ${PIPESTATUS[0]}'` prints `1` (EPIPE). With
  `env --default-signal=PIPE` in front of `bash` it prints `141`.

## Not done here

`bin/lib/suite-runner.sh` (`bin/test-suite-run.sh`), `bin/fast-lints.sh --run`
and `bin/rules-pack.sh` also start suites in CI steps, and they do not reset
SIGPIPE. The ticket names the shards only.
