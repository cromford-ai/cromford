# 2026-09-19 — BH-1044: disk-clean bounds the four state accumulators

Doc: OPERATOR-SETUP

## What changed

`bin/disk-clean.sh` (already on every box's crontab at 04:47Z — no cron change)
grew four stages after its npm/bench/worktree ones:

4. **`state/closeout-aged-out.tsv` is pruned.** The rows carry no timestamp of
   their own (`bin/lib/closeout-terminal.sh` writes project, build dir, RESULT
   first line, reason), so the cutoff compares the 12-digit launch stamp that
   `bin/run-build.sh` and `bin/fly-pool.sh` put at the end of a build dir name.
   A row older than `CLOSEOUT_TSV_KEEP_DAYS` (default 30) whose build dir is no
   longer on the box, or a second row for a dir already kept, is appended to
   `state/archive/closeout-aged-out.<YYYYMMDD>.tsv` FIRST; only then is the
   rewritten file moved into place, under `locks/closeout-aged-out.lock` — the
   same lock `closeout_record_aged` takes. A row whose dir has no parseable
   stamp is kept, never aged out. Nothing to drop means no rewrite at all (the
   inode does not move), and a held lock means the run skips and says so.
5. **Stale lock files go.** `locks/*` regular files older than `LOCK_STALE_H`
   (default 24) are deleted only when three probes agree: the mtime gate, no
   open fd anywhere in `/proc`, and `flock -n`. The unlink runs inside that
   flock, so nothing can take the inode between the probe and the `rm`.
   Directories under `locks/` are never candidates.
6. **Operator scratch moves.** `state/*.sh`, `state/*.done` and `state/*.bak-*`
   (top level only) move to `state/scratch/` with `mv -n`. A `*.sh` the box's
   crontab names, or one a `bin/` script reads by name, stays where it is.
   `bin/state-backup.sh` now excludes `state/scratch` from the off-box tarball.
7. **`state/leases/` is deleted** once nothing inside it changed for
   `LEASES_STALE_D` days (default 7). The reader grep at build time
   (`grep -rn 'state/leases\|/leases\b' bin cron docs fly worker`) found only
   `state/quota/leases/` — a different path, and never a candidate here.

## The 45 MB was the writer, not the missing pruner (fix round)

Review asked the question the plan skipped: why does a file the lib calls "a set
keyed on the build dir" have duplicates at all? Because of this line in
`bin/lib/closeout-terminal.sh`:

```
cut -f2 "$tsv" 2>/dev/null | grep -qxF "$dir" && exit 0
```

`grep -q` exits at the first match. When the match is not inside the last ~64 KB
of the file, `cut` is still writing, takes SIGPIPE and the pipeline returns 141 —
and `bin/pipeline-health.sh` runs `set -uo pipefail`, which that subshell
inherits. So the dedupe said "not recorded" about a row it had just found, and
appended it again. Every 10 minutes, for every dir near the top of the file.
~800 aged dirs x 144 ticks x ~100 bytes is the ~11 MB/day the audit measured.
Measured on this box: 34 MB fixture, match on the first row → rc 141; match on
the last row → rc 0; a 63 KB fixture → rc 0 either way, which is why no fixture
ever caught it.

Two changes came out of that:

- The dedupe read is one `awk` process now, no pipe to break, rc is the answer.
  `tests/closeout-record-aged-dedupe.bh-1044-test.sh` drives the writer under
  `set -o pipefail` against a file past the pipe buffer with the target row
  FIRST, which is the exact shape that was re-appending.
- **Stage 4 keeps a row whose build dir still exists, at any age.**
  pipeline-health re-records an aged dir on its next tick for as long as that dir
  has a RESULT and no COMMENTED, and nothing in this harness deletes build dirs.
  Archiving such a row by age alone would hand the row straight back to the tsv
  and grow `state/archive/` by the same ~800 dirs every day — inside `state/`,
  which `state-backup.sh` tars every 15 minutes. That is relocating the problem,
  not bounding it. A row is archived once its dir is gone and nobody can record
  it again. The summary line carries `tsv_kept_live=N` for the rows kept that
  way, and a `[disk-clean]` line names the count.

## Why

The Mac-side audit of 2026-09-19 (`docs/HARNESS_SPEND_AND_STATE_AUDIT_2026-09-19.html`)
found on the hub: a 45 MB `closeout-aged-out.tsv` that `bin/pipeline-health.sh`
greps every 10 minutes and nothing ever pruned, 3,153 stale flock files in
`locks/`, ~40 hand-run one-off scripts plus 25 `claude-auth-down.txt.bak-*`
copies loose in `state/`, and three August files in `state/leases/` with no
reader. Every one of them also rides into `state-backup.sh`'s tarball and back
out of a restore. #1033 slice 8 still moves the tsv's dedupe to a table later;
the archive files this writes keep the same four columns, so that backfill can
read both.

## What it touches

- Knobs, in `env/global.env` (`env-templates/global.env.example` carries them):
  `CLOSEOUT_TSV_KEEP_DAYS=30`, `LOCK_STALE_H=24`, `LEASES_STALE_D=7`. A value
  that is not a number logs one line and falls back — it is never clamped in
  silence.
- Test seams on the script, all defaulting to the live paths: `HARNESS_ROOT`,
  `DISK_CLEAN_REPOS`, `DISK_CLEAN_NPM_DIR`, `DISK_CLEAN_NOW`, `DISK_CLEAN_PROC`.
- New state on a box: `state/archive/` and `state/scratch/`.
- Where your `state/crontab.bak-<stamp>` copies went: `bin/update-runners.sh`
  writes one before it applies a rendered crontab, and `*.bak-*` is a scratch
  shape, so stage 6 moves them under `state/scratch/` and the backup leaves them
  behind. Nothing reads them (grepped) and every tarball's `meta/crontab.txt`
  carries the crontab that was live when it was taken, so the restore path is
  unchanged — but an operator hunting for a pre-change crontab should look in
  `state/scratch/`, not `state/`.
- One plan promise not kept, on purpose: the plan wanted a belt-over-braces
  "never touch `build-slot-*.lock` while `pgrep -f run-build` shows a build".
  It is not in the code. A running build holds its slot lock, so probe (b) (the
  open fd in `/proc`) and probe (c) (`flock -n`) both already refuse it, and the
  suite proves that with a real flock holder and with `/proc` blinded. A third
  probe that guesses from a process name would only add a way to be wrong.
- Suites: `tests/disk-clean-hygiene-test.sh` (the ticket's acceptance suite, 83
  assertions over a 11 MB tsv fixture, a still-present build dir, 100 stale
  locks, a flock-held lock, a merely-open lock, the crontab-named script, the
  bin/-read script, the collision case and the leases guards),
  `tests/state-backup-scratch-exclude.bh-1044-test.sh` and
  `tests/closeout-record-aged-dedupe.bh-1044-test.sh`.
- Map entry: `docs/verification-map/disk-clean-hygiene.md`; the "Never pruned"
  line in `docs/verification-map/closeout-health.md` is now false and was
  corrected in the same diff.
