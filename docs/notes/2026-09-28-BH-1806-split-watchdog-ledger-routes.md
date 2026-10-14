# Split-watchdog ledger: worker routes and shell verbs (BH-1806, BH-1793.1)

Doc: DB-COORDINATION-SPEC

## What changed

BH-1805 landed the `split_watchdog_actions` table and four shell verbs that
always answered rc 1. This slice gives them a real read and write path.

1. **Worker routes** (`worker/jobs/src/routes/split-watchdog.js`, appended to
   the bearer-protected `ROUTES` in `worker/jobs/src/index.js` after
   triage-state):
   - `POST /api/split-watchdog` `{project, family, child, step, reason?, outcome?, actor?}`
     upserts on `(project, child, step, reason_fp)`. A repeat bumps `repeats`
     and moves `last_at` and `outcome`; `family`, `reason`, `actor` and
     `first_at` keep their first values. Answers
     `{recorded:true, repeats, first, reason_fp}`. 400 when project, family,
     child or step is missing, child is over 128 characters, or step is not
     `[a-z][a-z0-9-]{0,31}`. The point lookup applies the same child and step
     checks (one `keyOf()` for both verbs), so it can never miss a row the
     write made.
   - `GET /api/split-watchdog?project&child&step&(reason_fp|reason)` is a point
     lookup: `{split_watchdog_action: row|null}`. No row is 200 + null, not
     404, because `_jobs_req` maps 404 to rc 2 and the dedupe reader must never
     have to tell "not seen" from a transport answer.
   - `GET /api/split-watchdog?project[&family][&since][&outcome][&limit]`
     lists newest `last_at` first. `limit` defaults to 500 and is clamped to
     500; a non-integer or < 1 is 400. `truncated:true` when more rows exist.
2. **Shell verbs** (`bin/lib/jobs/split-watchdog.sh`, signatures unchanged):
   `sw_record` prints `first` or `repeat <n>`; `sw_seen` prints the outcome or
   nothing; `sw_list` prints 11-column TSV
   (`project family child step reason_fp outcome repeats first_at last_at actor reason`);
   `sw_actions_today` counts `acted` rows whose `last_at` is today (UTC), via
   the list route with `outcome=acted&since=<YYYY-MM-DD>`. Every failure is
   rc 1 with empty stdout, including a 2xx that lacks the field the verb reads.

## reason_fp: server-side

The ticket said pick one. The worker computes it: SHA-1 of the reason, trimmed
and with whitespace runs collapsed to one space, first 12 hex. Case is kept.
A `reason_fp` in a POST body is ignored. The GET point lookup takes either the
`reason` (fingerprinted by the worker) or a 12-hex `reason_fp` a caller read
from a list row; a malformed `reason_fp` is 400, not a lookup of the
empty-reason row. No shell code hashes a reason, so the two sides cannot drift.
The fingerprint is taken over the FULL reason and only the stored copy is cut
to 500 characters, so a 600-character reason is found by the same text it was
recorded with (review finding on the first cut of this PR, which hashed the
truncated copy on write and the full text on read).

## What did not change

No lane, cron line, settings row or decision logic. Those are later children
of BH-1793. `tests/split-watchdog-contract.bh-1805-test.sh` still asserts that
no cron file or `catalog/lanes.json` names the watchdog; it no longer forbids
the route registration or `_jobs_req` in the ledger module, which is this
slice.

Tests: `worker/jobs/test/split-watchdog.bh-1806.test.js` (routes through
`worker.fetch` on node:sqlite), `tests/split-watchdog-client.bh-1806-test.sh`
(the real `bin/jobs-client.sh` against the real worker through a fake `curl`).
