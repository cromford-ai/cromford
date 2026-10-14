# A triage shard is deduped per TICKET, on a fingerprint persisted before the session is bought

Doc: BUILD-CONCURRENCY

The triage tick is a dispatcher: `bin/lib/rt/shards.sh` splits the tick's scope
by ticket key and buys one agent session per key. The only brake in front of
that spend was the tick-level `queuefp` check in `bin/triage-gate.sh`, and a
tick-level brake is all-or-nothing — one ticket's queue line gaining a word
un-brakes the whole tick, and every OTHER key in scope is re-bought having not
moved at all. A shard that concludes "hold, nothing to do" is a billed empty
result, re-offered on every RUN tick. The 2026-09-17..19 runaway-spend audit
measured it at project-4 2,073 shards in three days, project-1 TK-265 153 sessions
on one ticket, cromford $896/day. Nothing errored; the bill was the only
symptom.

So the unit of dedup moves to where the unit of spend already is. Before a key's
session is bought, the dispatcher fingerprints that ticket's world and compares
it with the value persisted at the last dispatch in
`state/triage-shards/<project>/<key>.fp` (`<fingerprint>\n<epoch>\n`, the shape
`queuefp` already has). Identical, with a stamp younger than
`TRIAGE_SHARD_FP_TTL_S`, means no session and one log line. **The tick-level
brake is untouched and stays as the backstop.**

## What goes into the fingerprint

- **The key's own scope lines.** A queue line is reduced to its MACHINE tokens —
  the ticket key, `PR #12` references, `project=`/`base=` pairs, a
  `[status/waitingOn]` bracket, ALL-CAPS status words — because a no-action
  session rewrites its prose and its `Re-checked <ts>` on every tick, and that
  churn is exactly what defeated the tick brake. A board DIFF line has its verb
  and description normalised away (see below); an `UNBLOCKED`/`STACKABLE` line
  from `bin/unblocked-children.sh` is kept verbatim, because it carries
  dependency facts no fingerprint holds.
- **The ticket's own entry in the live board fingerprint**
  (`state/<project>.gate.pending`), for any key the board named this tick.
- **The state of every PR the queue line names**, from the carried-forward
  ledger below.
- **This key's build dirs with their `RESULT`/`COMMENTED` marks.** A finished
  build reaches a `queue-pending` tick as no scope line at all, so without this a
  close-out could be deduped away and the client would never hear back.

Deliberately NOT in it: `state/<project>.result-rows`, a project-global watermark
with no ticket in it. Folding it in would move every key's fingerprint whenever
any build in the project finished.

## Why the PR states needed their own file

`state/<project>.prstates`, `<pr-number>\t<STATE>\t<epoch>` per line.

The obvious source was line 3 of `state/<project>.queuefp`, where
`bin/triage-gate.sh` parks its own 45-minute PR lookup. It is unusable: the gate
writes that line on ONE of its three write branches and erases it on the other
two. Probed against the real gate — a first tick writes 2 lines, a quiet
50-minute tick writes 3 with `12=OPEN;`, the next reworded-prose tick writes 2
again. The same unchanged world gave one key two different fingerprints and
bought a session on each flip: twice per 45-minute cycle, on exactly the "still
waiting on PR #X" line this ticket is about. Worse in the other direction — with
the stamp taken in the `?` state, a merge stamped during a 2-line stretch was
invisible until the 4h TTL. And `bin/lib/rt/shards.sh` deletes `queuefp`
whenever the hourly cap defers a unit (`TRIAGE_SHARD_CAPS=1` is live on all six
boxes), which erased the vector for every key at once.

So the states get a file nothing else writes and nothing deletes. It is FED from
the gate's free lookup when there is one (`triage_prstates_ingest`), REFRESHED
once per tick by REST when the entry has aged past the gate's own 45-minute
window (`triage_prstates_refresh` — one pass, for the numbers the queue lines
name, capped at 20 exactly like the gate's own lookup, never per key), and
CARRIED FORWARD otherwise. `?` therefore appears only before the first
successful read on a box, and never flaps back. A failed lookup leaves the
previous value and its stamp alone: a transient outage must not turn a known
`OPEN` into a `?` and buy a session for every key that names it.

## The refresh goes through the shared REST reader, never a raw `gh` call

`tests/gh-app-ratchet-test.sh` caught the first cut of `triage_prstates_refresh`
as a new raw `gh api` reader. It is converted rather than allow-listed — the
baseline count is unchanged at 9 raw files and 6 allow-listed — and the routing
earns its place three times over:

- `bin/lib/gh-rest.sh` is `no-graphql` by construction. `gh pr view` is a
  GraphQL wrapper and the accounts this fleet runs on are rate-limited out of
  GraphQL.
- **Its three exit codes are the whole reason this is safe to run on a
  schedule.** A raw call collapses "GitHub said 404" and "GitHub said come back
  later" into one empty string, which is incident #768. Here `44` is a real
  answer, cached as `ABSENT` for the same TTL so a queue line naming a dead PR
  does not re-ask for ever; and `75` — a rate limit, a network failure, an empty
  body — leaves the previous value **and its stamp** alone, because a transient
  outage that turned a known `OPEN` into `?` would move every fingerprint naming
  that PR and buy a session for each of them.
- The App identity is armed for the repo around the pass (`gh_auth_for` /
  `gh_auth_reset`), so the read comes out of a short-lived repo-scoped token
  rather than the one fleet-wide PAT bucket.

The pass is also gated on `gh_budget_low triage-prstates`, the idiom
`bin/review-autopilot.sh`, `bin/wake-loop.sh` and `bin/orphan-reconcile.sh`
already use: a PR-state refresh is the textbook non-essential read, and skipping
it costs nothing but a carried-forward value, which is what the ledger is for.

## Why the diff verb is normalised away

`bin/gate-diff.sh` names a ticket `NEW` when the consumed fingerprint lacks it
and `CHANGED` when it has it, and **only the `CHANGED` line carries
`(comments: 5 -> 6)`**. Which of the two a ticket gets is a fact about
`state/<project>.gate.json`, not about the ticket. A key re-armed out of that
file sits on `board issues: NEW 563 "c"` — byte-identical at five comments and
at six — so fingerprinting the diff line let a client's reply be skipped for the
whole TTL, webhook wake included, because the wake scopes off the same line.

The fingerprint therefore reads the ticket's own entry in the live fingerprint
and treats `NEW`/`CHANGED`/`REMOVED` as one token. A new comment always moves
the input, whatever the diff chose to call the line.

## A skipped key is not re-armed

`fp`-fresh now MEANS the thread has not moved since the shard that was handed
this exact world, so there is nothing to put back and consuming it is the honest
state. The first cut of this change re-armed skipped keys, which kept them
permanently absent from `gate.json` and permanently on the count-less `NEW`
line — the defect above, manufactured by the fix for a different one.

## Three outcomes, never two

`triage_shard_fp_fresh` answers fresh (skip), stale/different/never-stamped
(dispatch), and **unreadable** (dispatch, and say so). A 0-byte or garbage stamp
reading as "already paid" is the BH-977 shape; it would take that ticket dark
until the daily sweep.

`bin/triage-shard.sh` releases the stamp with `REARM_UNOWNED` on the three paths
where the shard did not do the work (a refused ledger claim, a missing contract,
a nonzero exit). The "key lock already held" path uses the plain `REARM`: two
shards meet on one key only when the dispatcher's held census races the first
shard's `flock`, and the loser must not delete the WINNER's stamp, which is a
live claim on work running right now.

## The knob

`TRIAGE_SHARD_FP_TTL_S`, default `14400` — four hours, the same hard backstop
the gate's queue brake uses, and the bound on how long any ticket can go unread
on a fingerprint. Resolved by `_tsh_num` from the environment then
`env/global.env`, exactly like every other `TRIAGE_SHARD_*` knob. **`0` is the
off switch**: nothing can be younger than zero seconds, so every key dispatches
exactly as it did before this change and no stamps are written at all.
`TRIAGE_PRSTATES_TTL_S` (default `2700`) sizes the REST refresh window.

## How it is proven

    HARNESS_TEST_SANDBOX=1 bash tests/triage-shards-ticket-fp-test.sh

Part A drives the real `bin/run-triage.sh` end to end against a scratch
`$HARNESS`; the stub `agent-call.sh` writes a cost row, so "no session was
bought" is asserted on `logs/cost.csv` and not only on a log line, and the stub
`gh` records every call so "one refresh pass per tick, never per key" is an
assertion rather than a hope. Part B drives the ACTUAL `bin/triage-gate.sh`
through its 2/2/3/2-line write sequence and asserts the fingerprint never moves
for an unchanged world, that a real merge does move it, that the ledger
refreshes itself when the gate never looks, and that losing `queuefp` to a cap
deferral re-buys nothing. Part C moves only the live fingerprint and expects a
dispatch, and moves only the diff verb and expects quiet — including the
event-wake path.
