# A build whose PR never opened is owned end to end

Doc: RUN-BUILD-GRAPH, MERGE-CONDUCTOR

BH-614. A build can end with its diff committed, its review APPROVE, its branch
on origin and no pull request, because `gh pr create` returned no url. Main
already NAMED that state in two places and did nothing with it downstream.

## The two words

- `bin/run-build.sh`'s RESULT ratchet (#749/BH-574) writes
  `PR_CREATE_FAILED: <gh words>` when a create claim carries no `https://`.
- `bin/fly-pool.sh`'s url-shape gate (BH-765) writes `RESULT_MALFORMED PR_CREATED
  …` when it reaps a record an OLDER pool image wrote, whose line 1 claims a PR
  and whose field 2 is not a PR url.

Same state, two spellers. BH-765's suite pins its word byte for byte, so nothing
in BH-614 re-spells it; every lane that owns the park reads BOTH shapes instead.
`RESULT_UNVERIFIED PR_CREATED …` is deliberately not this park — that is a PR
that could not be READ (BH-709), the alert medic owns it, and rebuilding it would
open a second PR for a ticket whose first one is probably fine.

## What changed

**`bin/run-build.sh` — the transition graph gains a terminal row.** For
`docs/RUN-BUILD-GRAPH.md`'s table, between rows 40 and 41:

| # | From | To | Guard | Bound |
|---|---|---|---|---|
| 40b | PR-open | `PR_CREATE_FAILED: <gh error>` | the create ladder returned no url and nothing was adopted; the branch is KEPT on origin | terminal; the queue row closes `failed`, `bin/pr-url-reconcile.sh` re-links it if a PR exists, else `bin/blocked-resolver.sh` rebuilds it fresh (3 tries, then ABANDONED) |

It is written by `RESULT()` itself — the ratchet folds `PR_CREATE_ERR` into the
terminal line — and never by a `RESULT "…"` call, so
`tests/run-build-graph-test.sh` §1's extraction cannot see it and §2 never had to
account for it.

**`bin/run-build.sh` `_job_finish` — `PR_CREATE_FAILED*) st=failed` by name**,
above the catch-all, instead of reaching `failed` through `*)`. The `D` in FAILED
is what keeps it out of the `PR_CREATED*` arm one line up.

**`bin/run-build.sh` `# >>> pr create failed` — a `pr_create_failed` ledger
artifact.** `ref` = the branch (what an operator opens the PR from by hand and
what a rebuild targets), `detail` = JSON carrying `record` / `branch` / `base` /
`error`, the last being gh's own words cut at 900 chars. Written before `RESULT()`
like the ALERTS line, guarded on `JOB_ID`, and fail-open: a box with no jobs
worker records nothing and the build ends the same way. `job_artifact_put` takes
any kind and the worker treats only `pr_url` / `verdict` specially, so no worker
change was needed.

**`bin/fly-pool.sh` `# >>> reap row close (BH-614)` — both failed-create words
close the queue row `failed`.** Every reaped RESULT used to close `done`, which
is the ledger saying finished work about a reviewed, pushed branch with no PR.
The block sits OUTSIDE the `# >>> pr verify gate` markers on purpose: BH-765's
and BH-709's suites extract that gate, and a row close inside it would be lifted
into their fixtures.

**`bin/blocked-resolver.sh` — `pr-create-failed` is a park this lane owns**, and
it answers `rebuild-fresh`. There is no PR to read and no finding to fix, so no
rung of the ladder applies. For `docs/MERGE-CONDUCTOR.md` §11's source table, the
`build records` row also covers `PR_CREATE_FAILED` and `RESULT_MALFORMED
PR_CREATED` (90-minute floor; the reconciler's window), and the
`br_rebuild_outcome` table's "anything else" row now includes `PR_CREATE_FAILED`
explicitly: a rebuild that itself ends that way re-enters through
`br_from_builds` after the floor, on the same per-ticket counter.

**`bin/pr-url-reconcile.sh` — reads both shapes, and skips a superseded record.**

**`console-ui/src/lib/stages.js` — `pr_create_failed` is a known stage at the PR
step and a member of `DEAD_STAGES`.** It used to be unknown, which drew a stopped
build at step 0 as "still planning" and made `buildLane` answer `building`.

## The handshake, which is the whole design

The resolver's intake for this park is the BUILD RECORD ONLY, never the FAILED
queue row. `bin/fly-pool.sh` closes that row the moment it reaps, seconds after
the build ended, while `bin/pr-url-reconcile.sh` runs every ten minutes to find
out whether the PR did open after all on a later rung of the create ladder. A
rebuild inside that window is two PRs for one ticket. `br_from_builds`' existing
90-minute record floor IS the reconciler's window, by construction, and a record
the reconciler re-linked reads `PR_CREATED …` at line 1 and is never offered. The
other direction is `.blocked-resolver-superseded`: once the resolver has replaced
a record with a fresh build, the reconciler never re-links the retired one.

Accepted residual race, named on purpose: the reconciler walks at most
`PR_URL_RECONCILE_MAX` records per tick under a deadline and reports the rest as
`unwalked=`. A record it never reached inside 90 minutes could be rebuilt while a
hand-opened PR exists. The superseded marker then keeps the OLD record from ever
being re-linked, so the worst case is one extra PR, visible on the board, not a
silent mislink.

## Commands

    HARNESS_TEST_SANDBOX=1 bash tests/pr-create-failed-owned.bh-614-test.sh
    HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver.bh-614-test.sh
    cd console-ui && node --test tests/stages.bh-614.test.js
