# Custody: who holds a decision the harness cannot make alone

## Ticket custody (BH-9554)

Custody answers three questions for each open ticket: which lane owns it now,
until when, and what must happen next by when. One D1 row per ticket holds
the answer. Ownership is a lease with an expiry, not "an artifact exists".

Ticket: #9554. This section describes slice C0, which is the table, the routes, the
shell library and this contract. Lines marked **(C1)**, **(C2)** or **(C3)**
describe later slices. Those slices are not on main yet.

### Why

Before custody, ownership came from artifacts. `bin/orphan-reconcile.sh`
treats a queued, claimed or running ledger row as the owner (class a), and
any open PR as the owner "whatever state that PR is in" (class b). A stuck
artifact therefore made its ticket read as owned, and no reconciler took it.
The audit for #9554 counted 835 open alerts, 74 `abandoned` ledger rows, and
queue rows up to 6.7 days old.

### The store

Both tables are in the jobs D1. The fragment is
`worker/jobs/schema.d/*-bh-9554-custody.sql`.

`ticket_custody` has one row per `(project, ticket)` (UNIQUE):

| Column | Meaning |
|---|---|
| `state` | A lifecycle phase (`worker/jobs/src/lib/lifecycle.js` `LIFECYCLE_PHASES`). `merged` and `closed` come only from settle. |
| `owner_lane` | The lane that owns the ticket, or `custodian` after a release. It is NULL only on a settled row. |
| `lease_expires_at` | The time the owner's lease ends (ISO). NULL means no lease. |
| `next_action` | One word from the action vocabulary below. |
| `deadline_at` | The time the next action is due (ISO). |
| `due_at` | The earlier of `deadline_at` and `lease_expires_at`. Every write sets it. |
| `attempt` | The custodian's action count in this state. It goes back to 0 when the state changes. |
| `ladder_rung` | The custodian's rung on the state's ladder. |
| `last_evidence` | The last evidence text a writer gave (500 characters max). |
| `pr_number` | The ticket's PR, when it has one. |
| `rev` | +1 on every write. Every write is a compare-and-set on it. |
| `settled_at` | Set when the ticket merged or closed. A settled row is out of every open read. |
| `created_at`, `updated_at` | Server times. |

`custody_actions` is append-only. Each accepted custody write adds one row:
`actor`, `action`, `why`, `result`, plus the row's `state`, `attempt` and
`ladder_rung` after the write. The row goes in the same D1 batch as the change,
under the same `rev` guard. A refused write (400, 404 or 409) writes no row
in either table.

### States and default deadlines

A write that gives no `deadline_at` and no `deadline_min` gets the default
for its state. The default is a settings row. The code constant
(`DEADLINE_DEFAULT_MIN` in `worker/jobs/src/routes/custody.js`) is only the
fallback. The route uses it when the row is not a whole number. The defaults
are the same as the `lifecycle.stuck.*` thresholds, so the two views agree.

| State | Settings row | Seed (minutes) | Code fallback |
|---|---|---|---|
| `triaged` | `custody.deadline.triaged_min` | 120 | 120 |
| `planned` | `custody.deadline.planned_min` | 120 | 120 |
| `plan_blocked` | `custody.deadline.plan_blocked_min` | 1440 | 1440 |
| `building` | `custody.deadline.building_min` | 180 | 180 |
| `pr_open` | `custody.deadline.pr_open_min` | 1440 | 1440 |
| `in_queue` | `custody.deadline.in_queue_min` | 120 | 120 |
| `ejected` | `custody.deadline.ejected_min` | 30 | 30 |
| `abandoned` | `custody.deadline.abandoned_min` | 60 | 60 |
| `merged`, `closed` | none | the row settles | |

Other knobs (settings rows; the code fallback has the same value):

| Row | Seed | Meaning |
|---|---|---|
| `custody.lease_s` | 1800 | The lease length when a claim or renew names none. |
| `custody.lease_max_s` | 86400 | A longer `lease_s` is a 400. It is never clamped. |
| `custody.deadline_max_min` | 43200 | A deadline more than 30 days after now is a 400. |
| `custody.due.limit` | 200 | The number of rows one `GET /api/custody/due` returns. |
| `retention.ticket_custody.settled_days` | 7 | Settled rows older than this are deleted. |
| `retention.custody_actions.days` | 90 | Action rows older than this are archived, then deleted. |

### Action vocabulary

`next_action` (and the `action` of `POST /api/custody/act`) must be one of
the words below. Any other word is a 400. This makes sure that no row holds an
action the custodian cannot dispatch.

| Word | What the custodian does (C1 maps each word to an existing script) |
|---|---|
| `reoffer` | Offer the ticket to its lane again (the stranded re-offer). |
| `requeue_build` | Put the ticket back in the build queue. |
| `resolver` | Run the blocked-PR resolver on the ticket's PR. |
| `retriage` | Send the ticket back to triage. |
| `return_todo` | Return the ticket to todo (or remove `ai-build`) with a board comment. Every ladder ends here. |
| `wait` | No action. The custodian checks the row again at the deadline. |

### Ladders (C1)

When a row is due, the custodian takes the next rung of the ladder for the
row's state. Each rung is one `POST /api/custody/act` call: `attempt` goes up
by 1, and `ladder_rung`, `next_action` and the deadline are set. Every ladder ends
in `return_todo`. No ladder ends in "alert only". C1 seeds the ladders as
`custody.ladder.<state>` rows and one kill flag per action kind as
`custody.kill.<action>` rows (default on). The rungs below are C1's starting
point.

| State | Rung 1 | Rung 2 | Rung 3 |
|---|---|---|---|
| `triaged` | `reoffer` | `retriage` | `return_todo` |
| `planned` | `reoffer` | `requeue_build` | `return_todo` |
| `plan_blocked` | `wait` | `retriage` | `return_todo` |
| `building` | `reoffer` | `requeue_build` | `return_todo` |
| `pr_open` | `resolver` | `requeue_build` | `return_todo` |
| `in_queue` | `wait` | `resolver` | `return_todo` |
| `ejected` | `resolver` | `requeue_build` | `return_todo` |
| `abandoned` | `retriage` | `return_todo` | |

### Lease rules

"Now" is always the jobs worker's clock for the request, never a box clock.

| Verb | Accepted when | Effect | Refused |
|---|---|---|---|
| `claim` | There is no row; or the row is settled; or the owner is this lane; or the owner is `custodian`; or the owner's lease is not live (`lease_expires_at <= now`). | Owner = lane, lease = now + `lease_s`, state, next action, deadline. `attempt` and `ladder_rung` go back to 0 when the state changes or the row was settled. | 409 `held`. The body names the owner and the lease end. |
| `renew` | The lane owns the row, and the row is not settled. | Lease = now + `lease_s`. | 409 `not_owner`; 404 `no_row`. |
| `release` | The lane owns the row. | Owner = `custodian`, no lease. The next action is required; the deadline is the given one or the state's default. | 409 `not_owner`; 404 `no_row`. |
| `next` | The lane owns the row (its lease is live, or its own lease ended and nobody took the row). | Next action, deadline, and optionally state, PR and evidence. | 409 `not_owner`; 404 `no_row`. |
| `settle` | The row exists. | `settled_at` = now, state `merged` or `closed`. Owner, lease, next action, deadline and `due_at` are cleared. | 404 `no_row`. A second settle is 200 `duplicate:true` and writes no action row. |
| `act` | `attempt` equals the caller's `expect_attempt`, and the row is not settled. | `attempt` + 1, `ladder_rung`, next action, deadline, and one action row with the custodian's action, why and result. | 409 `stale` or `settled`. |

Lane names compare exactly: `Pool` is not `pool`. A lane may not call itself
`custodian`. The key is `(project, ticket)`, so the same ticket key on two
projects is two rows.

#### What counts as owned

A row is **owned** when all of these are true:

- `settled_at` is NULL,
- `owner_lane` is a lane (not NULL and not `custodian`),
- `lease_expires_at > now`.

A released row, a row whose lease ended, and a settled row are not owned.
`GET /api/custody/row` reports `owned`. C3 replaces the artifact-based owner
checks with this rule (orphan-reconcile classes a and b, the triage-state lib,
the PR-ownership sweep).

#### Due

A row is **due** when `settled_at IS NULL AND due_at < now`. That is
exactly "the deadline passed, or the lease ended". `due_at == now` is not
due yet. `GET /api/custody/due` returns due rows, oldest first, with
`truncated` when there are more than the limit.

### Routes

All routes are behind the `HARNESS_SECRET` bearer
(`worker/jobs/src/routes/custody.js`):

- `POST /api/custody/claim` `{project, ticket, lane, state, next_action, deadline_at? | deadline_min?, lease_s?, pr?, evidence?}`
- `POST /api/custody/renew` `{project, ticket, lane, lease_s?}`
- `POST /api/custody/release` `{project, ticket, lane, next_action, deadline_at? | deadline_min?, evidence?}`
- `POST /api/custody/next` `{project, ticket, lane, next_action, state?, deadline_at? | deadline_min?, pr?, evidence?}`
- `POST /api/custody/settle` `{project, ticket, actor, state: merged|closed, evidence?}`
- `POST /api/custody/act` `{project, ticket, actor, expect_attempt, action, why, result, next_action, deadline_at? | deadline_min?, ladder_rung?}`
- `GET /api/custody/due?limit=`
- `GET /api/custody/row?project=&ticket=`
- `GET /api/custody/gaps?project=`: `{no_owner, no_deadline}`, the open rows that break the invariant "every open row has an owner and a deadline".

A 200 always has `ok: true`. A bad field is 400 `{error: <field>}`.

Every write reads the row, decides in code, then sends one batch. The batch
holds the action insert and the custody write, both guarded on the `rev` the
read saw. A writer that lost a race writes nothing and gets 409.

### The shell library

`bin/lib/jobs/custody.sh` holds `custody_claim`, `custody_renew`,
`custody_release`, `custody_next`, `custody_settle`, `custody_act`,
`custody_due`, `custody_row` and `custody_gaps`. The jobs client verb is
`custody <sub> ...` (`bin/jobs-client.d/bh-9554-custody.sh`):

```bash
bin/jobs-client.sh custody claim <project> <ticket> <lane> <state> <next_action> [--lease-s N] [--deadline-min N|--deadline-at ISO] [--pr N] [--evidence TEXT]
bin/jobs-client.sh custody renew <project> <ticket> <lane> [--lease-s N]
bin/jobs-client.sh custody release <project> <ticket> <lane> <next_action> [--deadline-min N|--deadline-at ISO] [--evidence TEXT]
bin/jobs-client.sh custody next <project> <ticket> <lane> <next_action> [--state S] [--deadline-min N|--deadline-at ISO] [--pr N] [--evidence TEXT]
bin/jobs-client.sh custody settle <project> <ticket> <actor> <merged|closed> [--evidence TEXT]
bin/jobs-client.sh custody act <project> <ticket> <actor> <expect_attempt> <action> <why> <result> <next_action> [--deadline-min N|--deadline-at ISO] [--ladder-rung N]
bin/jobs-client.sh custody due [limit]
bin/jobs-client.sh custody row <project> <ticket>
bin/jobs-client.sh custody gaps [project]
```

Return codes:

| rc | Meaning |
|---|---|
| 0 | 200 with `ok: true`. The body is on stdout. |
| 9 | 409, a refusal (`held`, `not_owner`, `stale`, `settled`). The body is on stdout. No alert. |
| 2 | 404, no custody row. No alert. |
| 1 | **Fails loud.** Transport error, 5xx, 400, a 200 without `ok: true`, an empty `JOBS_URL` or no `HARNESS_SECRET`. One alert (`bin/alert-line.sh --id custody-unreachable-<project>`) and one stderr line. |
| 3 | Bad arguments. One usage line. No request is sent. |

On rc 1 the lane must stop its transition. The library has no file fallback
and no retry loop (the transport retries a transport error once). The
transport's own once-a-day ALERTS line is off for these calls, so one failed
call makes one alert.

### Acting from the first merge

The write path has no shadow, observe-only or dry-run mode. A claim writes on
its first call, and no setting turns the writes off. The custodian lane (C1)
acts from its first run. One kill flag per action kind stops one kind of
action. A cap that is reached raises an alert and does not stop builds.

### Write path, by slice

| Lane seam | Verb | Slice |
|---|---|---|
| Triage enqueue | `claim` (`triaged`) | C2 |
| Pool claim and spawn | `claim` (`planned` / `building`), `renew` on the heartbeat | C2 |
| Plan result | `next` (`planned` or `plan_blocked`) | C2 |
| Execute result | `next` (`pr_open`) or `release` | C2 |
| Review | `next` | C2 |
| PR open | `next` (`pr_open`, `--pr`) | C2 |
| Conductor state changes | `claim` / `next` (`in_queue`, `ejected`) | C2 |
| Blocked resolver | `claim` / `release` | C2 |
| Settle (merge or close) | `settle` | C2 |
| Custodian | `due`, `act` | C1 |
| Owner checks (orphan-reconcile, triage-state, PR-ownership sweep) | `row` (`owned`) | C3 |

In C0 the routes and the library have no production caller. The legacy file
markers stay. Lanes keep writing them until a later ticket removes them.

### Retention

- `ticket_custody.settled` deletes rows settled more than
  `retention.ticket_custody.settled_days` ago. These are state rows: the
  history stays in `custody_actions`. An open row is never a candidate.
- `custody_actions.age` copies rows older than `retention.custody_actions.days`
  to the archive D1, then deletes them. It never only deletes them.

Both rules run in the hourly `d1-retention` lane
(`worker/jobs/src/routes/retention.d/bh-9554-custody.js`), under the fleet's
`retention.dry_run` and `retention.max_rows` caps.

### Tests

- `worker/jobs/test/custody.bh-9554.test.js`: the claim decision table, the 400 fields, the `act` CAS, the due table.
- `tests/custody-schema.bh-9554-test.sh`: the columns, the settings rows, EXPLAIN at 50,000 rows, the action rows, retention.
- `tests/custody-lease.bh-9554-test.sh`: claim, refusal, expiry, release, owned, round trip, settle, all through the jobs client verb.
- `tests/custody-db-down.bh-9554-test.sh`: rc 1 and one alert for each failure, and no alert for 409 or 404.

## Human gates

A human gate is one question the harness asks a person. It is one row in the
jobs D1 table `human_gates`, written by `POST /api/human-gates`
(`worker/jobs/src/routes/human-gates.js`). The shell side is
`bin/lib/human-gate.sh`: `hg_ask`, `hg_class`, `hg_plan_blocked`, `hg_release`.

### The 5-field format

Every gate is asked in this block, printed by `hg_ask` only after the row is
written:

```
Question: <question>
Recommended answer: <recommended>
Reasons: <r1>; <r2>; <r3>
Default: <default>
Deadline (UTC): <YYYY-MM-DD HH:MM> UTC
```

`hg_ask` refuses (rc 2, one stderr line, no row) a call with no recommended
answer, no default, or 0 or more than 3 reasons. The worker refuses the same
body with a 400. If the POST fails, `hg_ask` prints nothing (rc 1), so the
caller keeps its old text: a deadline is printed only when a row backs it.

The first caller is the planner block. A PLAN_BLOCKED build
(`bin/lib/rb/plan.sh`, `# >>> plan blocked gate`) calls `hg_plan_blocked`
(lane `plan`, reason `plan_blocked`). It writes one gate per question of the
plan's client-questions block to `<build>/human-gates.md`, and `pb_notice`
(`bin/lib/plan-blocked.sh`) posts that text in the ticket comment. A re-plan
that asks the same question again re-asks the same row (same deadline). A
reworded question is a new row.

### Gate classes

The class of a gate comes from the settings row `human_gate.class.<reason>`:

- `irreversible`: `migration-gated`, `hotfix-migration-hold`, `provenance`,
  `security-allowlist`.
- `defaultable`: `plan_blocked`, `tightened`, `verdict-contradiction`, `nhv`,
  `tackler`, `needs-human`, `hold`, `parked`.

An unknown reason is irreversible. Only the exact value `defaultable` reads
defaultable: a wrong case, a near miss, an empty reason or a missing row is
irreversible. An irreversible gate never auto-applies its default.

### Settings rows

- `human_gate.deadline_hours` (24): the deadline when the caller gives none.
- `human_gate.hold_review_days` (7), `human_gate.digest_hour_utc` (7).
- `human_gate.retention_days` (90): see Retention.
- Kill flags, each default 1: `human_gate.format.enabled` (0 = `hg_ask` prints
  nothing and writes no row), `human_gate.default.enabled`,
  `human_gate.digest.enabled`, `human_gate.reask.enabled`.

### Table and retention

`human_gates` is unique on `(repo, key, lane, question_fp)`. `question_fp` is
the first 16 hex characters of SHA-256 over the question, trimmed, whitespace
collapsed and lowercased; the worker computes it. A re-ask stamps
`asked_again_at` and never changes `status`, `answer` or `deadline_at`.

The retention rule `human_gates.archive`
(`worker/jobs/src/routes/retention.d/bh-9559-human-gates.js`) copies a resolved
row (status not `open`) older than `human_gate.retention_days` to
`human_gates_archive`, then deletes it from `human_gates`, in one D1 batch. An
open row never moves. `retention.dry_run` applies.

### Releases

`hg_release <lane> <repo> <key> <answer>` sources
`bin/lib/human-gate-release.d/<lane>.sh` and calls `hgr_<lane>`. `hgr_plan`
requeues the ticket through `bin/queue-line-put.sh` with the answer in the
queue line. A lane file that defines no `hgr_<lane>` is rc 3.

### The parts that follow

- [Merge conductor](human-gates/conductor.md)
- [Defaults at the deadline](human-gates/defaults.md)
- [Digest and replies](human-gates/digest-and-replies.md)
- [Review dates](human-gates/review-dates.md)

## Lanes that act (BH-9556)

Three hub lanes computed a decision and acted on none of it. Their seed rows
said dry run or shadow, and an outage of the settings read looked the same as
those modes. Since BH-9556 (slice C0) each lane acts by default, keeps one kill
flag in a settings row, and treats a settings outage as an error.

| Lane | Acts by default | Kill flag | Missing row | Outage |
|---|---|---|---|---|
| `bin/needs-sweep.sh` | `console.needs.sweep_dry_run=0`: it applies | the row `1` (dry); `--dry-run` | apply (fallback 0) | exit 4, ONE alert `needs-sweep-settings`, no candidates read, no ledger row |
| `bin/scheduler.sh` | `scheduler.mode=enforce`: the ready set decides dispatch (BH-6979; a stale set falls back to today's path) | the row `shadow` or `off` | shadow (code default, as `bin/lib/sched-gate.sh`) | exit 1, ONE `SCHED-TICK error=settings-unreachable` line, ONE alert `scheduler-settings-unreachable`, no POST, `.last` not stamped |
| `bin/unblock.sh` | `unblock.enabled=1`, `unblock.project.<p>.mode=act`, `lane.unblock.unblock_act=1` (registry default `UNBLOCK_ACT` 1) | `unblock.enabled=0`; the project row `shadow`/`off`; `lane.unblock.unblock_act=0` | `unblock.enabled` missing runs | exit 1, ONE alert `unblock-settings-unreachable` (bin/lane-alert.sh), no collector, GitHub or ledger call |

The seed move. A schema.d statement cannot change a row (the schema is
additive). So the jobs worker runs ONE guarded batch on the first settings read
of each DB binding (`worker/jobs/src/lib/seed-moves.js`, called by
`GET /api/settings` and `GET /api/settings/<key>`). It moves
`console.needs.sweep_dry_run` 1 -> 0 and `scheduler.mode` shadow -> enforce,
each only while the row still has the seed value AND actor `seed`. A moved row
carries actor `seed:BH-9556`. An operator row (any other actor) is never moved,
so an operator's `1`, `shadow` or `off` stays the kill flag. `PUT /api/settings`
refuses actor `seed`. A failed batch is one `console.warn`, never a throw; the
next read retries. Rollback: write the old value with an operator actor.

Unblock already acted for cromford in prod (an operator wrote
`unblock.project.cromford.mode=act` and `lane.unblock.unblock_act=1` on
2026-10-26), so no row moves for unblock. The other projects keep their
per-project mode rows: the per-project flip is the operator's choice (BH-7727).

Deferred to the custody slices after C0 of #9554 (the custodian
dispatch and the lane write paths; see "Ticket custody (BH-9554)"): `plan_stale` requeue, `plan_blocked` defaults, orphaned
build retries, `ABANDONED` release and re-plan, parked queue rows and the
un-ingested results deadline. BH-10057 slice C0 shipped the resolver timeout ladder: a
timed-out fix round is retried with a larger agent budget (`BR_FIX_TIMEOUT_RETRY_PCT`, 150 %)
and a large park buys 2 fix rounds (`BR_MAX_FIXROUNDS`, registry default 2).
