# BH-1385 (BH-1025.0): pr_state_events / pr_attempts, the client verbs, the conductor helpers

Doc: MERGE-CONDUCTOR, DB-COORDINATION-SPEC

## What changed

**Schema** (`worker/jobs/schema.sql`, one block appended at end of file, six
statements, all `IF NOT EXISTS`, no ALTER and no DROP):

- `pr_state_events(id, repo, number, state, since, head, reviewed, reason, url,
  alerted, at, actor)` — an EVENT log, not a current-state table.
- `idx_pr_state_events_dedupe` UNIQUE on `(repo, number, state, since,
  alerted)`, plus `(repo, number, id)` and `(state, at)`.
- `pr_state` — a VIEW: the `MAX(id)` event per `(repo, number)`, so no two
  readers can disagree about what "latest" means.
- `pr_attempts(repo, number, kind, sha, at, actor)`, PK
  `(repo, number, kind, sha)`.

Mirrored statement for statement in `CREATED_TABLES.pr_state_events` /
`.pr_attempts` (`worker/jobs/src/lib/core.js`), so `ensureTable(env, …)` is the
belt for a deploy that lands ahead of the schema apply — BH-1000's hub_lease
outage is why that belt exists. The view rides under `pr_state_events` because
a view over a table the same call just created is the only ordering that works.
No hand step: `bin/harness-sync.sh` applies `schema.sql` statement by statement
before `wrangler deploy`.

**Ten client verbs** in `bin/lib/jobs/jobs.sh`: `pr_rows_on`, `pr_rows_trip`,
`pr_state_event_put`, `pr_state_page`, `pr_state_events_page`,
`pr_attempt_put`, `pr_attempt_has`, `pr_attempt_del`, `pr_attempt_count`,
`merge_ledger_has`. All fail-open, all through `_jobs_req`, all inheriting its
rc map verbatim (0 on 2xx, 2 on a real 404, 9 on 409, 1 on transport/5xx/no
secret). The eight transport verbs do NOT consult the flag — the gate is in the
caller, so a sibling slice can read rows while the conductor's own writes are
still dark.

**Three helpers** in `bin/lib/mc/locks.sh`, with `mc_attempted` rewritten over
them: `mc_attempt_pr_key` (the line classifier), `mc_attempt_put` (file first,
row second, the row's rc ignored) and `mc_attempt_has` (file first, then the
row, which is warmed back into the file on a hit).

**And `mc_attempt_clear` gets its row half**, which is the half that bites.
It is the ledger's one eraser: the stuck detector, `mc_handoff_human_release`
and the pool-rebase enqueue clear a line so the next tick MAY spawn a fresh
rebase or consume a result again. Since `mc_attempt_has` answers a file miss
from the row and warms the line back, a file-only clear with the flag up would
forget NOTHING — the PR would be skipped on every tick after it, silently,
which is exactly the BH-523/BH-764 failure the clear exists to fix. So:

- `pr_attempt_del` after the file rewrite, behind the same flag and the same
  classifier, and it runs even when `attempts.txt` is empty (the file can be
  lost while the rows stay — that is the whole point of the twin).
- A DELETE that could not be made is NOT a forget: the twin goes blind for the
  rest of that process (`pr_rows_trip`), so the file, which HAS forgotten, is
  the only thing asked that tick; the stuck arm re-fires next tick and may reach
  the row then. `mc_attempt_put`'s "rc ignored" is right for a write (the file
  already says "attempted") and wrong here (a lost delete costs the respawn).
- Case 12 of `tests/pr-rows-contract.bh-1385-test.sh` drives three real ticks
  against a shim that keeps real rows: spawn → clear → respawn, plus a fourth
  tick proving an uncleared attempt still dedupes.

## The flag

`pr-state-rows`, a `flags` row mirrored as a file on each box, resolved once
per process by `pr_rows_on` (the `lt_on` precedent in
`bin/lib/ledger-twin.sh`). It ships OFF:

```
bin/jobs-client.sh flag-set pr-state-rows on "BH-1025 cycle 1"
```

Two preconditions on that flip, both about the forget:

1. #1386 must answer `DELETE /api/pr-attempts` in the SAME deploy as PUT and
   GET. A worker with PUT but no DELETE route answers the delete 404, and 404
   means "there was no row" to this client — the row would still be sitting
   there. PUT without DELETE is the stranding shape again.
2. ON → OFF → ON is not free. While the flag is down a clear is file-only, so a
   row written in the earlier ON period outlives it and can warm that exact
   `(kind, PR, sha)` line back when the flag returns. It only bites an attempt
   cleared while dark whose head has not moved since. If a dark period included
   stuck-PR clears, delete those rows (or leave the flag off) before flipping
   back on.

With the flag absent the only request any of this makes is `flag_active`'s own
one-per-process reconcile of `/api/flags/pr-state-rows`, which is how every
DB-backed flag in the fleet works. `tests/pr-rows-contract.bh-1385-test.sh`
case 9 asserts the request sink holds exactly that one line and no `/api/pr-*`
line at all.

## Why `alerted` is `NOT NULL DEFAULT '-'`

The dedupe index is a plain column list, which is the form D1 accepts. A NULL
never collides in a SQLite UNIQUE index, so a nullable `alerted` would let the
same `(repo, number, state, since)` sighting insert forever and the index would
be decorative. The alerted sighting is a SECOND row on purpose: "we paged about
this" must not overwrite the original sighting.

## Two mechanical pins widened

1. `tests/schema-additive.bh-1000-test.sh` allowed no `CREATE VIEW` at all, so
   the view could not land. Widened by exactly one arm,
   `"CREATE VIEW IF NOT EXISTS "*`. A plain `CREATE VIEW` is still NOT ADDITIVE
   — it fails on the second deploy for the rest of time, same as a plain
   `CREATE TABLE`. Checked both ways with `SCHEMA_ADDITIVE_FILE`.
   The alternative was to keep the view only in `CREATED_TABLES`, which would
   make a fresh D1 and the belt disagree — the exact drift the belt exists to
   remove.
2. `tests/mc/expected-map.tsv` and the `jobs` line of
   `tests/jobs-client-modules.bh-1194-test.sh`'s literal `MAP` are existing
   contract tables that MUST take rows or CI is red. The three map rows carry
   origin `lib`, not `bh-1025`: `tests/mc-split-layout-test.sh` greps the
   literal `<module>\t<fn>\tlib`, and any other origin reads as "misplaced".

## What is deliberately absent

No route, no `worker/jobs/src/index.js` change, no cron line, no
`bin/jobs-client.sh` dispatch verb, no resolver and no wake loop. Five of the
ten client verbs have zero callers by design (`pr_state_event_put`,
`pr_state_page`, `pr_state_events_page`, `pr_attempt_count`,
`merge_ledger_has`); the production consumers in this child are `mc_attempted`,
which `bin/merge-conductor.sh` calls eight times a tick, and `mc_attempt_clear`,
which it and `mc_handoff_human_release` / the pool-rebase enqueue call to forget
one. Routes are #1386.

## Rollback

Flip the flag off. The tables stay (additive, unread); `mc_attempted` returns
to grep-then-append on the next tick and `mc_attempt_clear` to its file-only
rewrite, because `pr_rows_on` resolves per process. What `off` does NOT undo:
the rows already written and the lines already warmed into `attempts.txt` — a
warmed line is true (some box did attempt it), so it is not a wrong answer, but
it is not erased by the flip either. Re-flipping ON after clears happened while
dark is the case in precondition 2 above.
