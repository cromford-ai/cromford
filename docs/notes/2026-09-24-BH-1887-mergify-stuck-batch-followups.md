# The Mergify stuck-batch refresh waits on the required set, alerts only on the oldest draft, and retries a failed POST

Doc: MERGIFY

## What changed

Four follow-ups from the #1885 review of the BH-1790 stuck-batch refresh, all in
`mc_mergify_stuck_pass` / `mc_mergify_batch_green` in `bin/lib/mc/queue.sh`.

- **Required set.** New `mc_mergify_required_checks <slug>` reads the
  `check-success` names from the `queue_rules:` block of the repo's
  `.mergify.yml` (the same policy-cache read `mc_queue_mergify_enabled` does).
  A batch draft now counts as green only when each of those names has a run on
  its head and every run is green. Before, "every run that exists is green" was
  enough, so a required run that had not been created yet could not block a
  refresh. A missing name is logged `has no run for required check(s) …`. An
  unreadable `.mergify.yml` refreshes nothing that tick (`UNVERIFIABLE`). A
  `queue_rules` block with no `check-success` falls back to the BH-1790 rule.
- **Oldest draft only.** With `max_parallel_checks: 8`, batch N+1 can sit green
  while Mergify waits on batch N. The newer draft is still refreshed (it does no
  harm), but only the lowest-numbered open batch draft can raise
  `MERGIFY_BATCH_STUCK`.
- **Window floor.** A `MC_MERGIFY_REFRESH_WINDOW_SECS` below the conductor tick
  meant a new slot every tick, so the previous slot's line was never there and
  the alert could not fire. 1-299 now reads as the tick: 300 (the `*/5` of
  `cron/lanes/410-merge-conductor.cron`) or `MC_TICK_SECS` when that is longer.
  0 still means once per head. The registry `min` stays 0, because a minimum
  cannot say "0 or at least 300"; the knob note says it instead.
- **Attempted vs posted.** `mergifyrefresh …` is still written before the first
  POST (once, not per retry). New `mergifyposted …`, same words, is written
  only when `gh api -X POST` returns 0, and the skip test reads that line. A
  failed POST is retried on the next tick instead of waiting a whole window
  (failure log: "the next tick retries"). If no refresh was ever posted, the
  alert says `@mergifyio refresh could NOT be posted … post it by hand on the
  draft and check the token can comment`.

## Choices worth knowing

- The #1885 review suggested `mc_attempt_clear` on a failed POST. That would
  erase the attempt, and then the alert could not tell the post failed. It also
  takes three arguments, not the whole line. Two ledger kinds do both jobs.
- A failed POST is retried every tick with no cap. `@mergifyio refresh` is
  idempotent on Mergify's side, so this is at most 12 tries an hour per draft.
- A required name that exists only as a commit status (not a check run) reads
  as missing, so that draft is not refreshed. That is the safe direction.
- Drafts that were in flight at deploy time carry a `mergifyrefresh` line with
  no `mergifyposted`, so each gets one extra refresh.

## Verified by

`tests/mergify-stuck-batch.bh-1887-test.sh` (§1 required set, including the
repo's own `.mergify.yml`; §2 oldest only; §3 window floor; §4 attempted vs
posted; §5 real `bin/merge-conductor.sh` ticks). It fails 30 of 45 on #1885's
head `ca17770`. `tests/mergify-stuck-batch.bh-1790-test.sh` is unchanged and
still green.
