# BH-1300: a pool project's build ceiling can no longer drop in silence

**What happened, twice.** BH-1279's note records it: on 2026-09-20 and again on
2026-09-21 ~20:40Z the jobs worker's schema re-apply resurrected the deleted
`repo/*/build = 1` row, every pool-routed project went from unlimited to ONE
build at a time, and nobody was told. project-5 sat at queue depth 5 with 13
`ai-build` tickets waiting from 20:40Z to ~22:00Z. The number was in the
fleet-status snapshot the whole time — the ceiling was rediscovered by a human
reading `fleet_status.rules`. Nothing compared it to the number from ten
minutes earlier. BH-1279 deferred that comparison; this is it.

**What ships.** `bin/concurrency-ceiling-watch.sh`, run by
`bin/fleet-status-push.sh` on the hub's `*/10` lane, AFTER the watchdog push and
the console beat (the same placement and the same reasoning as BH-1000's lease
block: nothing here may cost the dead-man signal). Each tick it reads
`bin/concurrency-plan.sh --json`, keeps the `route == "pool"` rows, compares
each one's `effective` against its own previous observation, and raises exactly
one warn when a ceiling dropped with no rule-set behind it. The line it would
have written on 2026-09-21, wrapped here and one line in the file:

```
2026-09-21 20:41:02Z [orchestrator/fleet-status] build ceiling for project-5
dropped unlimited -> 1 (bound by repo-rule 1) with no rule-set since
2026-09-21T20:30:58Z; bin/concurrency-plan.sh project-5 shows every cap,
bin/jobs-client.sh rule-set raises it
```

**"No rule-set since the previous snapshot" is read off `updated_at`, because
there is no ledger entry to read.** `rule-set` is not a ledger command:
`bin/jobs-client.sh rule-set` PUTs `/api/rules` and the worker stamps
`concurrency_rules.updated_at` (`worker/jobs/src/routes/rules.js`). That stamp
is the only durable trace a cap change leaves anywhere. So the evidence is the
`updated_at` of the row that BINDS for that project — `caps_rule_at` in
`bin/lib/build-caps.sh`, walking `caps_rule`'s own ladder, because a stamp read
off a different row is evidence about a cap nobody is looking at. A stamp inside
the window is an operator and the watch stays quiet; the seed's own
`2026-08-29T00:00:00Z` on a row whose number moved that morning is the incident.
A MISSING stamp (an older five-column client, a corrupt row) ALERTS: absence of
evidence is not approval, and the silence is what this exists to end.

**Pool only.** On the pool route the only caps that bind are the fleet-wide pool
cap and the repo rule, both of which read correctly from the hub. A local or
fly1 project's binding numbers are flags on ITS box, so from the hub they are
unverified — alerting on the hub's view of another box's `BUILD_SLOTS` would be
a page about nothing.

**The store.** `state/concurrency-ceiling.json` on the hub, one entry per pool
project (shape, with illustrative values):

```json
{ "project-5": {"effective":"unlimited", "bound_by":"pool-cap 20", "as_of":"2026-09-22T10:10:00Z"} }
```

A two-observation watermark, not a ledger of record: losing it costs one silent
tick (the next run rebuilds the baseline) and never a false alert. Written
tmp+mv, AFTER every alert decision for the tick — a crash between the send and
the write re-evaluates next tick and the `--id` absorbs the duplicate, so
"stamped but never delivered" cannot happen. A row the hub could not read
(`effective` = `?`) is skipped whole: not compared, not stored.

**Once per change, not per tick.** The store makes a re-observed ceiling not a
drop at all, and the alert id is `concurrency-ceiling-<project>-<old>-to-<new>`,
so a second distinct drop (4 -> 1 after unlimited -> 4) is its own condition
with its own line while a repeat of the same one is suppressed by
`bin/lib/alert-state.sh` on top. A RISE is silent and sends no `--resolve` —
the ticket asked for a drop alert, and a resolve writes its own ALERTS.log line.
Severity is `warn` (the batched digest), never `--critical`.

**What it touches.** `bin/lib/build-caps.sh` (new `caps_rule_at`),
`bin/lib/jobs/jobs.sh` (`job_rules` prints `updated_at` as a sixth TSV column —
every existing reader takes columns 1-5 by index, so it is additive),
`bin/concurrency-plan.sh` (new `db_rule_updated_at` key in `--json`, appended as
the last TSV field so the human table's `_rest` absorbs it),
`bin/concurrency-ceiling-watch.sh` (new), `bin/fleet-status-push.sh` (the tail
block that calls it, under its own `timeout 60`). Pinned by
`tests/concurrency-ceiling-watch.bh-1300-test.sh`, which drives the real plan
over a scratch harness and runs the whole `fleet-status-push.sh` for case 8.

Doc: BUILD-CONCURRENCY, ALERTS-STATE-MACHINE
