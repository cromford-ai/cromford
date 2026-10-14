# Cross-box claims read from the DB (BH-5002, BH-4951.3)

Doc: DB-COORDINATION-SPEC, BUILD-CONCURRENCY

## The bug

BH-2630 wired `bin/plan-overlap.sh` (source 4) and `bin/overlap-schedule.sh`
(source 2b) to read every box's `job_claims` row through `fc_list_dir`. BH-2627
renamed the lib's functions to `fclaim_*` (commit 8d94fb255), and both readers
kept the old name behind `command -v fc_list_dir`. That guard was always false,
so no box ever read a fleet claim. The writer side worked: on 2026-10-07
`GET /api/file-claims?project=cromford` returned 15 live rows, Fly pool
builds among them. A Fly build's claim on a file never deferred a watcher-box
plan on the same file.

`tests/file-claims-readers.bh-2524-test.sh` stayed green because its fake lib
defined `fc_list_dir` too. It now defines `fclaim_list_dir`, and the new
`tests/claims-cross-box.bh-5002-test.sh` drives the REAL lib with only
`_jobs_req` stubbed.

## DB first

Each reader calls `fclaim_list_dir <project> <tmpdir>` once, before reading
any claim file.

- **rc 0** (the worker answered with the contract, `truncated:true` included):
  `job_claims` is the claims source. `state/claims/<project>/*` is NOT read, so
  a claim the worker no longer lists (job not `running`, or past
  `files_expires_at`) stops deferring even when its local file lingers. This
  box's live build dirs (`builds/<project>-*`, no RESULT, 4h mtime) are still
  read, which covers a local build whose `fclaim_put` failed. plan-overlap's
  first-claimer tie-break is unchanged.
- **rc != 0** (no lib, no `_jobs_req`, no JOBS_URL, outage, a 200 that is not
  the contract): `state/claims/<project>` is read exactly as before, and one line
  is appended to `logs/file-claims-fallback.log`:

  ```
  <UTC iso> FILE_CLAIMS_FALLBACK <project> <plan-overlap|overlap-schedule>: job_claims unreadable, read state/claims/<project>
  ```

  The line goes to that file only. Stderr is unchanged (overlap-schedule's is
  stamped into the project log, and `tests/overlap-claim-ttl.bh-3943-test.sh`
  pins it). A missing `logs/` dir never changes a verdict.

The kill switches (`OVERLAP_SCHED`, `OVERLAP_SCHEDULE`, `switch.plan-overlap-off`)
still exit before any read, so they make no GET and write no line.

## How wave 6 counts it

`state/claims` is still written (`bin/lib/rb/plan.sh`) and still the fallback.
Wave 6 (#5005) removes it only after a week in which
`wc -l logs/file-claims-fallback.log` stays 0 on every box, which proves the DB
answered every decision.
