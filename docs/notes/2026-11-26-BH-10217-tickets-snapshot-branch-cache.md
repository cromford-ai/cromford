# BH-10217: tickets-snapshot-push keeps its branch answers

Refs #9926 (second round).

## Before

On the hub, 2026-11-26 10:00Z-10:33Z, the lane made 190 GitHub GETs: about 345
spent GETs per hour. 86 were `commits/<sha>`, 94 were
`pulls?state=closed&head=<owner>:<ref>`, 10 were `git/matching-refs/heads/`.
A branch-only ticket (an in_progress or review ticket with no open PR) cost 2
reads every 10 minutes, and the answers did not change.

## What changed

1. Commit cache: `state/tickets-snapshot/branch-commits.tsv`, rows
   `repo sha {actor,at} epoch`. A commit's author and date never change for a
   sha, so a sha seen before costs 0 reads.
2. "No merged PR" cache: `state/tickets-snapshot/not-merged.tsv`, rows
   `repo ref sha fingerprint epoch`, 1 row per (repo, ref). A row stays valid
   while ALL hold: the tip sha is the same; the fingerprint is the same; the
   row is younger than `TICKETS_SNAPSHOT_NOT_MERGED_MAX_AGE_S` (default
   21600 s). The fingerprint is the sorted `<number>:<state>` list of the PR
   record's closed and merged rows for that exact head ref (`-` for none). The
   lane reads it with 1 jobs GET per repo per tick:
   `GET /api/pr-record-refs?repo=<r>&refs=<JSON array>`. A new closed or merged
   record row for the ref ends the row, and the lane then reads GitHub 1 time.
3. `git/matching-refs/heads/` is read only when 1 or more in_progress/review
   tickets of the project have no open-PR claim. The open-PR list is enough
   for the rest. The branch-only fallback is the only caller that needs the
   full ref list; the retention prune below uses the same read.
4. Retention: on a tick that read a non-empty branch list, the rows of a branch
   that is gone (or whose tip moved) leave both files. All three answer files
   keep the age prune of `TICKETS_SNAPSHOT_MERGED_KEEP_DAYS`.

Unknown is never "no change". A failed, refused (404, 400 `too_many`, 503),
truncated or malformed record read, or a failed GitHub read, writes no row,
and the lane reads GitHub as before. `TICKETS_SNAPSHOT_BRANCH_CACHE=0` turns
the two caches off (no reads, no writes, no record read).

## Why local files

The lane runs on the hub only. A lost file costs 1 GitHub read per branch,
never a wrong claim. The validity check of the "no merged PR" answer reads the
PR record in D1; the answer itself stays local.

## After

The acceptance suite measures the per-branch reads: 20 branch-only tickets make
40 reads in tick 1 and 0 in ticks 2 and 3. The hub figure is owed 24 h after
merge and deploy: `bin/gh-ledger-report.sh --per-merged-pr --by-repo --last 24h`.

## Tests

- `tests/tickets-snapshot-branch-cache.bh-10217-test.sh` (the lane, a stub gh,
  a stub jobs client, a fixture clock).
- `worker/jobs/test/pr-record-refs.bh-10217.test.js` (the route on node:sqlite,
  EXPLAIN at 20,000 rows uses `idx_pr_records_repo_head`).
