# BH-6979 (BH-6547.3): the scheduler owns dispatch

Doc: SCHEDULER, FLY-POOL, BUILD-CONCURRENCY

Wave 3 of 4 of #6547. Wave 2 (BH-6978,
[its note](2026-10-16-BH-6978-scheduler-shadow.md)) computes the ready set in
shadow. This wave adds `scheduler.mode=enforce`: with that settings row, the
pool and triage dispatch read the scheduler's ready set and dispatch only from
it. The row stays `shadow` until an operator flips it.

## The rule

`bin/lib/sched-gate.sh` is the one reader of the set and the one place the
rule lives. `sched_gate <project> <KEY>` answers:

| Answer | rc | When |
|---|---|---|
| `SCHED_READY <KEY> (tick <at>)` | 0 | verdict `yes` |
| `SCHED_WAIT <KEY> reason=<r> (tick <at>)` | 3 | verdict `no` or `unknown`, or the key is absent from the set (`not in ready set`) |
| `SCHED_PASS <KEY> <why>` | 2 | today's path: not enforced, a key that is not `<PFX>-<n>`, verdict `in-flight`, or the set is not usable (`ready set <state>`) |

Enforce applies when the row `scheduler.mode` is exactly `enforce` (white space
trimmed; `Enforce` is not enforce) and the project is a word of
`scheduler.projects` (default `cromford`).

The set is usable when `GET /api/scheduler/ready` answers `ok:true` for a tick
posted in mode `enforce`, no older than `scheduler.ready_max_age_s` (900 s,
three ticks), with `complete:true`. Otherwise the state is `unreadable`,
`no-tick`, `shadow-tick`, `stale` or `incomplete`, and dispatch FALLS BACK to
today's gates (sibling-serial, overlap-schedule, stack-wait). It does not stop.
A fallback writes one warn ALERTS line per project per UTC day (flag
`flags/alerted-sched-fallback-<p>-<YYYYMMDD>`):
`scheduler.mode=enforce but the ready set is <state> — dispatch fell back ...`.
The first tick after a flip is still a shadow tick, so expect that line once on
the day of the flip.

## Where it decides

- **Triage dispatch:** block `# >>> scheduler enforce gate (BH-6979)` in
  `bin/lib/rb/gates.sh`, after the dispatch-mode gate and before the budget
  gate and the Fly enqueue. Every launcher reaches it through
  `bin/run-build.sh`. rc 3 is `BUILD_DEFERRED scheduler: <KEY> waits — <reason>
  (tick <at>)`, exit 3, with no claim, slot or queue row. A resume
  (`RESUME_BUILD`) and a pool machine (`BUILDER_EXEC=1`) are not asked.
- **Pool dispatch:** gate 0c of `pool_spawn_decision` in `bin/fly-pool.sh`. A
  wait holds the row with no machine, no QROW write and no deferral count. A
  ready verdict spawns without asking `bin/sibling-serial.sh`. A pass runs
  today's sibling-serial check.
- **The triage prompt:** in `bin/lib/rt/scope.sh` the OVERLAP SCHEDULE section
  is replaced by a SCHEDULER READY SET section (READY keys, WAITING keys with
  their reasons, the launch rule). A triage shard gets the same section in
  its SOP: `rt_scope` appends it to `SHARD_SOP`, which `rt_shards` reads.
  `bin/overlap-schedule.sh --key` answers nothing, so the shard has no
  overlap verdict. `bin/lib/rt/shards.sh` is not edited: the BH-3418 suite
  (B1) keeps it unedited.
- **STACKED_WAIT:** in enforce the `# >>> stacked child builds` block ignores
  `STACK_BASE`, the same way as `STACKED_BUILDS=0`. An admitted ticket has no
  open hard parent, so it builds on the real base. No stack-wait read,
  deferral or cap runs. The merge conductor's STACKED_WAIT merge class is not
  changed: it orders PRs that are already built.

`bin/sibling-serial.sh`, `bin/overlap-schedule.sh` and `bin/lib/stack-wait.sh`
are not changed. The scheduler calls them for their data.

## What the lane adds

- Every tick posts `verdicts` with its tick: one per candidate, judged ones as
  `yes|no|unknown` with the reason, in-flight ones as `in-flight` / `in flight`.
  Stored in `sched_ready` (unique `(project, at, ticket)`), in the same D1
  batch as the `sched_ticks` row, so a half-written set cannot exist.
- In enforce only, the tick reads sibling-serial: `sibling-serial.sh parts <p>`
  once, then `SIBLING_STACK=0 sibling-serial.sh check <p> <KEY>` per judged
  candidate that is a part, at most `scheduler.sibling_checks_max` (20). A
  wait `SIBLING_SERIAL <KEY> waits for <PFX>-<s>` is the verdict `no` /
  `files claimed by #<s>` (rule 3b of `sched_decide`). A part past the cap is
  `unknown` / `sibling check cap`. In shadow the lane does not call it, so the
  wave-2 agreement numbers do not change.

## Routes

- `POST /api/scheduler/diffs`: `mode` is `shadow` or `enforce`; optional
  `verdicts:[{ticket, ready, reason}]` (at most 1000; `reason` 0..200 chars,
  empty only on `yes`), written with ONE `INSERT ... SELECT ... FROM
  json_each`. The answer adds `verdicts_written` when verdicts were sent.
- `GET /api/scheduler/ready?project=`: `{ok, project, at, mode, candidates,
  complete, verdicts}` for the newest tick, in one statement (an uncorrelated
  CTE for the newest tick, then an index range of its rows). No tick:
  `{ok:true, project, at:null, complete:false, verdicts:[]}`.

## Settings rows

| Row | Seed | Meaning |
|---|---|---|
| `scheduler.mode` | `shadow` (wave 2) | `enforce` turns this wave on |
| `scheduler.ready_max_age_s` | 900 | a set older than this is stale |
| `scheduler.sibling_checks_max` | 20 | sibling-serial checks per tick in enforce |
| `retention.sched_ready.days` | 3 | rule `sched_ready.age` deletes older rows |

## Flip and rollback

Flip (operator): `bin/jobs-client.sh setting-set scheduler.mode enforce`, or the
console settings screen. Rollback: set the row back to `shadow`. Every gate
reads the row on each decision (the settings cache window applies), and in
shadow and off every path is today's.

Before the flip, read the agreement rate of the last 3 days:
`GET /api/scheduler/agreement?day=<YYYY-MM-DD>&project=cromford`.

Tests: `tests/scheduler-enforce.bh-6979-test.sh`,
`worker/jobs/test/scheduler-ready.bh-6979.test.js`.
