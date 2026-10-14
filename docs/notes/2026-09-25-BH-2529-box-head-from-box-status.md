# The cost autohalt writes pause rows only; box harness HEADs come from box_status

Doc: COST, DB-COORDINATION-SPEC

## What changed

Goal-gap audit B15 (file state to DB state), three pieces in `bin/pipeline-health.sh`
and `bin/fleet-status-push.sh`:

1. **Cost autohalt, no jobs client.** `cb_halt` used to ssh-touch
   `flags/paused-<p>` on the owning box (or touch it locally when fleet.conf had
   no address). That branch is gone. With no `flag_set` the halt is `fail`: no
   file, no ssh, no `state/costhalt/<p>` stamp. The rate breaker pages
   `costhaltfail:<p>` ("the pause row could not be written ... pause it from the
   console (pause_board)"), and the zero-merge breaker's page says the same.
   The client path (`flag_set paused-<p> on`) is unchanged.
2. **Section 8, fleet checkout freshness.** Remote boxes are no longer asked
   over ssh, and there is no remote ssh re-sync. Each box's HEAD is read from
   `box_status.harness_commit` / `harness_reported_at` (written hourly by the box
   itself through `bin/lib/lane-gate.sh`), via the new `box_heads` verb in
   `bin/lib/jobs/boxes.sh`. A box is drifted when its report is fresh and it
   does not contain the newest first-parent `origin/main` commit older than
   `HARNESS_HEAD_GRACE_S` (default 5400, settings row
   `lane.pipeline-health.harness_head_grace_s`). A missing row, a stale report or
   an unanswered `/api/boxes` is logged to `logs/pipeline-health.log` as
   "<box> harness HEAD unknown: <why>" and not paged. box_status names a box by
   what it calls itself (JOBS_BOX, else the hostname) and fleet.conf by its ssh
   name, so both are compared as the cron box id (`cron_box_id_for`,
   `bin/lib/cron-lines.sh`): `box-project-3-1`, `box-project-3-2` and
   `project-3` are one box, and of two rows for one box the newest report wins. The hub's own checkout
   still auto-heals locally through `bin/harness-sync.sh deploy`. Remote re-sync
   is `bin/fleet-propagate.sh` and `update-runners.sh` alone.
3. **fleet-status-push** carries `harness_heads` (`{<box>: {head, reported_at}}`
   from one `box_heads` read; `null` plus `harness_heads_error: "unreachable"`
   when the read fails) and `hub_harness_head` (the hub checkout's short HEAD).
   `harness_heads` and its error are shed first when the payload is too big.
   `.hub` keeps its nine keys.

## Why

The ssh paths wrote and read state nothing else could see: a pause file with no
row behind it, and a HEAD answer that existed only for the length of one ssh
call. The DB already had both facts.

## Tests

`tests/pipeline-health-box-head.bh-2529-test.sh`,
`tests/fleet-status-harness-head.bh-2529-test.sh`. Case 8 of
`tests/routing-writers.bh-1373-test.sh` now pins the reverse of what it pinned
(no ssh, `costhaltfail`), and `tests/cost-containment.k1-test.sh` drives the
breaker with a `flag_set` stub.
