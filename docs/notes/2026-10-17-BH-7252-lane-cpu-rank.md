# BH-7252 C0: hub lane CPU rank (CPU seconds per hour per lane)

Ticket #7252 asks for more hub lanes on Fly lane-run machines, the most
expensive lane first. C0 is the measurement. The later slices (C1..Cn) move
one lane per PR.

## Why the table is not in this PR

The build box is a Fly pool box. It has no hub `/proc`, no `JOBS_URL` and no
hub state. So this PR ships the instrument, and the hub posts the measured
table to #7252 itself, with no human step. The only hub numbers that this box
can read are the BH-6939 baseline on #6881 (2026-10-16T18:02:51Z): runnable
p50 38.48, p90 64.04; steal p50 50 %; forks/s p50 1123. That baseline has no
split per lane and no load5.

## Method

- `bin/lane-cpu-sample.sh --cpu-s` (new, sample mode only) adds a third
  column to each row: CPU seconds per hour = ticks * 3600 / (CLK_TCK *
  --seconds), one decimal, half up. Ticks are utime + stime of the lane's
  process tree, reaped children included (the BH-6173 rules). Without
  `--cpu-s` the output does not change.
- `bin/lane-cpu-rank.sh` (hub lane, daily 14:05Z, behind `hub-lease.sh check`)
  runs one window of `LANE_CPU_RANK_SECONDS` (3600) at
  `LANE_CPU_RANK_INTERVAL_S` (5). It reads `/proc/loadavg` before and after.
- 3600 CPU s/h is one core busy for the whole hour.

## Table format (the comment on #7252)

```
Window: <start> to <end> (UTC). Host: <host>. Interval: 5 s.
Load (load1/load5): start <l1>/<l5>, end <l1>/<l5>.

| rank | lane | CPU s/h | share % | placement | hub-only reason |
|---|---|---|---|---|---|
| 1 | <lane> | <n.n> | <n.n> | hub|fly | <lane_placement.<lane>.hub_only row, or "not classified"> |
| - | other | <n.n> | <n.n> | - | not a lane |
Lanes not shown: <n> (<n.n> CPU s/h).
<!-- lane-cpu-rank:7252 -->
```

- `placement` is `lp_decide <lane>` at post time (`bin/lib/lane-placement.sh`).
- `hub-only reason` is the `lane_placement.<lane>.hub_only` settings row. No
  row is `not classified`: no slice has judged that lane yet.
- `other` is CPU under no `bin/<name>.sh` ancestor (the kernel, cron, sshd).
- The posted body is also in `state/lane-cpu-rank/report.md` on the hub.

## Post once

- `state/lane-cpu-rank/state-<issue>`: `posted <ts> <issue|found>`,
  `attempts <n>` or `gave-up <ts> <reason>`. A run with `posted` or `gave-up`
  exits at once.
- Before the hour of sampling, the run reads the issue comments. A comment
  with the exact marker `<!-- lane-cpu-rank:<issue> -->` stops the run
  (`rank=found`).
- 6 failed runs (read, sample or post) write `gave-up` and one
  `lane-alert.sh --log-only lane-cpu-rank` line.

## Measure again (the "after" numbers)

1. Set the settings row `lane_cpu_rank.issue` to the issue that gets the after
   table (code default 7252).
2. Wait for the next 14:05Z run, or run `bin/lane-cpu-rank.sh` on the hub.
3. Compare load5 and the moved lanes' rows with the before table.

## BH-7406: why the table did not post

Two daily hub runs (2026-10-17T14:05Z, 2026-10-18T14:05Z) posted no table on
#7252. The cause is the token order in `bin/lane-cpu-rank.sh`:

1. Step 2 arms the App token once (`gh_auth_for`), before the comment read.
   `bin/gh-token.sh` serves a cached installation token until 5 min before it
   expires, so that token has 5 to 60 min left.
2. The sampler then runs for 3600 s.
3. The post used the same `GH_TOKEN`. It had expired, so the POST got 401. The
   run wrote `attempts <n>` and logged `rank=post-failed` with no cause.

The fix (BH-7406 C0):

- The script calls `gh_auth_for` again right before the post, so the post runs
  on a token with at least 5 min left.
- A failed run ends its log line with ` why=<cause>`: `http-<status>/<reason>`
  for read-failed and post-failed, `sampler-rc-<rc>[:<stderr line>]` for
  sample-failed, the first missing piece for not-configured.
- The settings row `lane_cpu_rank.issue` is seeded 7406
  (`worker/jobs/schema.d/202610182044-bh-7406-lane-cpu-rank-issue.sql`,
  `INSERT OR IGNORE`). #7252 is closed and #7406 carries the rest. A new
  `state-7406` file starts at 0 attempts. The marker is now
  `<!-- lane-cpu-rank:7406 -->`.

## Before numbers (hub load5)

- 52.42 at 2026-10-17T09:30:45Z.
- 57.69 at 2026-10-18T16:06Z (#issuecomment-6252072531).
- Target: under 24. The after number comes from a later slice of #7406.

## Rule for C1

1. Read the newest comment on #7406 that holds `<!-- lane-cpu-rank:7406 -->`
   (the marker of the `lane_cpu_rank.issue` row).
2. Take the top row whose reason is `not classified` and whose placement is
   not `fly`.
3. Read that lane's script. If it reads hub-only state (local repos, flag
   files, the hub's gh token), add a `lane_placement.<lane>.hub_only` row with
   the reason and take the next row.
4. Else add the `lane_placement.<lane>` row (`fly`), a routing test, a kill row
   back to hub, and a 1 h after check.

## Live probe (hub)

- `tail -3 /root/harness/logs/lane-cpu-rank.log` shows `rank=posted
  issue=7406(row)` after 15:05Z on the first day after deploy (BH-7406).
- #7406 has one comment with `<!-- lane-cpu-rank:7406 -->`.
