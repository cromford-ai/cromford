# A cut lead review report is stored whole on the hub (BH-5915)

Doc: OPERATING

## What happened

`bin/lead-review.sh` puts each report in the job artifact `lead_review_report`. The worker caps an
artifact detail at 4000 UTF-16 units, so `lr_detail` cuts a longer report and sets `truncated:true`.
The full report stayed only on the reviewing box, at `state/lead-reviews/<key>.md`. The hub could not
read it, and a hub reader of a cut report saw only its first 4000 units.

## What changed

1. `bin/transcript-push.sh` allows a fourth artifact source, `lead_report`. It uses the same path as
   `plan_md`, `review_md` and `decompose_run` (BH-531): the file is the body, with no header, on the
   reserved slot (no phase, attempt 100), after `bin/transcript-scrub.sh` and under the 150000-unit cap.
2. `finish_done` in `bin/lead-review.sh` pushes the report file as `lead_report` when its detail has
   `truncated:true`. The push comes before the artifact put. It is fail-open: a failed push never
   stops the artifact put, the result post or `job done`. The lane logs
   `full report for <key> handed to transcript-push.sh as lead_report (job <job>)`.
3. A report that fits is not pushed. The replay of a stored artifact (`stored=1`) is not pushed.
4. The `lead_review_report` artifact, its `truncated` flag and the posted GitHub review do not change.
5. Mission Control labels the row "lead review report (full)" (`console-ui/src/lib/transcripts.js`).

No worker, schema or deploy change. The job-detail poll sends transcripts as an index only, so the
poll payload stays bounded.

## How the hub reads it

```bash
bin/jobs-client.sh transcript-get <job> source=lead_report
```

rc 0 prints the body. rc 1 means no row (no push, a failed push, or an outage). A reader must:

- treat `JOBS_TRANSCRIPT_TRUNCATED=1` as "not full": the ledger kept only the tail of a report over
  150000 units;
- check the first line against the artifact's title, the same check `bin/lead-review-land.sh` makes;
- know that this copy is the scrubbed copy. A secret-like value in the report is stored redacted.

## Backfill for a report cut before this change

Run this on the box that holds the report, from the harness root. Replace `<job>` with the
`lead_review` job id and `<key>` with the report key (`lr-<pr>-<sha12>`):

```bash
JOB_ID=<job> TRANSCRIPT_SOURCE=lead_report bin/transcript-push.sh lead-review pipeline "" state/lead-reviews/<key>.md
```

The script always exits 0. Check `logs/transcripts.log` for `pushed <n>B source=lead_report`, then
read it back with the hub command above.

## Not in this change

`bin/lesson-classify.sh` reading `lead_report` first, and the one-shot re-classify of parked verdicts,
wait for PR #5892, which adds that file.
