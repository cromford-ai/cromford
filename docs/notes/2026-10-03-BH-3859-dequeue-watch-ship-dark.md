# dequeue-watch ships dark and reports once (BH-3859)

Doc: MERGIFY, MERGE-CONDUCTOR

## What changed

**It ships observe-only.** `DEQUEUE_WATCH_ACT` is 0 in three places: the
registry default (`catalog/lanes.d/dequeue-watch.json`), the code fallback in
`bin/lib/dequeue-watch/act.sh`, and a seed row
`lane.dequeue-watch.dequeue_watch_act = '0'` in `worker/jobs/schema.sql`. The
seed is `INSERT OR IGNORE`, so it lands on first registration only and an
operator's existing row is left alone. A dark tick classifies and claims
`observe` rows and logs `WOULD_<ACTION>`, with no side effect.

**One observe report, then silence.** After `DEQUEUE_WATCH_OBSERVE_TICKS` full
observe ticks (default 12, so 1h at `*/5`), the lane posts one warn through
`bin/lane-alert.sh` with id `observe-report:dequeue-watch`. It says how many
ticks it watched, how many `WOULD_` actions on how many PRs, the count per
action, up to five example lines, and the command that lets it act:
`bin/harness-ctl.sh set dequeue-watch DEQUEUE_WATCH_ACT 1`. It never flips the
knob itself and never sends a second report. The counter lives in
`state/observe-report/dequeue-watch.json` on the hub (`since`, `ticks`,
`sent_at`); `sent_at` is written only after `lane-alert.sh` answered rc 0. The
code is `bin/lib/observe-report.sh` (`observe_report_tick`), which takes the
lane, N, its log and its flip command, so the next lane that ships dark can
reuse it. Acting ticks never count. The state file and the alert's own
`state/alerts/<id>.json` for `observe-report:dequeue-watch` are both hub-local, so a
hub-lease failover starts the count fresh on the new hub and can send one
more report there; nothing dedupes it across boxes. That is bounded at one
report per failover. (The plan's line that the open alert id suppresses a
failover duplicate is wrong for exactly this reason.)

**Ownership is per (pr, head, class).** This supersedes the sentence in
`2026-09-30-BH-3719-dequeue-watch.md` that a head with a live action row is not
gathered again. Now a head that already has a live action row for a class is
not acted on again for that class; a new dequeue run on the same head that
fails for a different class is gathered, classified and gets its own action.
Gather reads the class off THIS run's event row (the ledger is keyed by
`run_id`): no class yet means a new run, gathered in full. With a class, a live
action row of that class owns it and the log says
`already-owned (<class>/<action>, run <run_id>)`. An `observe` row owns it only
while the lane is dark, so a flip to 1 re-gathers and takes the row over. The
watchdog checks the class this tick claimed under, so a second class on the
same head is never resolved off the first class's row.

**Honest counters.** The summary line is now
`tick projects= dequeued= recorded= acted= would= owned= unread= stale= skipped=[ page-cut][ err=]`.
`acted=` counts only real actions (act mode 1, a side effect started).
`would=` is observe mode's `WOULD_` lines, `owned=` a claim another row
already held, `unread=` a fix-round count or claim that could not be read.

**A timed-out tick says so.** The 240 s timeout is no longer an `exec`: the
wrapper runs the tick as a child and, when `timeout` kills it (rc 124), writes
`<ts> tick timed-out` as that tick's one summary line.

## Commands

- Watch it dark: `grep -E 'WOULD_| tick ' logs/dequeue-watch.log`
- Let it act: `bin/harness-ctl.sh set dequeue-watch DEQUEUE_WATCH_ACT 1`
- Report sooner or later: `bin/harness-ctl.sh set dequeue-watch DEQUEUE_WATCH_OBSERVE_TICKS <n>`

Suites: `tests/dequeue-watch-ship-dark.bh-3859-test.sh`,
`tests/observe-report.bh-3859-test.sh`.
