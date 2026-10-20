# BH-7616: repair-on-push reads each PR's file list once per tick

Doc: OPERATING

Slice C3 of #7616 (the rest of #7397). C0 (#7641) built the load shed. C1 and
C2 (#7681) moved pipeline-health to one open-PR list per repo per tick.

## What changed

`bin/repair-on-push.sh` runs every minute on the hub. One tick reads up to
`REPAIR_PUSH_WAKES` push wakes (default 20). For each wake it walks every open
harness PR of the repo. For a PR with no local `changed-files.txt`, it read
`GET repos/<slug>/pulls/<n>/files` again on each wake. So one tick made W x N
files reads.

Now the lane keeps a memo of each PR's sorted file list in the tick's own temp
dir, at `$TMP/prfiles.memo.<project>.<pr>`. The first wake of the tick reads
the list from GitHub. Every later wake of the same tick reads the memo. The
memo is removed with the temp dir when the tick exits. It is not kept across
ticks, so it is as fresh as the once-per-tick PR list beside it.

## Why

On an overloaded hub the ticks run long. The flock dedupe skips the ticks
between, and the push wakes stack up. The next tick then made W x N files
reads with W up to 20, and that made the overload worse (the loop #7397
describes).

## What stays live

- `changed-files.txt` of the build of record is still the first source. It is
  a local file read and is not memoized.
- The PR facts read (`GET repos/<slug>/pulls/<n>`) stays one read per wake. Its
  head is the lease `mc_rebase` takes, and another lane can move it inside a
  tick.
- The `compare/<push after>...<pr head>` read stays per wake. Each wake has its
  own push sha.
- A failed files read writes no memo. The lane logs `skip files-unreadable`,
  the cursor stays below the wake, and the tick stops, as before.
- An empty file list is memoized empty. The PR is `no-overlap` on every wake,
  as before.

The memo key has the project and the PR number. fleet.conf maps one project
to one repo slug, so two repos with the same PR number get two memos.

## The tick line

The summary line in `logs/repair-on-push.log` has two new fields after
`cursor=`:

    tick wakes=<n> rebased=<n> budget=<n> cursor=<id> files_get=<n> files_memo=<n> (...)

- `files_get`: GitHub PR files reads made in this tick.
- `files_memo`: answers from this tick's memo. Before this change, each one was
  one more `files_get`.

No reader parses this line. `bin/dora_conflicts.py` and `bin/dora-digest.sh`
read the `REPAIR`, `range=` and `left for next tick` lines, which do not change.

## Before and after

From `tests/repair-on-push-files-memo.bh-7616-test.sh`. "Before" is the same
suite with the memo branch disabled (`if false`), the mutation run of this
build.

| run (fixture) | files reads before | after |
|---|---|---|
| 3 wakes, 2 PRs (M1) | 6 (`files_get=6 files_memo=0`) | 2 (`files_get=2 files_memo=4`) |
| 2 wakes, 1 gh PR + 1 changed-files PR (M3) | 2 | 1 |
| worst case, 20 wakes, N PRs | 20 x N | N |

These numbers come from a fixture. The hub numbers come from
`grep 'tick wakes=' /root/harness/logs/repair-on-push.log` on the hub after the
merge: a tick with 2 or more wakes shows `files_memo` above 0.

## Left of #7616 after this slice

- Per-PR reads in pipeline-health: the staledequeue `pulls/<n>` head and the
  leadunqueued `commits/<sha>/status`. The lane ticks every 10 minutes, so a
  cross-tick cache there needs a TTL over 600 s and delays the page. It needs
  its own decision.
- Per-PR reads in `bin/blocked-resolver.sh`.
- Move pool scheduling off the hub: BH-7516, BH-7636, and the BH-6896 slices
  (#7556, #7572). The batch half is on main (`pool_pr_bulk_read`).
- The hub measurements (load p90 at or below the cap, 0 WINDOW_DEFERRED):
  `bin/hub-load-report.sh` on the hub after merge.
