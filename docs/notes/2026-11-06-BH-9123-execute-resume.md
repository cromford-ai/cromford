# Execute resumes from its checkpoint and parks at the cap (BH-9123, slice C1 of BH-9064)

Doc: CHECKPOINTS

## Why

Execute rc 124 (timeout) cost $454 and rc 143 (killed) $376 in the week to
2026-11-04, and a repeat after a timeout started a fresh execute from the plan.
This is the port of r3 (branch `ticket/bh-9064-r3`, commits f066f776f to
a9b993959) onto the C0 ledger that #9111 merged.

## What changed

- `bin/lib/execute-checkpoint-brief.sh` (new): `ecb_write <build> [branch]
  [base]` writes `$BUILD/checkpoint-brief.md` (the last commit, the diff stat
  against the base, the plan's acceptance items and which of them no commit or
  changed test names yet). `ecb_record` puts `<branch>@<sha12> session=<sid>` on
  the C0 ledger row (a checkpoint-only finish); `ecb_park` settles it `parked`.
  The one-argument `ecb_write "$build"` makes no network call (C2 calls it from
  the context meter before a declared kill).
- `bin/lib/rb/execute.sh`, after `CC execute`: on rc 124 or 143, or a
  `.ctxkill` (not rc 0, 1, 74 or 75, never on `.noprogress`), it pushes the wip
  checkpoint, writes the brief, records the checkpoint and runs `CC execute`
  again with `prompts/stages/execute-resume.md` (the brief inside it). It passes
  `LADDER_RESUME_SID=<session>` when that transcript file is on this box, so the
  claude session is resumed. After a `.ctxkill` it never resumes: the resumed
  transcript carries the context that was killed. The brief goes to a fresh
  session. At most `AGENT_LEDGER_MAX_ATTEMPTS` (3) execute calls per build.
- When the next call is refused as terminal, the row is parked and the build
  writes `RESULT "EXECUTE_EMPTY parked: attempts=<n> fp=<fp>
  checkpoint=<branch>@<sha12>"` and exits 3. Terminal is `ledger-failed` or
  `ledger-parked`, or a K3 `call-guard repeat execute paid=N/M` refusal inside a
  checkpoint chain (a relaunch in this build, or a build that started from a
  ledger checkpoint). K3 runs before the ledger on main, and its execute
  ceiling is 3, so the fourth call of one fp is refused by K3 first. Outside a
  chain a K3 refusal stays the BH-2305 `BUILD_DEFERRED`. A `ledger-running`
  refusal stays `BUILD_DEFERRED`. The first word stays EXECUTE_EMPTY, so
  `bin/fly-pool.sh` `ee_stop_check` and the other RESULT readers route it as
  before.
- A new build of the same ticket on the same build fp whose ledger row has a
  checkpoint starts from the resume prompt and the brief, not the plan prompt.
- `bin/agent-call.sh` keeps a `LADDER_RESUME_SID` it is handed for the first
  attempt only (`export -n`, then cleared after the first `run_attempt`), so a
  ladder retry on another rung never resumes the handed-in session.
- `bin/lib/stage-prompt.sh` knows the kind `execute-resume`.
- Knobs: `catalog/lanes.d/_lib.execute-checkpoint-brief.json`
  (`EXECUTE_BRIEF_STAT_LINES` 80, `EXECUTE_BRIEF_ITEMS_MAX` 60); the attempt cap
  is the ledger's `AGENT_LEDGER_MAX_ATTEMPTS`.

## Neighbors

- Three execute calls can take three times `EXECUTE_TIMEOUT_SECS`. The lane
  reaper deadline is not changed here.
- Without the lib on a box, the execute stage runs as before.

## Test

`tests/execute-resume.bh-9123-test.sh` drives the real `execute prompt` and
`execute result` blocks, the real `bin/agent-call.sh` (fake claude on PATH) and
the real jobs worker on node:sqlite, with K3 on its default map.
