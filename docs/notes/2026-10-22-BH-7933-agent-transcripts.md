# disk-clean bounds ~/.claude/projects, dry first (BH-7933)

Doc: HARNESS-COORDINATION

## What changed

The 2026-10-21 fleet survey found 5.0 GB of Claude Code transcripts under
`/root/.claude/projects` on box-small and 815 MB on project-3. No lane
owned that directory.

- `bin/agent-transcripts-clean.sh` is new. `bin/disk-clean.sh` runs it as
  stage 11, after the cron log bound. It reads the `disk-clean` lane gate and
  rows, so `flags/lane-off-disk-clean` stops it too.
- It removes regular files under `~/.claude/projects` with an mtime older than
  `CLAUDE_TRANSCRIPT_KEEP_DAYS` days (default 14, min 3), then the dirs this
  run emptied and empty dirs older than the cutoff.
- It keeps: a file any `/proc/<pid>/fd` link names, anything under a project
  `memory/` dir (the agent memory `bin/orchestrate.sh` reads), symlinks and
  their targets, and everything outside `projects/`. A `projects/` that is a
  symlink is refused.
- It ships dry. `TRANSCRIPTS_DRY_RUN` (row `lane.disk-clean.transcripts_dry_run`,
  default 1) logs one `agent-transcripts: dry-run would_remove=N freed_kb=K`
  line in `logs/disk-clean.log` and deletes nothing. Only the exact value 0
  deletes.
- An invalid keep-days value skips the stage with one log line.

## Before an operator sets the row to 0

`bin/archie-learn.sh` reads orchestrator transcripts newer than
`ARCHIE_SKILL_UNUSED_DAYS` (default 30) to flag unused skills. With the stage
live at 14 days it sees 14 days and can flag more skills as unused.

Test: `HARNESS_TEST_SANDBOX=1 bash tests/disk-clean-transcripts.bh-7933-test.sh`.
