# BH-9065 — pool machine shape

The Fly bill had four kinds of waste (audit of 2026-11-05): pool machines on
performance-8x for model sessions, machines that ran for hours, test hosts that
never stopped, and machines with no cost row. This note says what each part
does, which settings row turns it on, and what is still an operator step.

## 1. Two machine classes per job kind (C1a)

- `bin/lib/pool-vm-size.sh`: `pool_vm_resolve` accepts the shared-cpu class
  (`shared-cpu-1x|2x|4x|8x`, memory a multiple of 256 MB, 256..2048 MB per CPU).
- The job kind comes from the key: `build`, `leadreview` (LR-), `rereview`
  (RR-), `fixround` (FXR-), `rebase` (RB-), `preview` (CP-), and for a build
  key `plan` / `execute` (part 2).
- Row `lane.fly-pool.<project>.vm_class` maps kinds to a class. No row (or
  an empty row) is the fallback map `plan=model leadreview=model
  rereview=model`. A row replaces the whole map; `build=compute` puts every
  kind back on compute. A `model` kind uses rows `vm_size_model` /
  `vm_memory_mb_model` (fallback shared-cpu-2x / 4096). Every other kind is
  `compute`: rows `vm_size` / `vm_memory_mb` (fallback performance-8x /
  16384). Execute, the gate and the test phases run in a compute job.
- `spawn_one` logs `vm class <class> <size>/<mem> for <KEY> (<kind>)` after
  `machine run` returns an id, and writes `vm_class`, `vm_size`, `vm_mem` on
  the machine json. `next_job_or_destroy` reuses a machine only for a job of
  its own class. A machine json with no `vm_class` was spawned before this
  deploy: it keeps the old rule and takes any job, so the deploy destroys no
  running machine.

## 2. Plan and execute on separate machines (C1b)

When `vm_class` maps `plan=model` (the fallback map does). A build key spawns on the model class
with `stage:"plan"` on its job.json. `bin/run-build.sh` runs the gates and the
PLAN stage, then `ps_plan_handoff` (`bin/lib/pool-stage.sh`) publishes the plan
to `/api/preplans` (the row `bin/run-preplan.sh` writes) and answers
`PLANNED stage=plan <KEY>`. The reap (`pool_stage_reoffer`) requeues the key
with `stage:"execute"` and takes back the plan spawn's per-key cap entry, so a
pair counts once. The execute machine is compute class and adopts the plan
through the preplan relay (`PREPLAN_HIT`, no PLAN call). If the publish fails,
the plan machine builds the whole ticket itself, as before.

## 3. Soft cap of 2 hours per machine (C2)

Row `lane.fly-pool.<project>.pool_machine_soft_cap_s` (fallback 7200, 0 = off).
`pool_job_stamp` writes it on every build job as `soft_cap_s`, on a private
copy of the job file that is pushed to the machine. The queue file under
`state/build-queue/` is never rewritten. The machine's
uptime is the clock. `CC()` (`bin/lib/rb/plan.sh`) clamps each model session to
the time left, and at the cap `ps_cap_fire`:

1. checkpoints the branch with `bin/lane-checkpoint.sh` (wip commit, pushed),
2. publishes the plan (after the PLAN stage),
3. writes `brief.md`,
4. answers `CAPPED stage=<stage> after=<n>s`.

A checkpoint that does not land writes no CAPPED; the build goes on. The reap
requeues the key with the brief (`cap_brief`), `fresh_spawn` and, after the
PLAN stage, `stage:"execute"`. Attempt, deferrals, deaths and every other
counter stay as they were; the row's reason is `cap: CAPPED …`. The next
machine resumes from the wip commits, and its EXECUTE prompt carries the brief.
A machine whose job has no `soft_cap_s` (spawned before the deploy) is never
capped.

A machine at or past the cap is never reused. `next_job_or_destroy` destroys
it when its RESULT is `CAPPED`, or when the time since `booted_at` is at or
past `POOL_MACHINE_SOFT_CAP_S`. `spawn_one` writes `booted_at`, and the reuse
hand-off carries it, because `spawned_at` moves on each hand-off. A machine
json with no `booted_at` (spawned before this deploy) is never capped by age.
Without this arm, a capped machine took the next queued key, capped on its
first agent call and spent one of that key's spawns.

## 4. Test hosts scale to zero (C3)

`bin/testhost-tick.sh` checks every machine of the test-host app on its own
idle clock, `testhost.last_used.<mid>` (the shared `testhost.last_used` row is
only a fallback). It stops a host after `TESTHOST_IDLE_STOP_MIN` (default 10,
min 10) idle minutes when the busy probe says idle, no route is live and the
started count is above `TESTHOST_MIN_STARTED` (default 0). `ensure` starts one
stopped host when none is started. `docs/REMOTE-GATE.md` has the details.

## 4b. Lane-run machines of a declared CPU class (C4)

A lane that needs CPU declares `"machine": {"cpu": "performance", "size":
"performance-4x"}` in `catalog/lanes.d/<lane>.json` (`bin/lanes-build.sh`
validates it). `bin/lane-fleet.sh` starts a `--rm` machine of that size for
that lane, with `LANE_RUN_LANES=<lane>`, and stops it when the lane has no
queued run. The `lane-run-mk` and `lane-run-ts` group rows move to
`shared-cpu-2x` / 4096 as an operator step (the rows are prod data).

## 5. A cost row for every machine (C5)

`pool_fly_cost_row` prices a machine the listing no longer has from the
`vm_size`/`vm_mem` the spawn wrote (note `fly:<mid>:state=estimated`). The
dead-machine sweep bills an untracked orphan once (`pool_fly_orphan_cost_row`,
key `orphan`, interval from Fly's `created_at`..`updated_at`) before it
destroys it. A machine the ledger already billed under any key is skipped.

## Operator steps (not done from a box)

- The model class is on at deploy (fallback map). To turn it off for one
  project, set `lane.fly-pool.<project>.vm_class` to `build=compute`.
- C6: list and delete the idle storage (commands in the PR body). Code never
  destroys a volume.
- GitHub repo artifact retention: `gh api -X PUT
  repos/example-org/cromford/actions/permissions/artifact-and-log-retention -F days=7`.
  All 9 `upload-artifact` steps already set `retention-days` 3 or 7.
