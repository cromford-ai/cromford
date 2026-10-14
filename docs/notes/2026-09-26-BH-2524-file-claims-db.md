# Fleet file claims: the two overlap readers read job_claims (BH-2524, BH-2630)

Doc: DB-COORDINATION-SPEC, BUILD-CONCURRENCY

## Why

Build claims and overlap-defer are box-local (`state/claims/<project>/`,
`state/overlap-defer/<project>/`). Two boxes planning the same files could not
see each other, so they found out at merge time. BH-2524 adds the build's
`job_claims` row as a fleet source NEXT TO the box-local files. It never
replaces them, and a worker outage degrades to what each box did before.

## The split

- **BH-2627 (contract, merged into this branch's base).** Four nullable TEXT
  columns on `job_claims`: `planned_files`, `files_claimed_at`,
  `files_expires_at`, `overlap_not_before`. Constants in
  `worker/jobs/src/lib/core.js`: `FILE_CLAIM_TTL_MIN_S=60`,
  `FILE_CLAIM_TTL_MAX_S=86400`, `OVERLAP_NB_MAX_S=86400`,
  `FILE_CLAIM_LIST_MAX=200`. Knob `FILE_CLAIM_TTL_S` (default 14400) on lib
  `file-claims`. `bin/lib/file-claims.sh` defines `fclaim_put`,
  `fclaim_not_before_put`, `fclaim_list_dir` and `fclaim_not_before_left`
  (named `fc_*` until BH-2627's rename, commit 8d94fb255).
- **BH-2628 (routes + the fclaim_* bodies) and BH-2629 (the build publishes its
  row).** Both deployed: `GET /api/file-claims?project=cromford` returned
  15 live rows on 2026-10-07. The readers below still called the pre-rename
  `fc_list_dir`, so no box read them until BH-5002
  (`2026-10-07-BH-5002-claims-cross-box.md`).
- **BH-2630 (this change): the readers.**

## The readers

`fclaim_list_dir <project> <dir>` returning 0 is an answer: `<dir>/<KEY>` holds
each claiming key's file list (the caller's own key included) and
`<dir>/.claimed_at` is `KEY<TAB>files_claimed_at`. Any other return, a missing
lib or a missing function is NO answer. It is never read as "nobody claims".

- **`bin/plan-overlap.sh`, source 4.** Asked before the local sources and,
  since BH-5002, read INSTEAD of the local claim files when it answers. Judged
  after the local build dirs (source 2) and before the UNJUDGED report. Each key not
  already seen is added to SEEN and checked with the same `overlap` rule. A hit
  defers this build (`OVERLAP_DEFER <KEY> vs <KEY2> files=[...]`, exit 1)
  only when the other claim came first:
  - this build has no row of its own in `.claimed_at`, or
  - the other row's `files_claimed_at` sorts before ours (`LC_ALL=C` string
    compare, which is time order for one fixed ISO-8601 UTC format; an empty
    timestamp sorts first and blocks), or
  - the timestamps are equal and the other key sorts first (byte order).

  So the later claimer defers and the first one builds. Keys answered here are
  no longer reported `OVERLAP_UNJUDGED`. The local sources keep their symmetric
  rule. The kill flags (`OVERLAP_SCHED=0`, `flags/plan-overlap-off`) still exit
  0 before any read. `FILE_CLAIMS_INCOMPLETE` on stderr is passed through to the
  build's `pipeline.log`.
- **`bin/overlap-schedule.sh`, source 2b.** Between the local build dirs and the
  ledger's claimed rows. Each key not already seen or in flight becomes
  INFLIGHT, and its list is emitted, so a candidate that collides with another
  box's running build is `HELD`. There is no tie-break here: it is advice about
  what to launch next. A key answered here is not reported `OVERLAP_UNJUDGED`
  by source 3.

Rows are not filtered through the queue ledger or the build-key flock. A row's
liveness (`status`, `files_expires_at`) is the worker's to decide.

## Outage

`fclaim_list_dir` rc != 0: nothing is read from it, the local claim files
(`state/claims/<project>`) are read as before, one `FILE_CLAIMS_FALLBACK` line
goes to `logs/file-claims-fallback.log` (BH-5002), and the UNJUDGED report
still names every ledger-claimed key this box has no list for. Pinned by
`tests/file-claims-readers.bh-2524-test.sh` cases 8, 9, 11, 12 and
`tests/claims-cross-box.bh-5002-test.sh` C6-C7.
