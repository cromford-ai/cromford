# BH-9288: an out-of-memory stop names its cause, and the execute stage kills what its session left alive

Doc: RUN-BUILD

## Cause

On 2026-11-09 project-6-os TK-3659 started two vitest suites in the background
and then ran `NODE_OPTIONS=--max-old-space-size=8192 npm run typecheck`. The
machine ran out of memory and the typecheck was killed (exit 137) twice.
`ee_on_empty` (`bin/lib/execute-empty.sh`) always wrote "Raise the row
lane.fly-pool.<project>.vm_memory_mb". The memory went to the concurrent
processes, and nothing killed the vitest workers after the session.

## What changed

- `bin/exec-proc-hook.sh` (new): a PostToolUse / PostToolUseFailure Bash hook
  for stage execute. On an out-of-memory result it writes
  `<build-dir>/oom-procs.txt` (the processes alive, largest RSS first, scrubbed).
  Then, on an OOM or a timed-out call, it kills orphaned test runners of the
  session (vitest, jest, tsc, playwright). The snapshot always comes first.
- `bin/lib/exec-procs.sh` (new): `ep_snapshot`, `ep_oom_cause` (concurrent /
  single / no-snapshot / unknown) and `ep_reap` (kills process groups of the
  processes that carry `HARNESS_EXEC_TAG=<tag>`; never a group that holds the
  reaper or its ancestors).
- `bin/lib/execute-empty.sh`: the EXECUTE_OOM stop reason and alert take their
  advice from `ep_oom_cause`. Only "one process used most of the memory" says
  "Raise the row".
- `bin/lib/rb/execute.sh`: sets `EXEC_PROC_TAG` / `EXEC_PROC_DIR` before the
  first execute call (one tag per build). It removes `oom-procs.txt` before
  each `CC execute` (the first call and each BH-9123 relaunch) and calls
  `ep_reap` after each `CKPT_STOP` that follows one. `EX_RC=$?` stays the
  first line of the execute result block.
- `bin/agent-call.sh`: for stage execute with `EXEC_PROC_TAG`, puts
  `HARNESS_EXEC_TAG` on the claude line and adds the hook settings. The settings
  merge now concatenates the arrays under `.hooks.<Event>`. Before, a second
  PostToolUse file replaced the edit-feedback hook.
- Knobs `lib.exec-procs.*` (`catalog/lanes.d/_lib.exec-procs.json`):
  EXEC_PROC_REAP (1), EXEC_PROC_REAP_GRACE_S (5), EXEC_OOM_HEAVY_RSS_MB (200),
  EXEC_OOM_SINGLE_PCT (50), EXEC_OOM_SNAPSHOT_ROWS (15).
- Fleet rule `rules/topics/17-build-resources.md`: no backgrounded test suites
  in execute, one heavy check at a time.

## Test

`tests/execute-oom-classifier.bh-9288-test.sh`.
