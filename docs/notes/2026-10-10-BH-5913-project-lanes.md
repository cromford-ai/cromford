# One run per project: the shared per-project lane runner (BH-5913)

Doc: MERGE-CONDUCTOR

## Why

On 2026-10-09 every blocked-resolver tick on the hub ran 55-58 minutes. Each
tick logged `visited=[cromford] skipped=[<9 projects>] reason=tick-budget`
and `oldest_untouched=3903m`. One scan walked the parks of every project in one
loop. cromford had 600+ candidates and spent the whole tick. The scan lock
also turned away `blocked-resolver.sh <project>`.

The fix is one independent run per project. `bin/lib/project-lanes.sh` makes
that a shared contract, so other hub lanes can move onto it. The merge
conductor's `tick_project` fork loop is the model.

## The contract

A lane's cron line calls the dispatcher. The dispatcher calls:

    pl_dispatch <lane> <period-secs> <cmd> [args...]

1. It reads `bin/fleet-conf.sh --projects`.
2. It skips a project that `lane_project_held <lane> <project>` holds (when
   `bin/lib/lane-gate.sh` is loaded).
3. It starts one detached `bin/project-lane-run.sh <lane> <project> <offset>
   <cmd> [args...]` per project. There is no cap.
4. It prints one summary line and returns at once. It never waits for a run.
   The line is `<lane> dispatch: started N project run(s) (period Ps, no cap),
   K held: [p@offset ...]`.

`bin/project-lane-run.sh` does these steps for one project, then runs
`<cmd> [args...] <project>`:

| Step | What | Detail |
|---|---|---|
| Offset | sleep `pl_offset <lane> <project> <period>` | cksum of `<lane>/<project>`, in [0, period), never within 5 s of a whole minute. Stable across dispatches. A period of 0 starts every run at once. |
| Lock | `locks/<lane>-<project>.lock`, `flock -n` on fd 9 | Held for the life of the command. A project whose last run still holds it gets one line in `logs/<lane>-cron.log` and no run. `PL_LOCK_FD=9` is exported; `pl_unlock` releases it early. Every other inherited fd above 2 is closed. |
| State dir | `state/<lane>/<project>` | Created and exported as `PL_STATE_DIR`. The runner writes nothing in it. |
| Credential | `gh_auth_for <repo>` | Exports `GH_TOKEN` as the repo's App installation token. With no App on the box, `GH_TOKEN` stays as it was. The token lives one hour: a longer run, or a run that sources an env file that sets `GH_TOKEN`, re-arms with `pl_token`. |
| Env | `PL_LANE`, `PL_PROJECT`, `PL_SLUG` | `PL_SLUG` is the fleet.conf repo, or empty. |
| Output | `logs/<lane>-cron.log` | stdout and stderr of every run append here. |

A run started by hand (`<lane script> <project>`) takes the same lock with
`pl_lock_take <lane> <project> <fd>`, so a manual run and a dispatched run of
one project never overlap.

## Moving a lane onto the runner

1. Give the lane script a one-project mode that touches only that project's
   rows, state and repo.
2. Add a dispatch mode that calls `pl_dispatch <lane> <period> <script>`.
3. Point the cron line at the dispatch mode.
4. Move each fleet-wide state file to a per-project name, or rewrite it under a
   short lock (`flock -w 5`, never across a long step).
5. Re-arm the project's credential after anything that resets `GH_TOKEN`.

## blocked-resolver, the first lane

- Cron runs `blocked-resolver.sh --dispatch`, with `BR_DISPATCH_SPREAD_SECS` as
  the period (default 540, 0 = all at once).
- A project run keeps its own budget carry (`.tick-budget-<project>`) and
  saturation streak (`.saturation-<project>.tsv`). Its SATURATED marker is
  `.saturated-<owner>_<repo>`. The conductor reads it with
  `mc_resolver_saturated <key>`.
- Discovery is filtered to the run's project before any GitHub read
  (`br_key_in_only`, and a filter on the candidate list).
- A project run arms its repo's credential before its first read, after every
  `br_reset_token` and at every row (`br_home_token`).
- `bin/lib/br/opt/untouched.sh` pages once per project episode when the oldest
  untouched park passes `BR_UNTOUCHED_ALERT_MIN` (default 120).
- Shared state that stays shared: `.last-visited.tsv` and `.parent-wait.tsv`,
  each rewritten under a short lock.

## Tests

- `tests/project-lanes.bh-5913-test.sh`: the runner (20 parallel runs, a
  dispatcher that returns first, lock isolation, offsets, credential per
  project, environment and state dir, held projects).
- `tests/blocked-resolver-dispatch.bh-5913-test.sh`: blocked-resolver on the
  runner.
