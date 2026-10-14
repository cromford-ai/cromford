# A PR head buys one lead review, and the fleet counts the ones it paid twice (BH-3941)

Doc: CALL-GUARD, COST

Part of BH-3930 (slice 5 of 5). It builds on BH-3937's contract
(`bin/lib/review-bought.sh`, and the `lead-head` K=1 stage in
`bin/lib/call-guard.sh`), so it merges after that PR.

## What was wrong

- `bin/lead-review.sh` runs every 5 minutes, but a lead review takes 7-9. The
  next tick picked up the same request and paid for it again. That happened on
  123 of 128 heads in the 7-day audit.
- `bin/lead-review-enqueue.sh` asked for a fresh lead review whenever a builder
  approval was rebound to a new head (`reapproved@<head>`), even when the patch
  had not changed. That was 13 of 145 enqueues.

## What changed

1. **Tick lock.** `bin/lead-review.sh` takes `flock -n` on
   `locks/lead-review-tick.lock` (fd 7) just before it reads the request list.
   A tick that finds the lock held logs `tick skipped: the previous tick still
   holds locks/lead-review-tick.lock (a review is running)` and exits 0. It is a
   dedupe, never a wait. The agent call inherits the fd. So when a tick is
   killed mid-review, the lock stays held until that call ends, and only then
   can the next tick run. The heartbeat child sheds the fd
   (`_job_beat_shed_fds`), so it never holds the lock.
2. **Per-head guard key.** Both lead calls carry
   `AGENT_CALL_GUARD_STAGE=lead-head` and
   `AGENT_CALL_FP=lead:<owner/repo>#<n>@<sha>`. The unknown-verdict retry uses
   `...~noverdict`, which is its own key. When `review-bought.sh` is not on the
   box, the calls carry no fp, the same as before.
3. **Enqueue replay.** For a `reapproved@<head>` approval with no lead or human
   verdict standing on the head, the enqueue lane reads
   `GET /api/verdicts?repo=&pr=` and finds the newest `source=lead` row on
   another head with MERGE, MERGE-WITH-NOTES or BLOCK. If `patch_same_fetch` and
   `patch_same` (on the clone under `REPOS_ROOT`) prove the new head carries
   that head's patch, the lane runs
   `bin/lead-verdict.sh post <slug> <n> <head> <word> --source lead --reviewer box:<hub> --note "lead-replay:<prev12> how:<HOW>"`.
   Post rc 0, 4 or 5 means the verdict was replayed and no review is requested.
   When the history already holds a `source=lead` row on the new head whose
   note carries `lead-replay:`, the head was replayed on an earlier tick: it
   counts as replayed and nothing is posted again. That matters for rc 5, an
   advice row that may not stand, which would otherwise be re-posted every 5
   minutes. Every other outcome takes the request path, as before: a failed,
   unparseable or truncated read, no checkout, a failed fetch, a changed patch,
   or any other post rc. The tick summary gains `replayed=<n>`.
4. **The metric.** `bin/review-paid-unchanged.sh <fleet-cost.csv> [days=7] [NOW]`
   is pure python over the cost CSV. A row counts as paid unless its
   `row_source` is refused, settled or unbilled. The fps `review:`, `review-prs:`,
   `review-autopilot:` and `mc-rereview:` share the key
   `review:<slug>#<n>@<sha>`, and `lead:` keeps its own. The first paid row of a
   key is free, even when it was paid before the window. Every later paid row
   inside the window counts per UTC day and per `lane_id`. The window is exactly
   `days` UTC days ending on NOW's day, and `days`, `total_by_day` and
   `exempt_by_day` carry every one of them, zero-filled, so a quiet day reads 0
   rather than missing. A `~<reason>` fp goes to `exempt_by_reason` and
   `exempt_by_day`, and so does its stored form `_<reason>`, because
   `call_guard_fp` rewrites `~` to `_` before the cost row is written. A
   reason's trailing digits are dropped, so `rebuy<epoch>` groups as `rebuy`. Paid
   lead-review rows with a legacy fp count as `unkeyed`. Rows whose ts does not
   parse count as `bad_ts`.
5. **Where it shows.** `bin/cost-rollup.sh` runs the metric every run and
   stores it as `summary.json`'s `review_paid_unchanged`. It runs on the hourly
   WINDOWS_ONLY run too, because `summary.json` is rewritten whole every run and
   a daily-only key would be missing 23 hours a day. A failed run stores
   `{"error": "<first stderr line>"}`, never zeros. Only the nightly run beats,
   writes ALERTS lines and warns or resolves. It beats
   `review_paid_unchanged yesterday: <lane>=<n> ... (exempt: rereq=<n> stepup=<n> noverdict=<n>)`,
   where the exempt counts are yesterday's (`exempt_by_day`), not the window's.
   A result with no `total_by_day` entry for yesterday or the day before is an
   error (one ALERTS line), never a 0 and never a resolve.
   When yesterday and the day before both counted repeats, it raises
   `lane-alert --id review-paid-unchanged --severity warn` naming the top 5
   keys. Otherwise it resolves that id. An error writes one ALERTS line and
   never resolves. A box without the script stores
   `{"error": "bin/review-paid-unchanged.sh is not installed on this box"}`.
6. **The ratchet.** `tests/alert-line-wave-cost-health.bh-2314-test.sh` E4 keeps
   cost-rollup's ALERTS writers on `kind:alert`. It now skips only a
   `lane-alert.sh` line that names `--id review-paid-unchanged`, because a
   warn digest plus a resolve has no `alert-line.sh` form. Any other new
   lane-alert call in those files is still red.

## Reading the first days

The first two days of `review_paid_unchanged` straddle the deploy, and legacy
lane-prefixed fps normalise into the same key. Legacy review fps (`review-prs:...`, `review-autopilot:...`) normalise into the
shared key. So repeats across lanes from before this deploy show up in the
first window too. They are real repeats, not a fault in the meter.

## Tests

- `tests/lead-review-dedupe.bh-3930-test.sh` covers the tick lock, the kill -9
  retry, the guard fps and the enqueue replay (D1-D6), and that a head already
  replayed onto is never posted again (D7).
- `tests/review-paid-unchanged.bh-3930-test.sh` covers the metric and the
  cost-rollup blocks, extracted verbatim (E1-E6), reason grouping (E7) and the
  exact zero-filled window (E8).
