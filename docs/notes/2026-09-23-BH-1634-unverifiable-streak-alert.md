# A PR whose merge state stays unreadable now pages once, and gh-quota F3 notices a lost diff read

Doc: MERGE-CONDUCTOR

Two follow-ups to BH-1585 (the GraphQL cuts).

## The UNVERIFIABLE streak

Since BH-1585 a failed per-PR merge-state read in the open list marks only that
row `UNVERIFIABLE`, and `bin/merge-conductor.sh` skips the row with one log line.
A PR whose read kept failing was skipped every tick with nothing else said.

Now each skip adds one to that PR's streak in
`state/merge-conductor/unverifiable/<owner_repo#N>` (one line: count, alerted).
The skip's single log line carries it: `… retried next tick (unverifiable 3/6 ticks)`.
When the count reaches `MC_UNVERIFIABLE_ALERT_TICKS` (registered knob, default 6,
0 = off; per project `lane.merge-conductor.<project>.mc_unverifiable_alert_ticks`)
the conductor writes ONE `mc_alert` line, `conductor: <owner/repo#N> UNVERIFIABLE — …`.
The alerted flag is written before the alert is sent, under the file's own lock.

- A tick that reads the PR's merge state as a real state removes the file, so a
  later streak alerts again (one alert per streak, not once ever).
- A tick held by `MC_TICK_SECS`, or one whose whole list failed, never reaches
  the row: it neither counts nor resets. A repo-wide list outage already has its
  own blind-streak alert (BH-847).
- A draft PR is never read lazily, so it never starts a streak.
- Files older than three days are removed each tick, beside the head-lag gc.

Pinned by `tests/mc-unverifiable-alert.bh-1634-test.sh`, which drives the real tick.

## gh-quota F3

`tests/gh-quota.bh-426-test.sh` F3's per-PR REST read floor was 3, and the list's
three lazy merge-state reads met it on their own. It is 6 now (3 lazy reads plus
3 `mc_pr_diff` reads), and a new case runs F3's predicate on the mutant that has
lost `mc_pr_diff`: it must fail.
