# BH-9440: pool overlap scheduling, no blind ceiling release

Doc: SCHEDULER, BUILD-CONCURRENCY

## Cause

1. `bin/fly-pool.sh` `pool_after_gate` tested `POOL_AFTER_MAX_MIN` before it
   tested the blocker's state. A row held 6 hours on an OPEN blocker PR was
   released, and a machine spawned on top of that PR. On project-6, 6 of 24
   ceiling-released tickets then conflicted. `bin/sibling-serial.sh check`
   released at `SIBLING_SERIAL_MAX_MIN` in the same way.
2. `state/overlap-guard/<p>-prs.json` was written only by a launch check of
   `bin/overlap-guard.sh`. The pool never ran one on the hub, so
   sibling-serial noted `prs=unread` on every tick. The guard's PR list held
   harness PRs only.
3. A plain queued pool part never got a file list, so sibling-serial held it
   `on (no pre-plan list)`.
4. A build whose diff left its declared list never claimed the new files.

## Fix

1. Past the ceiling, a LIVE blocker (in flight, or its PR open) keeps the
   hold. One alert per blocker per UTC day names the blocker
   (`AFTER STUCK`, `SIBLING STUCK`; markers `state/pool-marks/<p>/<blocker>.after-stuck`
   and the third field of `<K>.sibling-since`). sibling-serial prints
   `SIBLING_SERIAL_HELD <K> past ceiling behind <S> (in flight|PR #n)`. The
   ceiling still releases when the PR read does not answer, and when a
   sibling is only queued.
2. `bin/overlap-guard.sh --refresh <project>` writes the snapshot with every
   open PR (any author) and its files, through the REST seam. It adds a
   `main@<sha12>` row for each non-merge commit on the default branch younger
   than `OVERLAP_MAIN_RECENT_MIN` (default 60; 0 = off). The guard judges such
   a row as an owner. File lists are cached per head sha and per commit sha.
   `bin/fly-pool.sh` calls it once per tick when rows are queued and the
   snapshot is older than `OVERLAP_PR_CACHE_SECS`. A failed read keeps the old
   snapshot and alerts once per project per UTC day.
3. `bin/fly-pool.sh` `pool_cheap_list` runs `bin/planned-files-cheap.sh` on its
   free tiers for a queued row with no list (no plans-dir, build or pre-plan
   index list), once per key per `POOL_CHEAP_LIST_TTL_S` (fly-pool knob,
   default 21600). A queue row's `.body` is handed over when present.
   sibling-serial names such a list source `cheap`.
4. `bin/lib/claim-drift.sh` runs in `bin/lib/rb/pr.sh` before the PR create.
   Diff files outside the claim are added to it (local copy, then
   `fclaim_put`, which renews the TTL), and the guard judges the union
   (`OVERLAP_CAND_FILE`). A DEFER is a `## Claim drift` note, not a stop.

## Not changed

- The planned-files store: `job_claims` (BH-2524.2) already holds the list per
  job, and `GET /api/file-claims` uses `idx_jobs_project_status_created`
  (worker/jobs/test/file-claims-explain.bh-9440.test.js).
- The recent-main read goes through the GitHub commits API, not a local
  `git log`: the pool keeps no checkout on the hub.
