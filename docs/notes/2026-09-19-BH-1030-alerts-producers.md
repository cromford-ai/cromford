# The box side of the alerts table: the row decides, the files follow

Doc: ALERTS-STATE-MACHINE, ALERT-REMEDIATION

BH-1068 shipped the `alerts` table, its seven client wrappers and the
`alerts_db_on()` gate, and nothing called them. This is BH-1030.2, the slice
where the producers start using the row: the state machine asks the worker for
its decision, the quarantine marks the row it queued, the flush valve drains the
worker's expired claims as well as this box's file, and the daily digest reads
parked rows. (A fifth producer, the fleet heartbeat's ssh line-count, was
scoped here too but dropped on rebase — see the `bin/fleet-heartbeat.sh`
paragraph below.)

Nothing here is on by default. With `flags/alerts-db` absent every script below
behaves exactly as it did yesterday and makes **zero** `/api/alerts*` requests —
`tests/alerts-table-test.sh` c0 drives all four scripts and asserts that count is
0, then runs the four neighbouring suites as subprocesses.

## What changed

**`bin/lib/alert-state.sh`.** `alert_state_note` takes a 4th argument, the
project, and gains a DB-first branch: `alert_note <id> <family> <box> <project>
<sev> <line> <reminder_s> <close_s>`, and on rc 0 the row's decision is what the
caller gets, with `state/alerts/<id>.json` written from the row as a
write-through cache. `alert_state_resolve` asks the table how many rows it
actually closed. Both fall back to today's file logic on rc 1 (outage) and rc 2
(route absent), log `db-miss id=… rc=…` when they do, and treat rc 9 (another box
won the compare-and-swap) as a `fire` — a race is a duplicate page at worst,
never a swallowed one. An answer that is not `<fire|remind|suppress> <int>` is
logged `rc=parse` and takes the file path too: absent is not a decision.

The request is made **outside** the per-id flock. The worker's CAS is the
serialisation point; holding a 5s-timeout local lock across a network call would
make every same-id sibling time out and print `fire 1`, which is the dedupe layer
manufacturing the duplicate page it exists to prevent.

**`bin/beat.sh`.** Passes the payload's `.project` into the note. In the
quarantine block the file append is FIRST and unconditional; only then, outside
the flock, `alert_state_set <id> quarantined beat` runs, and only a confirmed
mark stamps the queued payload `"dbrow":true`. That stamp is what tells
`alert-flush.sh` the DB pass owns the entry, so inventing it on a failed mark
would drop the alert from both paths. `"resolved":true` retractions are not
marked (a retraction is not a new incident to quarantine, and the worker would
409 it).

**`bin/lane-alert.sh`.** Passes `bin/project-of.sh`'s answer for the line, or
`fleet` when the line names no project. Nothing else; `--resolve` inherits the
library's new behaviour.

**`bin/poll-commands.sh`.** One `flag_active alerts-db` in the flags-beats block,
so the switch reaches a box the same apply-once way a pause does. The ALERTS.log
re-beat block is wrapped in `# >>> alerts re-beat` / `# <<< alerts re-beat`
markers and **keeps running** with the flag on — it is still the only path that
carries a line an emitter wrote straight into the log.

**`bin/alert-flush.sh`.** `H` now comes from `$HARNESS` (it was hardcoded, so the
valve could only ever be driven against the live tree). With the flag on it
claims expired rows with `alert_flush_claim`, POSTs each one to the console as
`[UNTRIAGED 45m] <line>`, and marks the row `new` **only** on a 2xx — a non-2xx
leaves the claim for the lease rather than recording a delivery that did not
happen. In the file pass a `"dbrow":true` entry past the cutoff is dropped
without a send, but only when the claim SUCCEEDED; a failed claim puts every
entry, stamped or not, back on today's path.

**`bin/alert-digest.sh`.** Daily mode reads `alerts_list --state parked` when the
flag is on: `PARKED_CNT` is the number, `PARKED_N` is what the reader sees, and
they differ in exactly one case — a truncated list says `500+` rather than
claiming a count nobody measured. Ages come from the row's `first_seen` against
one `NOW`. rc ≠ 0 falls back to `state/medic-parked.json`. `--warn-batch` is
untouched.

**`bin/fleet-heartbeat.sh`.** Dropped on rebase, 2026-09-22 — this ticket
scoped a change here (skip the remote `wc -l`/`tail` and the `hb-alert:` beat
while the flag is on), but BH-1031 deleted the file before this branch landed
on main: the ssh probe it ran, answering "can the hub reach this box", is
replaced by the DB-driven lane-liveness table (`lane_proc_beat` ->
`/api/lanes/tick`, read back by `bin/heartbeat-reaper.sh`), which answers a
different question ("is the lane alive") for reasons unrelated to this ticket.
There is no file left for the change to apply to.

## Known edge

With the flag on and the worker unreachable, `jobs-client.sh` writes its own
once-a-day "harness-jobs unreachable" line into `ALERTS.log` (its existing
contract, marker `flags/alerted-jobs-client-<date>`). That is one extra line a
day during an outage, not one per alert.

## How to drive it

    HARNESS_TEST_SANDBOX=1 bash tests/alerts-table-test.sh       # c0..c11
    HARNESS_TEST_SANDBOX=1 bash tests/alert-flush-ttl-test.sh    # c1..c6

Both build a scratch `$HARNESS`, run the real scripts from the checkout against a
fake curl, and read back the recorded requests, `ALERTS.log`,
`logs/alerts-state.log`, `state/alert-quarantine.jsonl` and
`state/alerts/<id>.json`. The two `poll-commands.sh` blocks are extracted by
their markers and sourced, so the assertions are about the code that ships.

Rollout is unchanged from BH-1068: deploy the worker routes, then
`bin/jobs-client.sh flag-set alerts-db on`. Until the routes exist the client
answers rc 2 and every script above takes today's path.
