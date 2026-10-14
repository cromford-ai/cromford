# P2: cut the paid calls around execute (2026-09-25)

**Why.** Seven days of cost rows to 2026-09-25: pre-plan spent **$4.4K on top
of plan's $6.5K**, and on the boards that ship least, triage is most of the
bill: project-1 $637 of triage for 13 merges, project-7 $649 for 6,
project-8 $238 for 4. project-9 spent **$643 with zero merges**
(pipeline-health `costzeromerge`). the operator's rule: no per-ticket dollar budgets.
Cut the **volume** of paid calls, structurally and deterministically. Three
levers, each a knob that is a settings row, each fail-open.

## 1. Skip a pre-plan that adds nothing

`preplan_small_reason` in `bin/lib/preplan-lib.sh`, asked by
`bin/preplan-tick.sh` (both loops, before the slot is spent) and again at the
choke point in `bin/run-preplan.sh` (before any plan is written and before the
billable call). A pre-plan buys latency, never correctness: the build's PLAN
stage plans from scratch whenever no fresh pre-plan is there. So it is skipped
when:

| Case | Evidence (no model) |
|---|---|
| triage sized it small | `size=S` / `size=XS` on the key's READY-QUEUE line (`SIZE: S` too; never `resize=S`) |
| copy/docs work | `kind=copy` on the queue line, or the board's own title prefix mapped through `bin/kind-gate.sh` (the vocabulary the build's kind flow uses) from the gate's fingerprint `state/<p>.gate.json` (+ `state/<p>.keymap.json` on in-app boards) |
| its build is running | the key is in `preplan_midbuild_keys` (build dir with no RESULT, held build-key lock, a running jobs row), asked once per project per tick |

Triage writes the tags: `catalog/agent-contracts/triage-system-append.txt`
(QUEUE LINE TAGS) asks every tick to put `size=<S|M|L|XL>` and
`kind=<bug|feature|copy|migration|infra>` on the queue lines it writes. The
`kind=` vocabulary is exactly bin/kind-gate.sh's KIND set; docs work is `copy`,
and no other spelling is honoured. A queue line with no tag pre-plans exactly as
before.

**The file list survives the skip.** The pre-plan was also where
`plans/<p>-<KEY>/planned-files.txt` came from, and bin/dep-verify.sh (missing =
UNKNOWN = obeyed as HARD), bin/overlap-guard.sh, bin/overlap-schedule.sh and the
train read it. So the first skip of a key runs `bin/planned-files-cheap.sh` with
`PLANNED_FILES_FREE_ONLY=1`: tiers 1-2 only (ticket-body paths, codegraph
importers), never the tier-3 model call. It writes `planned-files.txt` and never
`plan.md`, so nothing is adoptable as a plan. In-app boards have no issue body
for it, so there it writes nothing, the same as bin/preplan-candidates.sh today.

One `PREPLAN_SKIP small: <reason>` line per key per reason in
`logs/preplan.log` (marker `state/preplan/<p>-<KEY>.small`).

Knob: `PREPLAN_SKIP_SMALL` (preplan-tick lane, `lane.preplan-tick.preplan_skip_small`,
default 1). `0` or `flags/preplan-skip-small-off` restores the old behaviour.

## 2. Low-yield board triage throttle

`triage_throttle_check` in `bin/lib/triage-throttle.sh`, asked by
`bin/lib/rt/gate.sh:rt_gate` after the cost gate answered RUN. Per project,
settings rows on the run-triage lane (exported by the existing
`lane_env_apply run-triage <project>`):

| Knob | Row | Default | Meaning |
|---|---|---|---|
| `TRIAGE_MIN_INTERVAL_S` | `lane.run-triage.<p>.triage_min_interval_s` | 0 (off) | minimum seconds between paid ticks, capped at 86400 |
| `TRIAGE_MAX_RUNS_DAY` | `lane.run-triage.<p>.triage_max_runs_day` | 0 (unlimited) | paid ticks per rolling 24h |

**The ledger counts paid launches, not gate answers.** `triage_throttle_record`
writes one row to `state/triage-throttle/<p>.runs` in `rt_launch`
(bin/lib/rt/launch.sh) immediately before the agent call, and in `rt_shards`
when a tick dispatched at least one shard. A tick the gate let through that then
bought nothing (scope.sh's "event-wake named no board object") uses no slot.

Never held: `forced`, `forced-env` (an operator), `daily-sweep`, `no-gate-state`
(the safety net) and `event-wake` (a webhook; bin/wake-loop.sh's own cooldown is
its limiter). A held tick spends nothing, reports `LANE_TICK paused`, and logs
`rc=skip :: gate RUN <reason> held — throttle …` in `logs/<p>.log`. The pending
board fingerprint is not consumed, so the change is worked on the next allowed
tick.

**Maximum wait for a client's reply:**

| Board | Added wait from the throttle |
|---|---|
| webhook-backed (the reply arrives as `event-wake`) | none: the next cron tick, <= 10 min |
| no webhook (the reply arrives as a board diff) | <= `TRIAGE_MIN_INTERVAL_S` while under the ceiling; if the ceiling is spent, until the 24h window rolls or the daily sweep, whichever is first (<= 24h) |

Which projects get rows is an operator decision; nothing is seeded.

## 3. Board/repo health precondition

`triage_health_check` in the same lib, asked before the throttle, and ONLY for
gate reasons that need the board read: `board-changed`, `daily-sweep`,
`event-wake`, `no-gate-state`, `gate-fetch-failed`, `gate-error`. A
`queue-pending`, `split-ready`, `results-sweep` or `remote-results-pending` tick
works from local records and proceeds; `forced` always runs. The project is
unhealthy while:

- `has_repo=false`: fleet.conf names no repo, the project is not in fleet.conf,
  or, with `TRIAGE_HEALTH_NEED_CLONE=1` (ships 0, because
  `bin/run-triage.sh` runs without a checkout by design), there is no checkout at
  `$REPOS_ROOT/<p>`;
- `has_board=false`: no board prefix, or an in-app prefix with no base URL;
- the board fetch failed `TRIAGE_HEALTH_FETCH_FAILS` (default 3) consecutive gate
  ticks. The gate fails open on that (`RUN gate-fetch-failed`), so a dead board
  is the one that pays every tick. `triage_health_note` feeds every gate answer
  into the streak (a `SKIP no-change` is a read that worked; a `RUN gate-error`,
  the gate script itself dying, is not a fetch failure and counts for nothing),
  and one re-probe (`bin/triage-gate.sh <p> --pending`, no model) runs before the
  verdict;
- `state/triage-health/<p>.down` exists: an operator writes the reason into it.

There is **no** read of `state/claude-auth-down.txt`: that file holds short
labels (`small`, `hub`, `<box>-openrouter`) and lives only on the hub, so it
could never match a box. Carrying the hub's auth verdict to the boxes as a
per-project `.down` marker is follow-up work in the auth lane.

A hold goes to the warn digest through `bin/lane-alert.sh --id
triage-health:<p> --severity warn`, once per project per UTC day
(`flags/alerted-triage-health-<p>-<date>`), and the tick reports
`LANE_TICK paused`. Nothing names a project. `TRIAGE_HEALTH_GATE=0` or
`flags/triage-health-off` turns it off.

## Tests

- `tests/preplan-skip-small.p2-test.sh`: A the decision (size, kind and its
  exact vocabulary, board title, mid-build, knob, flag, fail-open); B the real
  tick launches only the worth-buying key, logs once, and leaves
  `planned-files.txt` (free tiers) behind; C the real `bin/run-preplan.sh` never
  reaches `agent-call.sh` for a size=S key and leaves the list but no plan.md;
  D the real `bin/planned-files-cheap.sh` never reaches its model tier when
  free-only.
- `tests/triage-throttle.p2-test.sh`: T1-T7 cadence, ceiling, exempt reasons
  (wakes pass the ceiling), garbage knobs, the check never writes; R1-R7 through
  the real `rt_gate`/`rt_launch`: the launch records, a wake that skips uses no
  slot, a hold reports `paused`, the shard dispatch records.
- `tests/triage-health.p2-test.sh`: H1-H8 each health fact, the streak and its
  re-probe (gate-error ignored), the auth file ignored, the switch; R1-R6 through
  the real `rt_gate`: only board reasons held, one lane-alert a day, `paused`.
