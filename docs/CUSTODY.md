# Custody: who holds a decision the harness cannot make alone

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

Deferred to the slices after #9554 (the custody table, the lease and the
custodian dispatch): `plan_stale` requeue, `plan_blocked` defaults, orphaned
build retries, `ABANDONED` release and re-plan, parked queue rows and the
un-ingested results deadline. BH-10057 slice C0 shipped the resolver timeout ladder: a
timed-out fix round is retried with a larger agent budget (`BR_FIX_TIMEOUT_RETRY_PCT`, 150 %)
and a large park buys 2 fix rounds (`BR_MAX_FIXROUNDS`, registry default 2).
