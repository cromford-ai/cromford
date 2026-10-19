# The lead review enqueue is unwired; its hub jobs run in the reconcile sweep (BH-7235)

Doc: OPERATING

Slice C1 of BH-5878. The lead review worklist (`bin/lead-review.sh tick` on
each box, `cron/lanes/710-lead-review.cron`) is now the one input of the lead
review.

## What changed

- `cron/lanes/713-lead-review-enqueue.cron` has no schedule line, and the
  lane `lead-review-enqueue` has `boxes: []`. No crontab runs
  `bin/lead-review-enqueue.sh`. The script, its lane JSON and its knobs stay
  until C2 (BH-7236).
- Why a comment-only stub and not a deleted file: with `REGISTRY_SOURCE=db`
  (every box since BH-5651), `bin/render-cron.sh` overlays the D1 registry's
  `lane_boxes` rows on the file `.boxes`. D1 still holds the seeded row
  `lead-review-enqueue/hub`, so the hub keeps the lane, and a lane with no
  `cron/lanes/` fragment makes the render refuse ("registry lanes with no
  cron/lanes fragment"). The first attempt deleted the file and the pre-push
  gate refused it in render-cron. A refused render freezes the hub crontab.
  The stub is a fragment with no schedule, so the render is green and runs
  nothing. C2 deletes the stub with the lane JSON; then the overlay, which
  maps over file lanes only, ignores the stale D1 row.
- `bin/wake-loop.sh` no longer sources `bin/lib/lead-reenqueue.sh` and no
  longer launches `bin/lead-review-enqueue.sh pr` on a hub pr/checks wake
  (BH-5581). A re-pushed head waits for the owning box's next */15 worklist
  tick.
- `bin/pr-state-reconcile.sh tick` (hub, */15) runs the two hub jobs of the
  enqueue for each open PR, after the CI fact, fail-open:
  - live probes (BH-5801): `lp_run_for_head` for a head that is not draft,
    not held, has a builder APPROVE and green CI on it, and no lead verdict;
  - console QA clear (BH-5909): `cqg_clear_block` for a head with a standing
    lead verdict in fleet.conf's `cromford` repo. The marker stays in
    `state/lead-review-enqueue/qa-reset-*`.
  `alert_once` (marker `state/pr-state-reconcile/alerted-<id>`) raises the
  live-probe lane's out-of-tries alert.
- Retention:
  - `bin/lib/lead-gates.d/99-state-sweep.sh` (`lg_tick_state_sweep`) deletes
    the gates' per-head markers in `state/lead-review-enqueue/` and the rows
    of `risk.tsv` and `requested.tsv` older than
    `LEAD_REVIEW_GATE_STATE_KEEP_DAYS` (lane `lead-review`, default 7), at
    most once in 24 h a box. Gates 50 and 95 keep pruning `delta.tsv`,
    `modes.tsv` and `failed-retry.tsv` themselves.
  - `bin/pr-state-reconcile.sh` deletes `state/pr-state-reconcile/alerted-*`,
    `state/live-probes/*` and `state/lead-review-enqueue/qa-reset-*` older
    than `PR_STATE_RECONCILE_MARKER_KEEP_DAYS` (default 14), at most once in
    24 h.
  - Both are dry runs the first time on a box (no stamp), and both write one
    audit line a run (`state-sweep:` in `logs/lead-review.log`,
    `marker-sweep:` in `logs/pr-state-reconcile.log`). 0 turns either off.
- `cqg_report`'s NOTE now names the reconcile sweep as what resets a console
  QA BLOCK.
- Deleted suites, each replaced by a worklist twin: the BH-5581 suite (the
  push launch is gone; `tests/lead-enqueue-unwired.bh-7235-test.sh` W1 pins
  the absence), the BH-5796 suite (`tests/lead-gates-rebase-hold.bh-5876-test.sh`)
  and the BH-5798 suite (`tests/lead-gates-self-check.bh-5876-test.sh`).

## Check it

- `crontab -l | grep -c lead-review-enqueue` on the hub prints 0 after deploy.
- `grep -E 'marker-sweep|lead review .* reset' /root/harness/logs/pr-state-reconcile.log`
- `grep state-sweep /root/harness/logs/lead-review.log` on a build box.
