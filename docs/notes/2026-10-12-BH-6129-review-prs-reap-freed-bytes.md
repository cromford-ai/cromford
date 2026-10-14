# review-prs tick-start cleanup logs the bytes it freed (BH-6129)

Doc: OPERATING

## Why

Sentry issue 7784795152 (CROMFORD-HARNESS-7): the review-prs pool on
box-project-1-1 ran capped by low /tmp, and nothing said what filled
/tmp or what the cleanup recovered. BH-6130 and BH-6132 already shipped fixes
1 to 3 of the ticket (event and log numbers, one event per cap change, removal
of a dead tick's scratch). This change is fix 4: log the bytes freed.

## What changed

`rp_scratch_reap` in `bin/lib/review-prs-tmp.sh` measures each dead tick's
`review-prs-wk-<pid>` dir with `du -sk` (bounded by `RP_TMP_DU_TIMEOUT_S`,
default 20 s, no `-x`) before it removes it. The lane log line is now:

    removed N stale scratch dir(s) under <tmp>, freed <bytes> bytes

If `du` could not measure a removed dir, the line reads
`freed at least <bytes> bytes (<u> dir(s) not measured)`. A dir held by a live
`review-prs.sh` is skipped before the `du`, so it is never counted. A dir whose
`rm` failed counts in neither number. No line is written when nothing was
removed. No knob, no event and no state file changed.

The line prefix is unchanged, so the BH-6130 reader
(`tests/review-prs-tmp.bh-6130-test.sh`, R1) still matches.
`tests/review-prs-tmp-freed.bh-6129-test.sh` pins the full line, the held-dir
exclusion, one event over 10 capped ticks, and the return to the configured
concurrency on the first tick with enough /tmp.

## Owed operator step

Fix 5 of the ticket is not code. After deploy, read the review-prs lane log
and the next CROMFORD-HARNESS-7 event on box-project-1-1. If /tmp is
still under the threshold after the cleanup line, file a follow-up ticket that
names the `top` entries of the event.
