# The human-block report (BH-9427, C0)

Doc: OPERATING

Slice C0 of #9427. This slice adds the instrument: a report of why PRs park in
`BLOCKED_HUMAN`, how long they wait, and how each block ends. The child slices
C1-C4 change the parks themselves (head-not-reapproved, prequeue-red with main
red, queue-ejected-twice with an unknown reason, iron-law). Each child uses
this report for its before and after numbers.

## What changed

- New script `bin/human-block-report.sh`. It reads the conductor log only. It
  makes no GitHub, model or worker call.
- New hub lane `human-block-report`: `cron/lanes/781-human-block-report.cron`,
  daily at 06:40Z, lease-gated, `--daily`. Registry entry
  `catalog/lanes.d/human-block-report.json`. Kill switch
  `flags/lane-off-human-block-report`.
- New log `logs/human-block.log`: one line per daily run.

## Operator commands

```bash
/root/harness/bin/human-block-report.sh                       # the last 7 days (knob), all repos
/root/harness/bin/human-block-report.sh --last 30d            # 1..90 days
/root/harness/bin/human-block-report.sh --repo example-org/cromford
/root/harness/bin/human-block-report.sh --log /path/a --log /path/b --now 2026-11-12T06:40:00Z
tail -7 /root/harness/logs/human-block.log                    # the last week of daily lines
```

Exit codes: 0 printed; 2 bad arguments (nothing written); 3 no readable log.

## The source

`mc_transition` (`bin/lib/mc/settle.sh`) writes one line per state change to
`logs/merge-conductor.log`:

```
2026-11-10 10:00:00Z example-org/cromford#9100 READY -> BLOCKED_HUMAN head=abcd1234 reviewed=abcd1234 merge=CLEAN reason=iron-law (2 hit(s))
```

The report reads `logs/merge-conductor.log.1` (when present), then
`logs/merge-conductor.log`. A block in the rotated part and its MERGED in the
current part join up. Every other line is ignored: a `re-reasoned` line, a
`MERGED <key> by conductor` line, a `BLOCKED_AGENT` line, a line with no
timestamp, and a truncated last line (fewer than 7 fields).

## The rules

1. The states come from the FIRST ` -> ` of the line. The reason is the text
   after the first ` reason=`. A line after `--now` is ignored.
2. An episode starts at `-> BLOCKED_HUMAN` and ends at the next transition of
   the same key. Wait = end - start, in whole minutes. An episode with no end
   waits until `--now`.
3. Outcome: the first MERGED after the episode is `merged`. The first CLOSED
   or ABANDONED is `closed`. No end is `blocked` (still blocked). Anything else
   is `open`: the PR left the block and is not merged or closed yet.
4. Class = the reason up to the first `:`, space or `(`. So `iron-law (2 hit(s))`
   is `iron-law`, and `prequeue-red: tests/x.sh on main …` is `prequeue-red`.
   An empty reason is `(none)`. Detail = the text after `<class>: ` up to
   ` on main`, ` — ` or the end, cut to 60 bytes.
5. An episode counts when it STARTED in `[now - N days, now]`. A MERGED in the
   window counts in `merged_prs`. It counts as human-blocked when the same PR
   had an episode before the merge, in any part of the files read.
6. Median: the middle value. For an even count, the floor of the mean of the
   two middle values.

A same-state re-reason does not start a new episode: the episode keeps the
class it entered with. A PR that leaves the block and enters it again has two
episodes.

## The output

```
human-block-report: window 7d ending 2026-11-12T06:40:00Z, repo all, source …, window_src default
class   blocks  prs  median_wait_min  total_wait_min  merged  closed  blocked  open
prequeue-red  4  3  45  160  2  1  0  1
…
TOTAL   14  13  45  5021  5  4  2  3
merged_prs  6  human_blocked_before_merge  5  share_pct  83.3
detail  prequeue-red  tests/lanes-registry-test.sh  2
repo    example-org/cromford  blocks 11  merged 5  blocked_merged 4  share_pct 80.0  median_wait_min 60
```

The daily line in `logs/human-block.log`:

```
2026-11-12T06:40:00Z [human-block] status=ok window=7d window_src=default blocks=14 prs=13 median_wait_min=45 total_wait_min=5021 merged=5 closed=4 still_blocked=2 open=3 merged_prs=6 blocked_share_pct=83.3 classes=prequeue-red:4/45,… repos=example-org/cromford:11/4/5/60,…
```

`repos=` is `<slug>:<blocks>/<blocked_merged>/<merged>/<median_wait_min>`.
When no log is readable, the line is `status=no-source paths=<p1,p2>` and the
run exits 3. An unread log is never a zero count.

## How to read the "Done when" numbers of #9427

- BLOCKED_HUMAN transitions per week: `blocks=` of the daily line (7-day window).
- Share of merged cromford PRs that were human-blocked: the `share_pct`
  of the `repo example-org/cromford` row.
- Median wait of a human block in cromford: the `median_wait_min` of that
  same row.

Part of each wait is resolver time, not human time: most of these reasons are
resolver hand-offs (`mc_handoff_owns`, `bin/lib/mc/classify.sh`). The report
shows the conductor state as it is and does not split the two.

## Knobs

- `HUMAN_BLOCK_REPORT_WINDOW_D` (7, 1..90 days): the default window. `--last`
  wins. A bad value falls back to 7 and the run says `window_src fallback`.
- `HUMAN_BLOCK_REPORT_DETAILS` (3, 1..20): detail rows per class.

## Retention

`logs/human-block.log` grows by one line (under 600 bytes) a day, about 220 KB
a year. No retention job is needed. The lane writes nothing under `state/`.

## Tests

`tests/human-block-report.bh-9427-test.sh` runs the real script on the fixture
logs in `tests/fixtures/bh-9427/`. A sentinel `gh`, `curl` and `claude` first
on PATH prove 0 vendor calls.
