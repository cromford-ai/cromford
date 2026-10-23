# An unreadable lead verdict no longer spends the head's only paid call (BH-8081)

Doc: CALL-GUARD

## What changed

- `review_one` (`bin/lead-review.sh`) asks `lu_extra_fp`
  (`bin/lib/lead-unread.sh`) when the BH-7792 peek finds the lead-head guard
  key spent. If the `~noverdict` key is paid (`~nvbody<D>` on a changed body),
  the paid round had no readable verdict. The head then gets ONE more paid call
  on `~unread` (`~unbody<D>`). The D1 call-guard (K=1 on `lead-head`,
  `CALL_GUARD_WINDOW_S`) caps it at 1 per head per window.
- The extra round makes one call. It has no `~noverdict` retry.
- A second unreadable answer writes `.empty` and fails the request `empty` as
  before. It also sends one warn through `bin/lane-alert.sh` with the id
  `lead-noverdict-<owner_repo>-<pr>-<sha12>`.
- Each guard-blocked tick adds 1 to `state/lead-reviews/<key>.gblock`. At
  `LEAD_REVIEW_GUARD_ALERT_TICKS` (2) ticks it sends the same alert. If the
  extra key is already spent, it alerts on the first blocked tick. The alert
  text names the `bin/jobs-client.sh call-guard-reset` command. Markers older
  than `CALL_GUARD_WINDOW_S` are removed on the next blocked tick.
- Knobs: `LEAD_REVIEW_UNREAD_RETRY` (1, 0 = off) and
  `LEAD_REVIEW_GUARD_ALERT_TICKS` (2, 0 = off), in
  `catalog/lanes.d/lead-review.knobs.d/`.

## Why

#8063 and #8034 (2026-10-22): one unreadable answer spent the head's paid
call. Each later claim logged "call-guard paid 1/1 ... no agent call" and
released. Nothing alerted. An operator ran `call-guard-reset` by hand.

## Test

`tests/lead-review-unread-retry.bh-8081-test.sh`.
