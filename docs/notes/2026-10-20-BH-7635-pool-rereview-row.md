# The pool runs a conductor re-review row (BH-7635, slice C1)

Doc: MERGE-CONDUCTOR, FLY-POOL

## Problem

A lane-run machine cannot run the conductor's detached re-review: the job
file would never reach the hub. So `mc_rereview_spawn` on a machine only
writes `deferred=rereview`, and the hub takes the step back (slice C0 made
that a keyed tick). The ticket asks for the re-review to be a queued pool
job, the same way a rebase is (`RB-<pr>-<head8>`).

Before this slice, no part of the pool knew a re-review row. A row
`RR-<pr>-<head8>` with meta `kind=rereview` became a plain build job
(`{ticket_id:"<pr>",key:"RR-…"}`) in `queue_row_job_file`, and
`pool_spawn_decision` asked the ticket gates of "ticket <pr>". So a pool
would have built ticket <pr>: a PR and a board comment nobody asked for.

## What changed

This slice is the POOL side only. It adds no producer, so no `RR-*` row
exists in production after it merges. Slice C2 adds the producer.

1. `bin/lib/queue-row-job.sh`: meta `kind=rereview` (flat or nested) on an
   `RR-*` key becomes job.json `rereview:{kind,slug,url,pr,reviewed,head,
   reason,dedup}`. Each field is checked: `slug` charset, `head` 40 lowercase
   hex, `reviewed` that or `-`, `pr` a number, `reason` `''|noverdict|prov`,
   `url` the PR's own url (or empty, then derived), and the key must be
   `RR-<pr>-<head8>`. A bad field, rereview meta on another key, or an `RR-*`
   key with other meta gives rc 3: the row is closed `failed` with
   `rereview meta rejected (<field>)`, one alert line, and no queue file.
2. `bin/lib/rereview-job.sh` (new) is the machine body.
   `rereview_job_run` runs `mc_rereview` once, under the call-guard fp the
   hub job uses, and writes one RESULT. The format is in the file header:
   line 1 is `REREVIEWED APPROVE|BLOCK`, `REREVIEW_NOVERDICT`,
   `REREVIEW_LANE_FAILED <why>`, `REREVIEW_DEFERRED <why>` or
   `REREVIEW_SETUP_FAILED <why>`; then `PR:`, `HEAD:`, `REVIEWED:`,
   `REASON:`, `MODEL:`, `RUNNER:`; after `REREVIEWED` only, the line
   `--- review ---` and the review text verbatim. A body over
   `RR_JOB_BODY_MAX` (262144 bytes) is never cut: line 1 becomes
   `REREVIEW_LANE_FAILED review body over 262144 bytes`. A verdict also
   writes the `rrjob <slug>#<n> <head> done` row, as `mc_rereview_run` does.
3. `fly/builder-runner.sh`: a job with `.rereview.kind == rereview` goes to
   `run_rereview_job` (warm-up, the lib, one RESULT, beat
   `stage:"rereview_done"`) and never to the build path.
   `pool_result_row_write` skips `RR-*`.
4. `bin/result-prefix-ok.sh`: `REREVIEWED` and `REREVIEW_` are RESULT
   prefixes. `REREVIEWX` and `RR_APPROVE` are not.
5. `bin/lib/mc/rebase.sh`, the hub half: `mc_pool_rereview_key`,
   `mc_pool_rereview_apply` and `mc_pool_rereview_fail`. The apply writes
   the SAME job file `mc_rereview_run` writes (`mc_rr_file`), so
   `headbound_review` consumes a pool verdict as it consumes a hub one:
   `REREVIEWED` -> `done` (verdict, `out_file` = the body, `.out.model`),
   `REREVIEW_LANE_FAILED`/`_SETUP_FAILED` -> `lane-failed`,
   `REREVIEW_NOVERDICT` -> `failed`, `REREVIEW_DEFERRED` -> no file. The key
   wins over the file: `HEAD:` must start with the key's head8 and `PR:` must
   be the key's PR, or rc 1 and no file. A `done` file is never rewritten.
   The fail writes `lane-failed`, never `failed`: a dead machine costs the
   PR no strike. It reads the slug and head from the row meta (one GET).
6. `bin/fly-pool.sh`: every `RB-*` arm also takes `RR-*` (walk order, spawn
   decision, both spawn-cap records, the pool-result row read, the death
   text). The new `# >>> pool rereview reap` arm sends a `REREVIEW*` RESULT on
   an `RR-*` key to `mc_pool_rereview_apply`, stamps `COMMENTED` and closes
   the row `done` with line 1; an apply refusal leaves the row claimed with
   one alert that names the RESULT path. A `REREVIEW*` word on another key,
   or another word on an `RR-*` key, fails the row and is never read as a
   build. BUILD_DEFERRED and a machine death fail the row (never requeue it,
   no `.failed.json`, no `died N times`) and call `mc_pool_rereview_fail`.
7. `pool-actor-gate`, `pool-stall` (`skip rereview`), `pool-orphan-rows`
   (`keep rereview`), `ticket-ownership` and `docker-pool-host` (`dph_key_ok`
   refuses `RR-*`) treat the key as not a ticket. `ticket-identity` needed no
   change: it already counts only rows with no `kind` or `kind=build`.

## Left for slice C2

- The producer: `mc_rereview_spawn` on a lane-run machine with
  `mc_remote_on` puts the `RR-*` row, and the snapshot carries the job file.
- The once-per-head markers `mc_rereview_run` writes on a call-guard
  deferral (`rrnvdefer`, `rrprovdefer`, `rrguardfirst`, `rrguardspent`). The
  apply only removes the job file on `REREVIEW_DEFERRED`; C2 decides where
  those markers are written for a pool read.

## Verified by

`tests/pool-rereview-row.bh-7635-test.sh` (J1-J7, B1, RT1, Q1-Q6, P1-P9,
A1-A8, D1, RT2, C1, R1-R4).
