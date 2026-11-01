# an execute session that changes no file is stopped early, and keeps its transcript (BH-8868)

Doc: CHECKPOINTS

## Why

project-6-os TK-3225: the execute session ran 3510 s and read 54.2M context
tokens with 0 file changes. Only the context kill at its 53.6M ceiling stopped
it. Its `execute-transcript.md` held only the final output and said "no claude
session file was found for this attempt". A killed session writes no CLI
envelope, so `ee_transcript` had no session id. The account also set
`CLAUDE_CONFIG_DIR`, so `$HOME/.claude/projects` had no session file.

## What changed

- `bin/lib/execute-no-progress.sh` (new): the worktree fingerprint
  (`np_snapshot`) and the stop rule (`np_decide`).
- `bin/agent-call.sh`: for stage `execute`, `run_attempt` takes the fingerprint
  before the CLI starts. The context meter compares it on every poll. With no
  change, the meter stops the session after `EXECUTE_NO_WRITE_STOP_MIN`
  minutes (default 20) or at `EXECUTE_NO_WRITE_STOP_CEILING_PCT` % of the
  ceiling (default 50). It writes `$OUT.noprogress` before the TERM.
  The stop is a policy stop: rc 143, a `NO PROGRESS:` line on `$OUT`, no model
  escalation, no vendor failover, cost note `no-progress:rule=..:elapsed_s=..`,
  row_source `killed`.
- `bin/lib/rb/execute.sh`: on the marker the build ends
  `EXECUTE_EMPTY EXECUTE_NO_PROGRESS: <rule> after <n>s, ...` (exit 5). The
  first word stays `EXECUTE_EMPTY`, so every RESULT reader and the pool's
  relaunch cap count it as before.
- `bin/lib/execute-empty.sh`: `ee_transcript` reads `$OUT.session`
  (`<sid>\t<config dir>`), and searches `<config dir>/projects` first.
- Knobs: `catalog/lanes.d/_lib.execute-no-progress.json`, settings rows
  `lib.execute-no-progress.execute_no_write_stop_min` and
  `lib.execute-no-progress.execute_no_write_stop_ceiling_pct`. 0 turns a rule off.

## Not in this change

Fix 3 of the ticket (split a big plan into per-step execute sessions) is a
later slice of BH-8868.

## Tests

`tests/execute-no-progress.bh-8868-test.sh`, `tests/execute-transcript.bh-8868-test.sh`.
