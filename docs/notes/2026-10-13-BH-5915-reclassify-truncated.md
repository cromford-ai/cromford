# Classify a cut lead report from its hub copy, and re-open the parked ones (BH-5915)

Doc: OPERATING

## What changed

1. `bin/lesson-classify.sh` reads the full lead report when the worker cut the artifact at its
   4000-unit cap (`truncated: true`). It reads the job's newest `lead_report` transcript, which
   `bin/lead-review.sh` pushes since BH-5915 C0 (`docs/notes/2026-10-10-BH-5915-lead-report-transcript.md`).
   The lane uses that copy only when the ledger kept the whole body (not only its tail) and the
   first `# Lead review ` line is the same as the artifact's title. Then it classifies as usual and
   logs `verdict <v>: the artifact is cut; classified from the full report on the hub (job <j>, source lead_report, <n>B)`.
2. No usable copy: the lane parks the verdict as before. The log line and the run error keep their
   text and get the suffix `; no full copy on the hub (<why>)`. `<why>` is `absent` (no
   `lead_report` row), `tail-only` (the ledger kept only the tail) or `title-mismatch` (a copy for
   another PR or head).
3. A copy that cannot be read now (the transcripts index or the body read fails): the run is
   settled failed with a refund and the verdict is NOT parked. The log says
   `could not be read (unreadable); not parked, the next tick retries`. No model call is made.
4. New worker route `POST /api/block-classify/reset {verdict_id}`
   (`worker/jobs/src/routes/block-classify-reset.js`, bearer only). It resets only a `failed` run
   whose error names the `4000-unit artifact cap`: `attempts` goes to 0 and the error gets the
   prefix `requeued: `. Answers: 200 `reset:true`; 200 `replay:true` for a run already requeued;
   404 `no run`; 409 `not_cap_parked` for any other run; 400 for a bad `verdict_id`. The next
   claim clears the error, so a verdict that parks again can be reset again.
5. New one-shot `bin/lesson-classify.sh --requeue-truncated`. It takes `locks/lesson-classify.lock`,
   probes the route, and posts a reset for each `state/lesson-classify/parked-<id>`. It removes a
   marker only after a 200. A 409 or 404 keeps the marker (`kept`); any other answer keeps it and
   counts an error. It prints and logs one line
   `requeue-truncated: parked=<n> requeued=<n> kept=<n> errors=<n>`. Exit 0 when `errors=0`,
   else 1. It makes no model call and claims nothing. Cron passes no argument, so the hourly tick
   does not change.

## Operator step (once, on the hub)

Do this after the merge deploys the worker. Run each command from `/root/harness`.

1. List the parked verdicts: `ls state/lesson-classify/parked-* 2>/dev/null`. Find the ones parked
   for the cap: `grep 'truncated at the artifact cap' logs/lesson-classify.log`.
2. If a line says `no full copy on the hub (absent)`, or is from before this change (no suffix),
   run the C0 backfill on the box the line names. The command is in "Backfill" of
   `docs/notes/2026-10-10-BH-5915-lead-report-transcript.md`.
3. Run `bin/lesson-classify.sh --requeue-truncated`. Read the summary line.
4. If the command says a tick holds the lock, run it again after the tick ends.
5. If it says the route is not answering, the worker deploy is not live. Deploy it, then run step 3 again.
6. If `errors` is not 0, read `logs/lesson-classify.log` and `logs/jobs-client.log`, then run step 3 again.
7. After the next tick (minute 23), run
   `grep 'classified from the full report on the hub' logs/lesson-classify.log`.

A requeued verdict with no hub copy parks again on the next tick with `(absent)`. Do step 2 for
it, then step 3 again. The lane offers only verdicts inside `lesson_classify.since_days`
(default 14). A verdict older than that is reset but not offered again.

## Tests

`tests/lesson-classify.bh-5915-test.sh` (F1-F7 the lane, Q1-Q6 the one-shot, E1 a 12000-unit
report parked, backfilled, requeued and classified) and
`worker/jobs/test/block-classify-reset.bh-5915.test.js` (R1-R8 the route).
`tests/lesson-classify.bh-5806-test.sh` C9 still pins the park when the hub has no copy.
