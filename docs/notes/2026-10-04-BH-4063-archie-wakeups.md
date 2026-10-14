# Archie wakes on events, not only on his schedule (BH-4063, wave 2 of #3966)

Doc: DB-COORDINATION-SPEC, OPERATOR-SETUP

## What changed

Archie's tick (`bin/archie.sh`) now runs `bin/lib/archie-wake.sh` after its
lock and before the due read. Each collector turns an event into a **wake**:
the initiatives it concerns are marked due now, and the event is written to
`state/archie/wake-context/<id>.txt`, which the next check of that initiative
carries in its prompt ("Events this check is answering") and deletes once the
model has answered. Wave 1's check path, model route (`stage.archie`) and beat
path are unchanged. There is no second call site.

| source | read from | fingerprint (ledger `archie_wake` key) | wakes |
|---|---|---|---|
| merge | `job_ledger_list merge 200`, status `merged` | `merge:<pr url>` | initiatives linked to the PR's ticket (`job_pr_facts` col 3) |
| replan | `logs/decisions.log` `gate=replan scope=child <KEY> :: replan-escalate :: <decision>` | `replan:<KEY>:<cksum(decision)>` | linked, else factory-watch |
| outcome | `logs/outcome-metrics.csv` | `outcome:<pr>:<outcome>` | linked; a `reworked` row also wakes every initiative whose text says rework |
| budget | `logs/ALERTS.log` `[<lane>] DAILY SPEND CAP:` | `budget:<lane>:<day>` | factory-watch |
| alert | other `logs/ALERTS.log` lines (never Archie's own `archie:` lines) | `alert:<cksum(line minus stamp)>:<day>` | `ARCHIE_WAKE_ALERT_SCOPE` 1 linked only, 2 also factory-watch, 0 off |
| followup | `pending` `archie_followup` rows with `due_at <= now` | `followup:<key>` | the row's initiative, else factory-watch |

An initiative's links are the ticket numbers its goal, metric query,
escalation rule and link URLs name: `#N`, `BH-N`, `/issues/N`, `/pull/N`, and
ranges `#A–#B` / `#A-#B` (at most 50 numbers).

- **One event, at most one wake.** `job_ledger_get archie_wake <fp>` comes
  first. Absent: put `claimed`, write the context, mark due, put `woken <ids>`.
  Present: skipped. Outage (rc 1): nothing is woken and that source's cursor
  stops before the event, so the next tick retries it. Several events on one
  initiative in one tick give one check.
- **Cursors** live in `state/archie/cursors/<merge|replan|outcome|alerts>`. A
  missing cursor is a baseline (EOF, or the newest merge row) and wakes nothing.
  A shrunk file is read again from 0, and the ledger absorbs the re-read.
- **Mark due.** Wave 1 has no "due now" verb, and `next_check_at` only moves
  when a slot closes. So a woken initiative's future slot is closed `silent`
  through `POST /api/initiatives/check` with `advance_to=<now>`, and only when
  that slot has no event yet.
- **A woken check is not silenced by the escalation rule.** It answers its
  events. A blank answer still sends nothing.
- **factory-watch** is created the first time an initiative-less event needs
  it, through wave 1's idempotent `POST /api/initiatives` (goal `Factory watch`,
  metric `none`, rule `change`, every 2160h). On its own schedule it is always
  silent and makes no call. A dropped factory-watch stays dropped.
- **Follow-ups.** `bin/archie-followup.sh add <3d|YYYY-MM-DD> <note> [--initiative I<n>]`
  (or a `FOLLOWUP: <when> :: <note>` line in a check's answer, at most 3, cut
  from the beat) writes ledger `archie_followup` `fu-<sha8(initiative|due day|note)>`
  `pending` with detail `{due_at, initiative_id, note}`. The first tick at or
  after `due_at` wakes it and puts the row `fired`. Rows are never deleted.
- **Beat gate.** Wave 1's one beat send goes through `archie_beat_gate`. In quiet
  hours (`ARCHIE_QUIET_FROM_H` to `ARCHIE_QUIET_TO_H` UTC, equal = none, which is
  the default) or past `ARCHIE_BEAT_CAP_DAY` (default 5; ledger
  `archie_beatday <day>` holds the count), the beat is held as `archie_digest`
  `dg-<sha8(line)>` `queued`, and the slot still closes `sent`. The first
  allowed tick sends every held row as ONE digest beat (counted as one; at cap
  0, one digest a day), oldest first, up to 3500 characters, with the rest
  named and left queued. A row goes `sent` only after the send succeeded.
  `state/archie/digest-queued` says something is held, so a tick with nothing
  held reads no digest rows.
- **Off:** `flags/archie-wake-off` (`catalog/switches.d/archie-wake-off.json`)
  stops the collectors and follow-up firing. Scheduled checks and the beat gate
  keep running.

## What to set

Quiet hours are off until someone sets them. the operator's timezone is not recorded
anywhere, so the hours are his to choose: settings rows
`lane.archie.ARCHIE_QUIET_FROM_H` / `lane.archie.ARCHIE_QUIET_TO_H` (UTC).

## Where this differs from the plan

- The alert knob is `ARCHIE_WAKE_ALERT_SCOPE`, not the plan's
  `ARCHIE_WAKE_ALERTS`: its 0/1/2 value is a scope, and `_ALERTS` reads like a
  count or a switch.
- The suite is `tests/archie-wakeups.bh-4063-test.sh`, not the body's
  `tests/archie-wakeups-test.sh`, because suites are named per ticket.

## Verify

`HARNESS_TEST_SANDBOX=1 bash tests/archie-wakeups.bh-4063-test.sh`. On the hub,
`bin/archie-followup.sh add 1d "QA probe"` and then `bin/archie-followup.sh list`
show one pending row. The next day `logs/archie.log` has `wake: events=1`.
