# A finished remote build reaches its box once: the ledger row is the dedupe key, and "could not ask" never relays

Doc: BUILD-CONCURRENCY, DB-COORDINATION-SPEC

A build that finishes on a Fly builder or a pool machine reaches the owning box
through two doors — the jobs ledger's `result` row, which the box pulls, and a
relay json the hub pushes into `state/remote-results/<project>/<KEY>.json`. Both
are live on purpose. Two things decided whether a build came through both, and
both were wrong.

**The hub relayed on an unknown.** `bd_result_in_ledger` answered rc 1 for "the
ledger says no" AND for "the ledger could not be asked", with a comment saying
that was deliberate. Every caller's fallback on rc 1 is the ssh relay, so a
blink of the coordination DB pushed a copy of a result whose row was already
travelling.

**The box deduped on the result LINE.** `RR_SAMELINE` in `bin/lib/rt/staging.sh`
compared `head -1` of the staged RESULT with the relay json's `.result`, on the
reasoning that both are copies of the one line the build wrote. They are not.
`bin/fly-pool.sh` parks its hub json with `head -c 200`; the reap's pr-verify
gate rewrites word 1 to `RESULT_UNVERIFIED` or `RESULT_MALFORMED`; a builder
with the direct path armed appends `| CLOSED-OUT: …` to the line after its row
was written. Each divergence staged the build a second time, and the sweep put a
second close-out comment on one client's ticket. The same test collapsed two
genuinely DIFFERENT builds of one ticket whenever they happened to end in the
same sentence — the opposite mistake, in the same line of code.

## What changed

**`bin/lib/builder-direct.sh` — three answers.** `bd_result_in_ledger` now
returns rc 0 (the feed carries this build), rc 1 (the feed was read and does
not), rc 2 (it could not be asked at all: no jobs client in this shell, a
transport or HTTP failure, an empty project/key). What to DO about rc 2 is the
caller's; neither caller may map it to "delivered" or to "absent".

**`bin/fly-results-ingest.sh` — the decision moved to the front, and gained a
HOLD.** The block is fenced `# >>> relay decision (BH-1041)` and now runs before
the artifact pulls and before the builder is cleared, because one of its three
answers is "do nothing at all". On rc 2 the fresh hub build dir is removed, the
builder keeps `/run/harness/RESULT` and `job.json`, the hub keeps its
active-job row, and the `*/2` sweep re-asks. One line per key says so:
`state/fly/<project>-<KEY>.relay-deferred` is written BEFORE the log and ALERTS
lines, so a crash between them costs a repeated sentence rather than a lost
deferral. Any non-deferred completion removes the flag. The relay payload gained
`machine_build_dir`. The `CLOSED-OUT:` marker is now explicitly a CACHE: present,
the ledger is not asked at all.

**`bin/fly-pool.sh` — the reap defers and a retry re-asks.** It sources
`bin/lib/builder-direct.sh` and the reap's inline feed read is now one
`bd_result_in_ledger` call. `FEED_OK=0` with a client present selects a new
`RELAY_MODE=defer`: `RELAY_DEFERRED` on the pool dir, the hub json kept, no
`RELAYED`, nothing over ssh. The merge-queue touch still rides a deferral — that
hand-off needs no ledger. The full ssh push and its bookkeeping moved into
`pool_push_full` so the new `pool_relay_retry` (fenced
`# >>> pool relay retry (BH-1041)`, called once per tick before the reap loop)
does exactly what the reap does rather than a near-copy: rc 0 stamps `RELAYED`
and drops the marker, rc 1 pushes once and drops it either way (a failed push
keeps today's hub json, its `RELAY FAILED` alert and its hand-delivery story —
re-trying that every two minutes would page every two minutes without changing
it), rc 2 is silent. Both hub json writes carry `machine_build_dir`.

**`bin/lib/rt/staging.sh` — `RR_SAMELINE` is deleted.** The cross-path identity
is the MACHINE's build dir: `basename $BUILD` on the builder, written to the
ledger row as `detail.build_dir` by `bin/run-build.sh` and onto the RESULT as
`BUILD_DIR:` by `fly/builder-runner.sh`, from where both relay senders copy it
into the json's `machine_build_dir`. Whichever loop stages first writes it into
the staged RESULT as `BUILT_AS:`; the other loop's guard greps for exactly that,
non-empty only, so an older sender's absent field cannot match an absent line.
A json with no `machine_build_dir` is staged on its own and the project log says
"no cross-path identity on this json (older sender)". `ORIGINAL_RESULT:` stays —
it is no longer a duplicate test, but a rewritten line loses what the build
concluded and the sweep quotes it (BH-531).

## The correction to the contract docs

`docs/DB-COORDINATION-SPEC.md` described `RR_SAMELINE` and the result line as
the cross-path identity. The function is gone and the identity is
`detail.build_dir` / `machine_build_dir` / `BUILT_AS:`, so that section is
rewritten in place (review round 1 overrules the plan's D37: docs move with the
behaviour they describe, and a contract doc that names a deleted function is
read by the next person as the contract).

## Consequence, stated

Two distinct builds of one ticket that end in an identical sentence now stage
two dirs and get two close-outs. That is correct — they are two results — and it
is the behaviour `RR_SAMELINE` was silently suppressing.

## Where to look on a live box

Hub: `logs/fly-dispatch.log`, `logs/fly-pool.log`,
`ls builds/pool-*/RELAY_DEFERRED`, `ls state/fly/*.relay-deferred`,
one `LEDGER UNREADABLE` line per key in `logs/ALERTS.log`. Box:
`ls -d builds/<project>-<KEY>-remote*` — one dir per build — and its RESULT's
`BUILT_AS:` line.

The two deferrals have DIFFERENT backstops, and only one of them is a page
(review round 1). The POOL's park leaves a `pool-*` build record with no
`RELAYED` and a parked hub json, which is what `bin/pipeline-health.sh`'s "no
board close-out >1h" and `staleremote` >2h checks already read — so a pool
deferral that never resolves does page. The INGEST's hold leaves neither: it
writes `state/fly/<p>-<KEY>.relay-deferred` and keeps `state/fly/<p>-active.json`,
and `bin/pipeline-health.sh` reads neither path. Its backstop is therefore the
bound in the ingest itself — `RELAY_HOLD_MAX_S` (240s), after which it relays and
says `HOLD EXPIRED` once — because the thing that would otherwise notice is
`bin/fly-dispatch.sh` calling the finished build dead once the builder's 600s
idle autostop takes the machine, requeueing it and marking the ticket `.failed`
on attempt 2.
