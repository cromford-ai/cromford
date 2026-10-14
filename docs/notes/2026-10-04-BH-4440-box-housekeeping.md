# BH-4440: box housekeeping for session ledgers and /tmp, and a disk alert that says where the space went

Doc: disk-clean-hygiene, disk-guard

**What changed.**

- New `bin/box-housekeeping.sh [--dry-run]`, run by `bin/disk-clean.sh` as
  stage 9 (04:47Z daily, every box). It does two sweeps and writes one summary
  line for each to `logs/disk-clean.log`:
  - **Session ledgers.** Regular files under `~/.grok/sessions` and
    `~/.codex/sessions` older than `AGENT_SESSION_KEEP_DAYS` (default 7) are
    deleted. Then it removes the directories that run emptied, and empty ones
    already past the cutoff. The `sessions` root itself always stays, and a
    root that is a symlink is refused. `bin/grok-usage.sh` and
    `bin/codex-usage.sh` only read files newer than the call in flight, so
    neither loses an input.
  - **`/tmp` top level.** An entry goes when the newest mtime anywhere inside
    it is older than `TMP_TOPLEVEL_STALE_D` (default 2) days. Kept at any age:
    - a basename in `TMP_SWEEP_KEEP_GLOBS` (dot-entries, `systemd-private-*`,
      `snap-private-tmp`, `tmux-*`, `worktrees`, `repos`, `builds`)
    - sockets and FIFOs
    - mount points (compared by `stat %m`, because overlayfs gives a file and
      its own directory different `st_dev`)
    - git worktrees
    - anything a `/proc/<pid>/fd` or `/proc/<pid>/cwd` points into
    - anything whose age was not read within `TMP_AGE_SCAN_TIMEOUT_S`

    The whole sweep stops at `TMP_SWEEP_DEADLINE_S` and counts what it left
    as `left=`.
  - Every count is bumped only after `[ ! -e ]` proved the removal. KB is
    measured before the removal.
  - A knob that is not a whole number at or over its minimum skips its sweep,
    with a log line.
- `bin/disk-clean.sh` stage 1: the npm cache line, which was the literal
  `2048`, is now the `NPM_CACHE_MAX_MB` knob. A garbage value skips the clean
  and logs it. The `disk-clean:` summary line is unchanged.
- `bin/disk-guard.sh`: the `disk-high-<host>` text now ends with
  `top dirs: <path> <size>, ...`. That is the 5 largest depth-2 directories
  from `nice du -xk -d 2 /` under `timeout DISK_TOP_DIRS_TIMEOUT_S` (default
  120). The result is cached in `state/disk-guard/top-dirs` for
  `DISK_TOP_DIRS_TTL_MIN` (default 60). A du that times out or prints nothing
  gives `top dirs: unavailable (<why>)`, never a partial list. The id is
  unchanged, so it is still one row per box, and it resolves as before.

**Operator.** `bin/harness-ctl.sh set disk-clean AGENT_SESSION_KEEP_DAYS <n>`
(likewise the other knobs). Off: `bin/harness-ctl.sh off disk-clean` stops the
housekeeping with the rest of the lane. Preview on a box with
`bin/box-housekeeping.sh --dry-run`.

**After merge.** The first real run on each box is its next 04:47Z
`disk-clean` tick. The box's before/after `%` is in that tick's `disk-clean:`
line, and the counts are in its two `box-housekeeping:` lines.
