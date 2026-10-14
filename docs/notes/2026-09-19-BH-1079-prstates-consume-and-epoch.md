# A skip-only triage tick consumes the board fingerprint, and the PR-state ledger never takes an older answer

Doc: EVENTS

BH-1015 put a per-ticket fingerprint in front of the money and a carried-forward
PR-state ledger behind it. Its round-2 review found two ways the pair still
spent, and four ways the ledger was unbounded or silent. All six are here.

## A — the tick that skipped every key never consumed

`bin/lib/rt/shards.sh` absorbed `state/<project>.gate.pending` into
`state/<project>.gate.json` only when it had actually dispatched something:

```sh
if [ "$SHARD_N" -gt 0 ]; then rt_gate_consume; fi
```

A key that the HELD path had re-armed out of `gate.json` therefore stayed out of
it for ever. Every following tick re-fetched the board, `bin/gate-diff.sh`
reported the same `NEW <id> "<title>"` line, the per-ticket fingerprint correctly
answered "unchanged, no session" — and `bin/triage-gate.sh` could never answer
`SKIP no-change`, because the file it compares the live fingerprint against was
missing the very ticket the board keeps reporting. So the tick paid for the board
round-trip, the diff and the fingerprint pass on every cron fire until the 4h
`TRIAGE_SHARD_FP_TTL_S` expired, then bought one spurious session, then started
over.

The condition is now `SHARD_N > 0 OR SHARD_SAME non-empty`. A key skipped as
unchanged has been verified against its own live board entry a few lines up, so
its pending fingerprint is absorbed exactly as if it had been dispatched — there
is nothing left to put back. **The order is load-bearing:** consume FIRST, re-arm
HELD/LEFT after, because `triage_shard_rearm` edits `gate.json` in place and a
re-arm before the `mv` would be overwritten.

`rt_gate_consume` also stamps `state/<project>.gate-meta`, the daily-sweep clock.
That is now stamped on skip-only ticks too. Harmless: any dispatching tick
already stamped it, and a project with a queue line exits at the gate's section 2
long before the daily-sweep branch.

## B — an older gate vector overwrote a newer ledger row

`triage_prstates_ingest` folds line 3 of `state/<project>.queuefp` (the gate's own
45-minute PR lookup) into the ledger. It stamped every pair with `now`, and
`_tsh_prstates_put` overwrites unconditionally.

Line 3 **survives** every tick the gate did not re-read on — the gate rewrites it
on one of its three write branches and erases it on the other two — so the same
`12=OPEN;` was re-ingested tick after tick, each time stamped as if it had just
been read. A `12 MERGED` the REST refresh had established minutes earlier was
replaced by that ten-minute-old `OPEN`, every key naming PR #12 flipped its
fingerprint, and each one bought a session on a merge that had already happened.

The epoch now comes from `queuefp` line 2 (the stamp the gate wrote beside the
vector), and a pair is written only when that epoch is **not older** than the one
already on file.

Not *strictly newer*: the gate writes `queuefp` and the tick's own REST refresh
stamps the ledger inside the same tick, so a freshly written vector routinely
carries the same second as the row it should replace. A strict compare dropped
that merge and held the stale value until the gate's next 45-minute window —
`tests/triage-shards-ticket-fp-test.sh` case (B) catches exactly this, and it is
pinned again as (B5) in the new suite. Equal seconds mean both sources read the
same GitHub at the same moment, so letting the vector land costs one identical
rewrite at worst.

A `queuefp` whose line 2 is not an epoch ingests NOTHING: a vector with no
readable age cannot claim to be newer than anything.

`_tsh_prstates_put` stays unconditional on purpose — the REST refresh has just
read GitHub, so its answer is by definition the newest thing anyone has. The
caller that replays a vector of unknown age does the compare itself.

## The four ledger rules around them

- **`MERGED` and `CLOSED` are terminal.** `triage_prstates_refresh` skips them
  before the age check, so neither is re-bought once per TTL for as long as its
  queue line lives. A reopen still reaches the ledger through the gate's vector,
  which is the only path that should move a terminal state.
- **A failed REST lookup is logged.** The value and its stamp are still kept (a
  transient outage must not turn a known `OPEN` into a `?` and buy a session for
  every key naming it), but silence made that indistinguishable from a successful
  read. One line per failed number, bounded by the loop's existing `head -20`:
  `<stamp> [<project>] prstates refresh: PR #<n> lookup failed — keeping <state> from <age>`.
- **Both PR lookups consult `bin/lib/gh-budget.sh` before they spend.** The
  refresh (lane `triage-prstates`) and the gate's own `gh pr view` loop (lane
  `triage-gate`) were each up to 20 silent calls per project per tick under
  rate-limit exhaustion. Low budget: the refresh carries every value and stamp
  forward, which is what a failed lookup already does; the gate leaves `PRV`
  empty, which is the branch it already takes on any `ERR` — `RUN queue-pending`,
  2-line `queuefp`, identical outcome, zero lookups. Unknown (rc 2: no library,
  or a `rate_limit` endpoint that did not answer) PROCEEDS, like every other
  consumer — a broken endpoint must not freeze a ledger. The refresh builds its
  needs-a-lookup list BEFORE it touches the budget, so a tick with nothing stale
  still costs zero gh calls.
- **`triage_prstates_prune` runs once per tick**, right after the refresh, and
  drops rows that are BOTH unnamed by any current `logs/READY-QUEUE.log` line AND
  older than `TRIAGE_PRSTATES_PRUNE_S`. Either condition alone keeps the row: a
  long-lived blocking PR is exactly what this ledger exists to carry. A row with
  an unreadable epoch is kept — prune is not the place to lose data. One locked
  rewrite, under the same `<file>.lock` sidecar as the writer.

## What this touches

- `bin/lib/rt/shards.sh` — the consume condition, and the prune call beside
  `triage_prstates_ingest` / `triage_prstates_refresh`.
- `bin/lib/triage-shards-lib.sh` — `triage_prstates_ingest`,
  `triage_prstates_refresh`, new `triage_prstates_prune`,
  `triage_prstates_prune_s`, `_tsh_prstates_ts`, `_tsh_gh_budget_low`.
- `bin/triage-gate.sh` — one guarded block in front of the queue branch's PR loop.
- State: `state/<project>.gate.json`, `state/<project>.gate-meta`,
  `state/<project>.prstates`. Reads the shared budget cache
  `state/gh-budget/<fp>.json` (60s TTL, shared with orphan-reconcile and the
  merge conductor; reads only).
- Knob: `TRIAGE_PRSTATES_PRUNE_S`, default `604800`, resolved by `_tsh_num` from
  the environment then `env/global.env`.
- Suite: `HARNESS_TEST_SANDBOX=1 bash tests/triage-shards-prstates.bh-1079-test.sh`.

## Operator check on a box

```sh
grep 'gate no-change' /root/harness/logs/<project>.log | tail
cat /root/harness/state/<project>.prstates
grep 'prstates refresh: PR #' /root/harness/logs/<project>.log | tail
```

A `rc=skip :: gate no-change` line right after a `dispatched 0 shards …
unchanged: <key>` line is defect A fixed. A `MERGED` row in `.prstates` that
flips back to `OPEN` is defect B back.
