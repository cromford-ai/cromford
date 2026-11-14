# BH-9426: build deferral report, and no deferral on a path the merge resolves by itself

Doc: BUILD-CONCURRENCY, SCHEDULER

## Why

In 7 days the hub recorded 932 builds. 319 (34%) ended `BUILD_DEFERRED`
because another build held the same planned files. Nothing said which files.
Some of the deferrals were on files the merge resolves by itself.

## What changed

- `bin/defer-report.sh [--last <N>d] [--project <p>] [--top <n>] [--out <file>]`
  reads `builds/[fly-|pool-]<project>-<KEY>-<stamp>/RESULT`. For each
  `BUILD_DEFERRED` it names the files and the holder from the two shapes
  production writes: `OVERLAP_DEFER <K> vs <HOLDER> files=[...]`
  (plan-overlap.sh, plan-sibling.sh) and `file overlap — CONFLICT with <dir>:
  p ~ q` (conflict-check.sh). Any other deferral is counted as `other`. The
  wait of a deferral is the start of the next build of the same KEY minus its
  own start; no next build is `open`. It prints TOP FILES (count, total and
  median wait, open, holders) and PER TICKET.
- Lane `defer-report` (hub, `17 6 * * *`, `cron/lanes/718-defer-report.cron`):
  one line per project per day in `logs/defer-report.log`, and the TOP FILES
  paths in `state/defer-report/<project>-top.txt`. Knobs
  `DEFER_REPORT_WINDOW_DAYS` (7), `DEFER_REPORT_TOP` (20),
  `DEFER_REPORT_ENABLED` (1). Kill: `flags/lane-off-defer-report`.
- `bin/lib/automerge-paths.sh`: a path is auto-merge when the target repo's
  `## Generated files` table declares it or `git check-attr merge` gives
  `union`. `bin/conflict-check.sh`, `bin/overlap-guard.sh` (`prune`),
  `bin/plan-overlap.sh` and `bin/plan-sibling.sh` (`fragment_safe`) do not
  defer on it. The repo is `$PLAN_OVERLAP_REPO`, else
  `$REPOS_ROOT/<project>`. No repo dir = the old rule.
- `bin/lib/defer-top.sh` `defer_top_line`: the planner, execute and review
  prompts get one line under the verification-map line: the top files from
  `state/defer-report/<project>-top.txt`, as files to stay out of unless the
  ticket is about them. A list older than `DEFER_TOP_MAX_AGE_H` (48) is not
  shown. Called from the `# >>> defer top` block of `bin/lib/rb/plan.sh`.
- The conductor half of scope 3 was already on main (BH-8986 made
  `catalog/state-paths.json` a git-ignored render; BH-1175
  `mc_resolve_deleted_ignored` takes main's deletion).
  `tests/mc-state-paths-regen.bh-9426-test.sh` proves a stale PR's
  `catalog/state-paths.json` conflict resolves with no human.

## Not in this change

Scope 2 (split the top 5 list or hub files into fragment folders) needs the
report's output from the hub. The pool box that built this has no build dirs,
so no file is named here. Run `bin/defer-report.sh --last 7d --project
cromford` on the hub and pick the five from its TOP FILES.
`bin/overlap-schedule.sh` is unchanged: it judges pre-plan lists through the
`OVERLAP_IGNORE` globs.
