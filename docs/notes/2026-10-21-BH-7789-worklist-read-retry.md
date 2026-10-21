# Lead review worklist read: one retry, status and body logged, every read recorded (BH-7789)

Doc: OPERATING

## What changed

- `lw_items` (`bin/lib/lead-worklist.sh`) reads `GET /api/pr-state/needs-review`
  once more after `LW_ITEMS_RETRY_SLEEP_S` seconds (default 2, an integer
  0..10, else 2) when the first read fails. A `no-secret` or `no-url` answer is
  not retried. The rc contract to `bin/lead-review.sh` does not change.
- The read captures the status word and the first 200 bytes of the body through
  `_jobs_req`'s `JOBS_STATUS_FILE` / `JOBS_BODY_FILE`. `logs/lead-review.log`
  gets one line on a final failure (both reads' status and body) and one line
  when the retry answered. A clean first read logs nothing new.
- Every `lw_items` call appends one line to
  `state/lead-review/worklist-reads.tsv`: UTC time, repo, ms, `ok`/`none`/`fail`,
  reads (1 or 2), status word (or `parse`). `lw_pr_day_prune`, once a tick,
  keeps `LW_READS_KEEP_DAYS` days (default 7).
- New tests: `tests/lead-worklist-retry.bh-7789-test.sh` and
  `worker/jobs/test/pr-state-needs-review-plan.bh-7789.test.js` (EXPLAIN of
  every statement the needs-review route runs on seeded volume; the 1 s timing
  case skips with the measured number while the pre-BH-7764 fold is in place).

## Why

The needs-review route took 7136-7693 ms in prod and answered `500 error code:
1101` on some ticks. `lw_items` gave up on the first failure and the lane log
said only `rc=1`. The query rewrite is BH-7764 (#7776); on this test's seed the
old fold answers in about 7000 ms and the BH-7764 fold in about 120 ms.
