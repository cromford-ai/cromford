# Overlap schedule: read-mostly paths are not collisions (BH-6299)

Doc: SCHEDULER

## What happened

On project-6-os on 2026-10-12, six tickets (TK-61, TK-62, TK-136, TK-146,
TK-154, TK-155) each planned the same six repo-wide guard tests and checks.
A slice runs those files. It almost never edits them: two real commits across
all of them since 2026-10-09. `bin/overlap-schedule.sh` read each shared path
as a COLLISION and put the six tickets in six waves. `bin/overlap-guard.sh`
deferred them on the same paths.

## What changed

1. **One rule, `bin/lib/read-mostly.sh`.** `read_mostly_list <project>`
   prints the read-mostly paths. It reads the newest builds of the project
   that opened a PR (`RESULT` line 1 `PR_CREATED http…` or `PR_MERGED http…`,
   with a non-empty `planned-files.txt` and `changed-files.txt`), one build per
   KEY. For each planned path, `edit_rate = edits / plans`. A changed file equal
   to the path, or under it, is an edit. A path with at least
   `READ_MOSTLY_MIN_PLANS` plans and a rate strictly below
   `READ_MOSTLY_MAX_RATE` is read-mostly.
2. **The schedule and the guard both call it.** The schedule exempts the set in
   `ignored()`, beside `OVERLAP_IGNORE`. The guard drops the set in `prune()`
   and writes `read-mostly: <n> path(s) not judged` to `logs/overlap-guard.log`.
   Both match by exact path. HOT-FILES still lists the path and ends its line
   with ` (read-mostly)`.
3. **The planner lists edits only.** `bin/lib/verify-list.sh` `vl_plan_rule`
   is in the pre-plan prompt (`bin/run-preplan.sh`) and the build plan prompt
   (`bin/lib/rb/plan.sh`). It tells the planner to list only files it will
   MODIFY or CREATE, and to name run-only tests and checks under
   `## Verify (run, not edited)`.
4. **`bin/planned-files.sh` skips run-only paths.** It does not scan the
   `## Verify…` section (to the next `#`/`##` heading) or any line whose first
   word is `VALIDATE:` (after an optional `-` or `*` bullet). A path also named
   on any other line is still listed.
5. **`READ_MOSTLY_EDITED <file> <KEY>`.** When a counted build changed a
   read-mostly path, the compute appends that line to `logs/read-mostly.log`,
   once per (KEY, file).

## Knobs

Read through `bin/lib/scheduler-conf.sh` (env, then the settings row
`conf.scheduler.<lowercase name>`, then `flags/scheduler.conf`, then the
default):

| Knob | Default | Meaning |
|---|---|---|
| `READ_MOSTLY_WINDOW` | 50 | counted builds read, newest first (a cap: an older build is not read) |
| `READ_MOSTLY_MIN_PLANS` | 5 | plans a path needs before it can qualify (floor 2) |
| `READ_MOSTLY_MAX_RATE` | 0.2 | edits/plans must be strictly below this; `0` turns the feature off |
| `READ_MOSTLY_MAX_AGE` | 900 | seconds the cache is reused; `0` recomputes on every call |

## State

- `state/read-mostly/<project>.tsv`: `path<TAB>plans<TAB>edits` for every path
  with at least `READ_MOSTLY_MIN_PLANS` plans. A cache of a pure function of
  `builds/`. Loss costs one recompute.
- `state/read-mostly/<project>.edited`: `KEY<TAB>file` lines that dedupe the
  `READ_MOSTLY_EDITED` log line. Loss re-logs lines and has no other effect.

## Limits

- Each box computes the set from its own `builds/`. A box with less history
  finds fewer read-mostly paths, so it falls back to the old rule.
- `bin/plan-overlap.sh` and `bin/conflict-check.sh` do not read the set. They
  see only the smaller `planned-files.txt` from item 4.
- A real edit of a read-mostly path is not prevented. The merge conductor
  rebases, and a textual conflict goes to `bin/blocked-resolver.sh` as before.

Tests: `tests/overlap-read-mostly.bh-6299-test.sh`,
`tests/planned-files-verify.bh-6299-test.sh`.
