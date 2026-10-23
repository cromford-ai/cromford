# BH-8020: the verdict-read step names, times and bounds each call

Ticket: example-org/cromford#8020 (Sentry CROMFORD-HARNESS-T). A merge
conductor worker on box-hub (harness-console) was killed at its 419 s
deadline in step `verdict-read`. The event named the step but no call, and the
lane log had no line for the step's reads.

Doc: MERGE-CONDUCTOR

## What the step reads

`pr_worker` (`bin/merge-conductor.sh`) runs these calls in step `verdict-read`:

| Call name | Function | What it reads |
|---|---|---|
| `review-file` | `verdict_parse -L <record>/review.md` | the build record's verdict (local file) |
| `headbound` | `job_verdict_headbound` | jobs worker `GET /api/verdict?pr=` |
| `ledger-verdict` | `job_verdict` | jobs worker `GET /api/verdict?pr=` (the same URL again) |
| `rr-verdict` | `mc_rr_verdict_of` | the local re-review job file, only when ledger and record disagree |
| `contradiction` | `job_verdict` in `mc_contradiction_words` | jobs worker `GET /api/verdict?pr=`, only on a CONTRADICTION on this head |
| `eject-rebased` | `eject_rebased_moved` | local files; a `job_ledger_put` POST on a head marked `ejectrebase` (a write) |

Each jobs request (`_jobs_req`) has `curl -m 8`, one transport retry and one
overload retry. One request can take about 38 s; the step makes up to 3.

## What changed

- `mc_vr_begin` / `mc_vr_end` (new fragment
  `bin/merge-conductor.d/bh-8020-verdict-read-bound.sh`) frame the step.
  Inside the frame, `mc_vr_run` (`bin/lib/mc/classify.sh`) hands each call to
  `mc_vr_call` under its name. Outside the frame (the queue pass,
  autoenqueue, batch-resolve, parentprio) `mc_vr_run` runs the call as before.
- Each call writes the BH-7029 call line to `MC_CALL_FILE` while it runs, as
  `verdict-read/<name>`. A deadline kill now names it: the WORKER_DEADLINE
  line ends ` | call: verdict-read/<name> (<n>s) | calls: ...`, and the Sentry
  event has the tag `call` and the extras `call`/`call_s` (the BH-7029
  machinery in `bin/lib/fanin.sh`, unchanged).
- Each READ runs under the merge-conductor knob
  `MC_VERDICT_READ_CALL_TIMEOUT_S` (default 45 s, 0 = no bound, not a number =
  45; settings row `lane.merge-conductor.mc_verdict_read_call_timeout_s`). The
  value used is never past the worker deadline minus 15 s
  (`mc_lock_wait_left`). With under 1 s left, the read is not started.
- Past the bound, the read's process tree gets TERM, then KILL 3 s later. The
  read answers rc 124 with no output; a late answer never counts. Every later
  call of the step runs nothing. One line goes to the lane log:
  `<key> VERDICT_READ_TIMEOUT call=verdict-read/<name> took=<n>s timeout=<b>s rc=124: ...`.
  Then `pr_worker` returns: nothing is decided on the PR this tick, the PR
  lock goes with the worker, and the row is left as it is. A READY row gets
  the ready-why note `verdict-read-timeout`, so fan-in reports
  `READY held:verdict-read-timeout`. No alert and no Sentry event for a cut.
- `eject-rebased` is a write. It is named and timed, never cut.
- Every step writes ONE line:
  `<key> VERDICT_READ took=<s.s>s calls: review-file=0.0s rc=0 headbound=0.4s rc=0 ledger-verdict=0.3s rc=0 eject-rebased=0.0s rc=0`.

## How to read the next event

1. In Sentry, read the tag `call` on a `conductor-worker-deadline` event in
   step `verdict-read`. It names the call that ran at the kill.
2. In `logs/merge-conductor.log`, find `<key> VERDICT_READ took=` lines. Each
   one gives the seconds and rc of every call of the step.
3. Find `VERDICT_READ_TIMEOUT` lines. Each one names a read that the bound cut.

## Not changed

- The cause of the 419 s kill is not known; this change records it the next
  time. The duplicate `GET /api/verdict` (`headbound` and `ledger-verdict`
  read the same URL) is left as it is.
- `mc_verdict`'s callers outside the step keep their unbounded reads.
