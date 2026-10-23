# Scale landmines: the harness itself (BH-7906)

A landmine is a path from `docs/scale/ENVELOPES.md` whose `CEILING` is at or
below `NEXT` (10x `NOW`), on the numbers in that file. Two paths qualify. The
other paths either have a ceiling above 10x or have no measured `NOW` or
`CEILING`, so the audit cannot rank them (see the `not measured` lines in
ENVELOPES.md).

Each entry has one skipped test in `tests/scale-landmines.bh-7906-test.sh`.
The fix ticket turns its skip into a real test, so that ticket starts red.
No fix ticket is filed by this audit (BH-7123: an audit files no follow-up).

## github-rest-shared-bucket

PATH: GitHub REST through bin/lib/gh-rest.sh, one GitHub App installation bucket shared by every hub lane and pool machine.

WHAT BREAKS: the bucket empties before the hour ends. Each read after that answers 403, gh_rest returns rc 75, and the lane skips its decision ("UNVERIFIABLE"). Merges, closes and re-reviews wait an hour.

AT: 6,600 calls/h (the bucket). NOW is 5,700 calls/h (2026-09-22), so the ceiling is at 1.16x NOW, far below NEXT (57,000 calls/h).

SMALLEST FIX: give each lane class its own call budget per hour in the quota ledger, refuse the optional reads of a class over its budget, and move one heavy class to the second App meter that bin/lib/gh-rest-ledger.sh:134 already names.

TICKET TITLE: GitHub REST: per-lane-class hourly budgets on the shared App bucket

TICKET BODY:
1. The shared App bucket is 6,600 calls/h; the fleet used 5,700/h on 2026-09-22 (bin/lib/gh-rest-ledger.sh).
2. At 1.16x today's load the bucket empties every hour and lanes skip decisions.
3. Add an hourly budget per lane class to the quota ledger, as settings rows.
4. Over its budget, a class's optional reads are refused first; the ledger shows which class spent the bucket.
5. Done when tests/scale-landmines.bh-7906-test.sh case github-rest-shared-bucket is a real test and green.

SKIPPED TEST: landmine BH-7906: github-rest-shared-bucket

## d1-jobs-worker-overload

PATH: the harness-jobs worker and its single D1 database, through bin/jobs-client.sh, from every lane on every box.

WHAT BREAKS: D1 answers "D1 DB is overloaded". The worker gives a 503; _jobs_req retries once and then fails open, so coordination reads (flags, queue, verdicts) fall back to stale or empty answers.

AT: 1x. D1 answered "overloaded" 875 times in 5 h on 2026-10-14 (#6727), so the ceiling is at or below NOW and below NEXT (8,750 answers in 5 h).

SMALLEST FIX: count rows read per route per hour (D1 meta.rows_read) in a summary table, and move the top reader onto a summary table or a short cache, as the iron law on indexes and retention asks.

TICKET TITLE: jobs worker: rows-read budget per route and a summary table for the top reader

TICKET BODY:
1. D1 answered "overloaded" 875 times in 5 h on 2026-10-14 (#6727); 100-160M rows were read an hour.
2. BH-6750 added retention, but no route records the rows it reads, so the next hot reader is invisible.
3. Record meta.rows_read per route per hour in a summary table, with an index and a retention rule.
4. Move the top reader to a summary table or a short cache; prove it with EXPLAIN QUERY PLAN on seeded data.
5. Done when tests/scale-landmines.bh-7906-test.sh case d1-jobs-worker-overload is a real test and green.

SKIPPED TEST: landmine BH-7906: d1-jobs-worker-overload
