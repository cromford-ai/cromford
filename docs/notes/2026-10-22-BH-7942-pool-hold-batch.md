# The pool's HOLD gate reads the issue from the tick's listing, with its own cut and one retry (BH-7942)

Doc: FLY-POOL-RESPAWN-CAP, GH-REST

## What happened

On 2026-10-21/22 the project-6-os pool skipped 25 distinct tickets with
`hold check unreadable (... gh api repos/<repo>/issues/<n> answered an empty
body (rc=124)) — will retry`: 20 skips in the 23:00Z hour and 11 in the 00:00Z
hour, with about 33 rows queued. `hold_check` made two `gh api` calls per row
(the issue, then its comments), each cut at the 20 s `POOL_GH_READ_TIMEOUT_S`,
and one cut read lost the row its tick.

## What changed

- `pool_hold_list_prime` keeps each complete issue object of the open ai-build
  listing it already read once per tick (BH-6549) in `_POOL_HOLD_IJ`
  (`phc_listing_issues`, `bin/lib/pool-hold-cache.sh`). A row whose issue is
  in it is decided by `hold_check_issue` (`bin/lib/hold.sh`): one comments read,
  no issue GET. 30 queued rows cost 1 listing page and 30 comments reads, not
  1 + 60. A row absent from the listing, or a listed item without `labels`,
  `title`, `body` or `state`, reads its own issue as before.
- Every hold read (listing pages, issue GET, comments read) is cut at the new
  lane knob `POOL_HOLD_READ_TIMEOUT_S` (default 45, settings row
  `lane.fly-pool.pool_hold_read_timeout_s`, 0 = no cut). The PR, branch-head
  and repo reads keep `POOL_GH_READ_TIMEOUT_S` (20).
- `pool_hold_read` retries an unreadable hold read once inside the tick, and
  the listing reads a non-200 page once more. After one row's retry also fails,
  the rest of the tick reads once per row (`_PHR_RETRY_OFF`, carried from a
  decide worker to the tick shell like `_POOL_PR_UNREADABLE`).
- Unchanged: an unreadable answer never marks or clears a hold. `hold_check`
  keeps its two reads and its output for its other callers.
- `POOL_HOLD_CACHE_TTL_S=0` still reads no listing, so every row then reads its
  own issue (with the new cut and the retry).

## Evidence

One line per tick after `hold cache:`:
`hold reads: batched=<rows decided from the listing> retries=<n> retry_ok=<n> retry_off=<0|1> timeout_s=<n>`.
Live check: `grep 'hold reads:' logs/fly-pool.log | tail`, and the hourly
count of `hold check unreadable` in `logs/fly-pool.log`.

Suite: `tests/pool-hold-batch.bh-7942-test.sh`.
