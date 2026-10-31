# blocked-resolver on a Fly lane machine with no clone (BH-7630)

Doc: PROJECT-LANES

## What went wrong

On 2026-10-19 `lane_placement.blocked-resolver=fly` ran the resolver on the Fly
lane-run machines. Those machines have no project clones under `/root/repos`.
156 rungs could not START that day:

- `mc_rebase rc=4 … a clone or credential problem` (rung 1 and rung 1b).
- `there is no local clone at /root/repos/<p> for the fix round to work in`.

Each one was logged as "no rung spent, retried next tick". No fix round
started and no alert came. At 22:38Z the row was set back to `hub`.

The cause: `br_fix_round` queued the round for the owning box only when
`hub_box_builds_here` said no. That predicate says yes on every box that is not
the hub, and a lane machine is not the hub. So the lane machine ran the round
itself and stopped on the missing clone.

## What changed

- **Fix rounds go to the owning box from a lane machine.** `br_fix_hops`
  (bin/blocked-resolver.sh) is rc 0 on the hub and on a lane machine
  (`LANE_RUN_ID` set), and never on a `--fix-here` run. `br_fix_round`,
  the in-flight `fix_round_jobs` gate in `br_one` and the slot count
  `br_remote_open_prime` use it. A lane machine now writes the same
  `fix_round_jobs` row the hub writes (`br_fix_remote`), reads it on the next
  run and adopts the result.
- **Rung 1 and rung 1b go to the owning box from a lane machine with no
  clone.** `br_lane_no_clone <p>` is rc 0 when `LANE_RUN_ID` is set and
  `$REPOS/<p>/.git` does not exist. `br_mechanical` and `br_regen_rung`
  (bin/lib/br/ladder.sh) then call `br_hop_rung`, which writes a
  `fix_round_jobs` row through `br_fix_remote` with `hop_rung` on the record
  copy (`mechanical`, or `regen:<next>`). The row args stay six. The box's
  `--fix-here` reads `hop_rung`, drops it from the record, and runs
  `br_mechanical` or `br_regen_rung` first (`REBASE_ON_POOL=0`: a pool rebase
  moves a hub conductor row). The agent fix round runs only from that rung's
  own failure arm. A clean merge of main spends 0 fix rounds. The lane machine
  writes no record; the box's record comes back through the adopt. A lane
  machine with a clone, and every hub run, keep the old path. A box that
  predates this change ignores `hop_rung` and runs the fix round, as before.
- **A lost write-back does not buy a second round.** On a lane machine
  `br_fix_adopt` saves the record locally, and it reaches the hub only through
  the write-back. When `fix_round_get` answers none, `br_fix_heal` reads the
  newest adopted row (`fix_round_adopted_record`, bin/lib/fix-round-queue.sh)
  and saves its `record_out` when it holds more attempts than the local record.
  The ladder then reads the cap from that record. An unreadable answer holds
  the park.
- **Every rung that could not START is counted.** `br_setup_blocked` calls
  `br_setup_rate` before its once-per-episode marker. It appends
  `epoch TAB placement TAB class TAB rung TAB rkey` to
  `state/blocked-resolver/<p>/setup-blocked.tsv`. Placement is `fly` when
  `LANE_RUN_ID` is set, else `hub`. The class comes from `br_setup_class`:
  `no-clone`, `mc-rebase-setup`, `worktree`, `no-owner-box`, `no-branch`,
  `ref-unresolved` or `other`. The path is under the write-back allow-list
  `state/blocked-resolver/<p>/**`, so a Fly row reaches the hub.
- **One alert per project per 24 h.** More than `BR_SETUP_BLOCKED_ALERT_N`
  (default 2, the fragment
  `catalog/lanes.d/blocked-resolver.knobs.d/BR_SETUP_BLOCKED_ALERT_N.json`)
  rows of one placement in the last hour send one `lane-alert.sh --id
  resolver-setup-blocked-<placement>-<project>` line. It names the count, the
  placement, the class and the latest reason. On `fly` it gives the kill row.
  The severity is `warn`, or `critical` when two or more projects are over N
  on that placement. The marker `setup-blocked.alerted` holds the epoch it was
  written at and holds the next alert for `BR_SETUP_BLOCKED_ALERT_HOLD_S`
  (default 86400 s, the fragment `BR_SETUP_BLOCKED_ALERT_HOLD_S.json`). It is
  an epoch, because an empty rewrite has the same sha and the checkpoint does
  not carry it. The marker is written before the send.
- **No per-PR page while the hold stands** (comment 6315926752, operator,
  2026-10-21: "rc=4 repeats within 24h raise one alert per project, not one
  per PR"). `br_setup_blocked` sends its per-park page only when the project's
  rate alert has not fired inside the hold. The per-park record, event and log
  line do not change.
- **The dispatch warns while placed fly.** `blocked-resolver.sh --dispatch`
  runs `br_placement_check` before `pl_dispatch`. When `lp_decide` answers
  `fly`, it sums the `fly` rows of the last hour over every
  `state/blocked-resolver/*/setup-blocked.tsv` on the hub. Over N, it sends one
  `--id lane-placement-unready-blocked-resolver` warning with the projects, the
  classes and the kill row. It does not change the placement and it does not
  stop the dispatch.

## Retention

`setup-blocked.tsv` keeps one hour of rows. Each write rewrites it with only
the rows younger than 3600 s (temp file and `mv`). The marker is one file per
project that holds one epoch.

## Moving the lane to Fly (adds to the BH-6128 note)

Before the flip, and for one hour after it, this must print no row on the hub:

```bash
awk -F'\t' '$2=="fly"' /root/harness/state/blocked-resolver/*/setup-blocked.tsv 2>/dev/null
```

If it prints rows, set the row back:
`bin/jobs-client.sh setting-set lane_placement.blocked-resolver hub`.

## Verified by

`tests/blocked-resolver-lane-no-clone.bh-7630-test.sh` (F1-F5, M1-M3, H1-H2, L1,
G1-G2, K1, A1-A8, D1-D4).
