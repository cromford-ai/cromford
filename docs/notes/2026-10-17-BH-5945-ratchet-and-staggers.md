# Hub project-loop ratchet, cron staggers, lead-review lock measure (BH-5945)

Doc: TESTING, MERGE-CONDUCTOR, EVENTS

## What changed

1. **Ratchet.** `bin/project-loop-lint.sh` is the rules-pack component
   `project-loop`. A hub lane that a diff adds must not loop over projects in
   its own script (a `fleet-conf.sh --projects` read, a `fleet.conf` read loop,
   or a global lock around a loop over `$PROJECTS`). It must dispatch through
   `bin/lib/project-lanes.sh` (`pl_dispatch`, `pl_lane_dispatch`) or
   `bin/project-lane-run.sh`. A lane that needs one fleet-wide pass carries
   `# project-loop-ok: <reason>`. Existing lanes are not judged. Only the lane's
   own script is read, not the libs it sources.
2. **Staggers.** merge-queue and review-prs start minutes come from the
   project's fleet.conf cron offset: merge-queue `(6 + offset) % 20` (+20, +40),
   review-prs `(7 + offset) % 30` (+30). `bin/render-crontab.sh` moves a later
   project on the same box to the next free minute when an earlier one has it.
   Offset 0 keeps the old `6,26,46` and `7,37`. The registry cadence is now
   `*/20 * * * *` and `*/30 * * * *` (same period).
   box-small after the next render: project-8 mq 7 rp 8,
   cromford mq 9 rp 10, harness-console mq 11 rp 12, cromford mq 13 rp 14.
3. **Lead-review tick lock.** The tick writes `state/lead-review/tick-lock.since`
   when it takes `locks/lead-review-tick.lock`, logs `tick lock held <s>s
   started=<n>` when it releases it, and a skipped tick logs `held <s>s` from
   the stamp.

## Why

On box-small all four projects fired merge-queue at :06 and review-prs
at :07 in the same minute. A hub lane that walks every project under one lock
makes each project wait on the others; the per-project runner (BH-5913) exists
for that.

## Not done

The ticket asks to split the lead-review tick lock per project if one project
waits on another. BH-6984 already releases the lock when starts close, so the
lock now covers only the decide-and-start span. The two log lines give the
numbers that decide a split. No split in this change.
