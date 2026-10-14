# Archie tells the operator once when a metric is unreadable (BH-4765, BH-4760.1)

Doc: OPERATOR-SETUP

## Why

Since BH-4609 an unreadable metric re-checks daily, but it never makes a call
and never sends a beat. The live I1 initiative read `unreadable` for days and
the operator heard nothing. An unreadable metric is itself a finding: the goal has no
number until its source is fixed.

## What changed

`bin/archie.sh` tick, step 5, for an initiative with a `metric_query` other
than `none`:

- **Readable metric.** The box-local marker
  `state/archie/unreadable-told/<id>` is removed, and the check runs as before.
- **Unreadable, marker present.** No change from BH-4609: event `unreadable`,
  advance `min(ARCHIE_UNREADABLE_RECHECK_H, cadence)` hours, no call, no beat.
- **Unreadable, no marker.** One told check:
  - The escalation rule is skipped.
  - The prompt carries `check.metric_unreadable: true` (the contract is the
    "When the metric is unreadable" section of `catalog/prompts/archie-check.md`).
    Every other check carries `false`.
  - When `ARCHIE_LLM_MAX_USD=0` or `stage.archie` has no route, there is no
    call and no attempt event. A fixed sentence is used, with class
    `ticket-file`: "I can't read the metric for I<id> (<metric_query>), so this
    goal has no number until the source is fixed. I'd file a ticket for the
    source." The same sentence replaces a blank or no-action answer.
  - The decision is recorded and the body is composed as for any check. The
    body reads `Metric: unreadable (<rule>)`, and the stored value stays null.
  - `sent` advances the same re-check hours, not a full cadence.
  - The marker is written only after `archie_beat_gate` returns 0. A failed
    beat leaves the slot `composed` and writes no marker; the next tick resends
    the stored body with no second call, and then writes the marker.

## Limits

- The marker is box-local. After a hub failover the new hub tells once more:
  at most one repeat, never silence.
- A beat held for the digest (quiet hours, today's `ARCHIE_BEAT_CAP_DAY`) counts
  as told, because `archie_beat_gate` returns 0 for it.
- A marker write that fails is one `warn:` line in `logs/archie.log`, and the
  next re-check tells again.
- An attempt cap or a budget-stop cap on the told call closes the slot as
  `model_failed` with no marker, so the next re-check tries again.

## Tests

`tests/archie-unreadable-told.bh-4765-test.sh` (U1-U8, through the real
`bin/archie.sh tick`). `tests/archie-initiative-tracer-test.sh` T6 and
`tests/archie-check-retry.bh-4609-test.sh` R9, R10 and R12 seed the marker, so
they still pin the already-told path.
