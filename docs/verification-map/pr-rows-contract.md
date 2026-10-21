# PR state and attempt rows (the contract half)

**What it is:** two D1 tables and a view — `pr_state_events`, `pr_state`,
`pr_attempts` — plus the shell verbs that read and write them, and the three
helpers that put the merge conductor's attempt ledger on top of them. It is the
row twin of two files on ONE box:

- `state/merge-conductor/pr-state.tsv` — the current state of every PR the
  conductor tracks, including the `alerted` column that says "we already paged
  about this one".
- `state/merge-conductor/attempts.txt` — 396 KB on the hub on 2026-09-22, one
  line per `(kind, PR, sha)` the fleet has already paid for. Lose it and every
  open PR is offered one more rebase and one more re-review.

**It ships DARK.** Nothing writes a row and nothing reads one until the
`pr-state-rows` flag is up, and there is no route yet — the routes are the
sibling child #1386. With the flag absent `mc_attempted` is byte-identical to
what it was before: `grep -qxF` the file, `echo >>` the file, and not one
`/api/pr-*` request anywhere. The file stays the ledger of record for a full
cycle either way.

## How you reach it

There is no UI route and no CLI verb. Two ways in:

- the flag, from any box:
  `bin/jobs-client.sh flag-set pr-state-rows on "BH-1025 cycle 1"`
  (and `off` to stop all row traffic again — see the preconditions below, and
  read the rollback section for what `off` does and does not undo)
- the library, from a lane that already sources the client:
  `. "$HARNESS/bin/jobs-client.sh"` then `pr_state_page 20`

The primary lane is `bin/merge-conductor.sh` (`cron/hub.cron`, every 5
minutes), which calls `mc_attempted <kind> <KEY> <sha>` eight times a tick for
the rebase, re-review and rr-consumed decisions.

## How you drive it

```
HARNESS_TEST_SANDBOX=1 bash tests/pr-rows-contract.bh-1385-test.sh
cd worker/jobs && node --test test/pr-state-schema.bh-1385.test.js
```

The first drives the real `bin/lib/jobs/jobs.sh` and the real
`bin/lib/mc/locks.sh` (loaded through the real `merge-conductor-lib.sh`) behind
a curl shim that records every method, path and body, and asserts on the
request sink, the rc and `attempts.txt` — never on source text. The second
builds the same tables twice, once from `worker/jobs/schema.sql` and once
through the real `ensureTable`, and compares them with `PRAGMA table_info`.

On a live box, with the flag up, the evidence is:
`grep pr-attempts $HARNESS/logs/jobs-client.log` for a failed write, and the
`attempts.txt` line for a successful one — the file is always written first, so
a row with no file line cannot happen.

## The rc contract, which is the whole point

Every verb inherits `_jobs_req`'s map verbatim, the same one `job_ledger_get`
has always had:

| rc | means | what a caller does |
|---|---|---|
| 0 | 2xx — a real answer | act on it |
| 2 | 404 — a real miss | act on "not there" |
| 9 | 409 — conflict | the routes child decides; this child passes it through |
| 1 | transport, 5xx, no secret — unusable | do the work again, never skip it |

`mc_attempt_has` turns that into one rule: **rc 1 is never "already
attempted"**. An outage answers rc 1 (the conductor tries again) and latches
the twin off for the rest of the process, so a HANGING worker costs one timeout
per tick rather than one per PR.

## The response shapes the routes child must answer

Defined here, because this is what the fixtures pin:

- `GET /api/pr-state` and `GET /api/pr-state-events` → `{"rows":[…]}`
- `GET /api/pr-attempts` with a `sha` → 2xx when the row exists, **404** when it
  does not
- `GET /api/pr-attempts` without a `sha` → `{"count":N}`
- `POST /api/pr-state-events` and `PUT /api/pr-attempts` → 2xx, or 409 on the
  dedupe index
- `DELETE /api/pr-attempts` with the full `repo`/`number`/`kind`/`sha` query →
  2xx when the row is gone, 404 when there was none. **Not optional, and not a
  later deploy than PUT.** A worker that answers PUT but has no DELETE route
  answers the delete 404, which this client reads as "there was no row" — the
  one case where an honest rc map lies, because the row is right there. PUT and
  DELETE ship together or the forget below silently stops working.

## The forget, and what it costs to get wrong

`mc_attempt_clear` is the ledger's ONE eraser. The stuck detector
(`bin/merge-conductor.sh`, the `NEEDS_REBASE|REBASING` past-TTL arm),
`mc_handoff_human_release` and the pool-rebase enqueue all clear a line so the
next tick MAY act again — a fresh rebase, a consumable result, a NO_REBASE line
that speaks once more.

`mc_attempt_has` answers a file miss by reading the row and warming the line
back into the file. So with the flag up, a clear that stopped at the file would
forget nothing: the row would put the line straight back and that PR would be
skipped on every later tick, for ever, silently. That is BH-523/BH-764 again,
which is the failure the clear exists to fix, so the clear writes through:

- `pr_attempt_del` (`DELETE /api/pr-attempts`) after the file rewrite, gated on
  the same flag and the same PR-key classifier as the write.
- An empty `attempts.txt` is not an exit. The point of the twin is that the file
  can be lost while the rows stay, so the row delete runs either way.
- A DELETE that could not be made is NOT a forget. The file has forgotten and
  the row may not have, so the twin goes blind for the rest of that process
  (`pr_rows_trip`) and the file — which HAS forgotten — is the only thing asked
  that tick. The next tick clears again, because the stuck arm re-fires while
  the PR is still stuck. This is the one place `mc_attempt_put`'s "rc ignored"
  does not apply: a lost PUT costs one extra attempt, a lost DELETE costs the
  respawn itself.

Driven end to end by case 12 of the contract suite: three ticks against a shim
that keeps real rows — spawn, clear, respawn — plus a fourth that proves an
UNcleared attempt still dedupes.

## Before the flag goes up

Two preconditions, both of them about the forget:

1. #1386 answers `DELETE /api/pr-attempts` in the same deploy as PUT and GET
   (above). Without it the delete 404s and reads as "no row".
2. Flipping OFF and later ON again is not free: while the flag is down a clear
   is file-only, so a row written during the previous ON period survives it and
   can warm that exact `(kind, PR, sha)` line back when the flag comes up. It
   only bites an attempt that was cleared while dark and whose head has not
   moved since. If a dark period included stuck-PR clears, delete those rows
   (or leave the flag off) before flipping back on.

## Why `alerted` is `NOT NULL DEFAULT '-'`

`idx_pr_state_events_dedupe` is a plain column list over
`(repo, number, state, since, alerted)`, which is the form D1 accepts. A NULL
never collides in a SQLite UNIQUE index, so a nullable `alerted` would let the
same sighting insert forever and the index would be decorative. `'-'` is the
"not alerted yet" value, and the alerted sighting is deliberately a SECOND row,
so the original sighting is not overwritten by the fact that we paged about it.

## Gate rows (BH-4953)

PR gate facts live in this same table as rows with `state='gate'`. Eleven
nullable columns carry them (`draft`, `closed`, `held`, `hotfix`,
`ci_green_sha`, `builder_approved_sha`, `lead_verdict_sha`,
`lead_verdict_word`, `reviewing_sha`, `review_failed_sha`, `nudged_sha`),
applied by `ensureColumns`, not by `schema.sql`. A gate row's `since` is its
source (a delivery id or `<field>@<sha>`), so a replay dedupes on
`idx_pr_state_events_dedupe`. NULL is "no news": `gateFacts` folds each field
to its latest non-null value per PR, which is why it never reads the
`pr_state` view.

The view still counts gate rows, because the schema is additive-only and the
view cannot be redefined. So `GET /api/pr-state` and the daily digest's two
`BLOCKED_HUMAN` reads take MAX(id) over non-gate rows only, and a gate fact
never becomes a PR's current state for the conductor rehydrate,
blocked-resolver or stuck-work.

`GET /api/pr-state/needs-review?repo=` lists PRs that are not closed, draft or
held, whose head equals both the approved sha and the CI-green sha, and whose
head has no lead verdict and no failed review. Order: nudged on this head,
then hotfix, then oldest approval, then number. An empty list is a 200 with
`rows: []`. `pr_needs_review` maps that to rc 2 and reads a 404 as rc 1
(an old worker), never as "nothing to review". Gate rows are never pruned
here.

`gateFacts` is ONE range read on `idx_pr_state_events_gate` (repo, state,
number, id), folded in JS (BH-7764). The old SQL ran 14 correlated subqueries
per PR and outlasted withD1Retry on an overloaded D1. When a D1 overload
outlasts the retry, both gate GETs answer 503 `{error:"pr_state_events
unavailable", retryable:true, d1_attempts}` with one `d1-overload:` warn line
and no Sentry event. Every other error still throws to withSentry. Proven by
`worker/jobs/test/pr-gate-overload.bh-7764.test.js`.

## What is NOT here

No route, no `worker/jobs/src/index.js` change, no cron line, no
`bin/jobs-client.sh` dispatch verb, no resolver and no wake loop. Five of the
ten client verbs have zero callers ON PURPOSE — `pr_state_event_put`,
`pr_state_page`, `pr_state_events_page`, `pr_attempt_count` and
`merge_ledger_has` are the contract #1386 and #1387 build against. The other
five (`pr_rows_on`, `pr_rows_trip`, `pr_attempt_put`, `pr_attempt_has`,
`pr_attempt_del`) are called from `bin/lib/mc/locks.sh`, and all of that is
dark until the flag is up.
