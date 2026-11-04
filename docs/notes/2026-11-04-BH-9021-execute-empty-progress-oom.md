# BH-9021: the EXECUTE_EMPTY cap counts only attempts that did not move the branch; a resumed rule=time stop opens the PR; an OOM stop says EXECUTE_OOM

Doc: FLY-POOL

## Why

project-6-os, 2026-11-03. TK-3552 attempt 1 pushed 6 checkpoint commits and
was stopped by the no-progress rule. Attempt 2 resumed them, found the work
done and was stopped by `rule=time`. Both ended `EXECUTE_EMPTY`, so the pool's
cap of 2 held the key NEEDS_HUMAN, and the finished tree on `ticket/TK-3552`
never reached a PR. TK-3552 and TK-3575 also ran `npm run typecheck` and
`npm test` into an out-of-memory kill, and the stop reason said only "no file
changed".

## What changed

1. `bin/lib/rb/execute.sh` records the branch head before the execute session
   (`EE_HEAD_START`) and the head origin holds after the last checkpoint push
   (`refs/remotes/origin/$BRANCH`, moved only by a push that landed). The
   `EXECUTE_EMPTY EXECUTE_NO_PROGRESS: ...` and checkpoint-only RESULT lines end
   with ` [branch-head start=<sha|-> end=<sha|->]`. `EXECUTE_EMPTY no changes
   produced` is unchanged. The first word stays `EXECUTE_EMPTY` for every reader.
2. `ee_stop_check` (`bin/lib/execute-empty.sh`) does not count a record whose
   RESULT line 1 carries that token with two different hex shas. A `-`, a
   malformed token or no token (records from before this change) is counted.
3. A resumed build (`CKPT_START_POINT` set or `CKPT_WIP_N` > 0) stopped by
   `rule=time` whose diff to base is not empty is a normal execute result: one
   pipeline.log line, then the squash (`<KEY>: work recovered from N lane
   checkpoint(s)` for an all-wip branch) and the gates. `rule=ceiling`, a build
   that did not resume, and an empty diff still end `EXECUTE_EMPTY`.
4. `ee_on_empty` runs `ee_oom` over the rendered transcript. When the result of
   the newest typecheck or test command holds `FatalProcessOutOfMemory`,
   `heap out of memory`, `Mark-Compact` or `Exit code 137`, stop-reason.txt
   starts `EXECUTE_OOM: <command> ran out of memory (<signal>) on a machine
   with <N|unknown> MB (VM_MEMORY_MB). Raise the row
   lane.fly-pool.<project>.vm_memory_mb.` and one `bin/alert-line.sh` line
   (`--id execute-oom:<project>:<key>`) says the same. `<build>/oom.alerted`
   keeps it to one alert per build dir. The memory is `VM_MEMORY_MB`, else
   `MemTotal` of `/proc/meminfo` (a pool machine does not get the env var).

No knob, no table, no change to `bin/fly-pool.sh` (sibling PR #8910).

## Evidence

- `tests/execute-empty.bh-9021-test.sh` (cases A, B, C, D, Z).
