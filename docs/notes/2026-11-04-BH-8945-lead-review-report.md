# A pool lead review report stays readable after the machine is gone (BH-8945)

Doc: OPERATING

## What happened

A pool lead review (a Fly machine, `fly/builder-runner.sh run_leadreview_job`)
wrote its report to `/data/harness/state/lead-reviews/lr-<pr>-<head12>.md` and
posted that path as the request's `report_ref`. The reaper then destroyed the
machine. The verdict note `report:<ref>` named a dead path, and no read took a
lead-review id. Case: the lead review of project-6 #3531,
2026-11-02. The report was in the
`lead_review_report` artifact of its job, but nothing pointed to it.

## What changed

- `bin/lead-review-report.sh <lead-review-id>` prints a stored report from the
  hub: request → `job_id` → `lead_review_report` artifact, and for a cut
  artifact the whole `lead_report` transcript (BH-5915). It also takes the
  `artifact:<job>/lead_review_report` ref. rc 0 whole, 2 prefix only, 3 absent,
  1 worker unreadable, 64 bad id.
- `run_leadreview_job` sets `LEAD_REVIEW_EPHEMERAL=1`. With it, `finish_done`
  posts `report_ref` = `artifact:<job>/lead_review_report`. A persistent box
  keeps the disk path.
- On that box, the full-body push of a cut report is read back and compared
  with the scrubbed body. It is retried up to `LEAD_REVIEW_REPORT_PUSH_ATTEMPTS`
  (knob, default 3) times, `LEAD_REVIEW_REPORT_PUSH_BACKOFF_S` (knob, default 5)
  apart, before RESULT, so before the reaper destroys the machine. Each failed
  try logs `full report for <key> (PR <url> head <sha12>) not on the hub after
  attempt <k>/<N>`. At the cap, one alert `--id lead-report-push-<job>` fires.
  The review stays done with the 4000-unit prefix artifact.

## Retention

No new store. The text lives in the existing `job_artifacts` and
`job_transcripts` rows. They are review history, which is archived, never
deleted, and other lanes read them (`lesson-classify.sh`,
`lead-review-land.sh`).

## Command

```bash
bin/lead-review-report.sh <lead-review-id> | tail -1
```
