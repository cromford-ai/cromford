# Console preview: the streak head and its retry (BH-6270)

Doc: bin/console-preview-deploy.sh

## What changed

Four fixes in `bin/console-preview-deploy.sh`, from the NOTEs of lead review
lr-6056-72e007976067 on PR #6056 (BH-5909 slice 1):

1. **The streak survives a charge.** `state/console-preview-deploy/.box-streak`
   (`<sha> <k>`) is now removed only when its own head uploads, or when the
   retry charges the head to terminal (`failed N`, N >= MAX_ATTEMPTS). Another
   head's upload and a non-terminal charge keep it. Before, the next run
   started the streak at 0 and the head stopped two more runs, each with a
   `console-preview-box` alert.
2. **A retry that uploads runs QA and posts the comment.** The QA run, the kept
   comment body and `post_one` moved into `qa_and_post`, which the loop and the
   retry both call. The record becomes `done` (or `posting k`), and the retry
   counts in `deployed`. Before, the retry wrote nothing, so the next tick
   uploaded the same head again. The retry is still at most one per run, so a
   run can make MAX_PER_RUN + 1 deploys.
3. **The retry needs a LATER upload and no box stop.** `PROVEN` is set only by
   an upload after the streak head was skipped. `BOXSTOP` is set when the loop
   stops on a box fault, and then the retry does not run. A build-stage box
   fault on the retry (for example `npm ci` rc 125) raises the same
   `console-preview-box` alert as the loop (`box_alert`) and charges nothing.
4. **401, 403 and 429 need an error word.** `upload_fault` reads a status code
   as a box fault only after `status`, `http`, `code`, `error`, `received`,
   `returned` or `response` (`HTTP 403`, `status: 429`, `Error 401.`). A code
   inside a file name (`dist/403.html`, `/errors/429.html`) no longer makes a
   Pages refusal the box's.

## Why

Each defect either charged a head wrongly, raised alerts for a head the lane
had already judged, or uploaded a head again with no QA and no comment.

## Known limit

The plain-word box matches (`forbidden`, `unauthorized`) are unchanged. A file
named `dist/forbidden.html` in a Pages refusal still reads as a box fault.

## Tests

`tests/console-preview-deploy.bh-6270-test.sh` (S1, S2, S3a, S3b, S3c, S4).
`tests/console-preview-deploy.bh-5909-test.sh` is unchanged and still green.
