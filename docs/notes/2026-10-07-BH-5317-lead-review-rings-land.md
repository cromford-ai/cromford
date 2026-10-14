# The lead-review chain is event-driven: a finished review rings lead-land (BH-5317)

Doc: EVENTS

## What changed

The lead chain has three hops, and each one now has a doorbell. The crons stay
on as `*/15` backstops.

1. `bin/lead-review-enqueue.sh` (hub) asks for a review. A fresh request rings
   `lead-review` on the owning box (BH-4057/#4092, already on main).
2. `bin/lead-review.sh` (box) reviews it. New in this change: a pool worker
   whose terminal result (done, or `outcome=failed`) the jobs worker accepted
   with a 2xx rings `lead-land` from its exit trap (`lr_ring_land`), before the
   tick collects it. That is `lcw_ring lead-land <repo> <pr> <head>`, which
   sends `POST /api/wakes/lane` with dedupe `lead-land:<pr>@<sha12>`, so each
   (pr, head) gets one row however often it rings.
3. `bin/lead-review-land.sh` (hub) promotes the verdict when `bin/wake-loop.sh`
   claims that row, instead of waiting for its next cron.

These cases do not ring: a superseded row, a skip, a non-terminal failure
(agent call rc 74..79, rate limited, an unreadable live head), and a failed
result post. A review whose rules pack `could not run` delivers its result but
withholds the ring (`lead-land doorbell withheld … (rules pack could not run)`),
and the land cron promotes it. The tick summary gains `rung=N`.

## The owed rerun

The tick lock stays on fd 7 (`locks/lead-review-tick.lock`). A tick that finds
it held writes `state/lead-review/rerun-owed` and logs
`tick skipped: … (a review is running) (rerun owed)`. When the holding tick
ends, it releases the lock (`flock -u 7`, so a process it left behind cannot pin
it) and then relaunches ONE tick through `lcw_rerun`, however many ticks were
skipped. It also forces one when it deferred work to its start cap or deadline.
It does not force one into a refusal it would only repeat: low `/tmp`, the
spend cap, a stopped worker, or a rate-limit pause. The chain is bounded by the
new registry knob `LEAD_REVIEW_RERUN_MAX` (default 3, `0` = off), counted
through `LEAD_CHAIN_RERUN_DEPTH`. The host suite and the rules pack now run with
fd 7 closed.

## Cadence

`cron/lanes/710-lead-review.cron`, `713-lead-review-enqueue.cron` and
`715-lead-review-land.cron` (and their `catalog/lanes.d/*.json` cadences) moved
from `*/5` to `*/15`. Hops 2 and 3 are doorbell-driven now. Hop 1 (a builder
APPROVE reaching the enqueue) has no inbound ring, so it goes from up to 5 to up
to 15 minutes.

## Kill switch

`flags/lead-chain-wake-off` (or its settings row) stops every ring. The owed
rerun is local and bounded, so the switch does not affect it.

## Known gaps

- A running tick reads the request list once. A request that arrives mid-tick
  waits for the owed rerun.
- Until BH-4094 lands, a `lead-land` ring that hits a held land tick lock is
  dropped, and the `*/15` land cron picks the row up.
- `LEAD_REVIEW_LAND_RERUN_MAX` is not registered yet. `tests/lanes-registry-test.sh`
  §6 refuses a knob that nothing reads, and `bin/lead-review-land.sh` will not
  read it until BH-4094 lands.
