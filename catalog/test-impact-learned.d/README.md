# catalog/test-impact-learned.d — learned impact-map edges

Each `*.tsv` file here is ONE edge that a merge-queue failure taught the impact
map. `bin/test-impact.sh` reads every `*.tsv` file into the map
(`ti_learned_rows`). This README is not read.

## Format

One comment line, then one data line with four tab-separated fields:

```
# bin/impact-learn.sh: <suite> failed merge-queue run <run_id> for <repo>#<pr> head <sha>; the map did not select it.
<path>	<suite>	<repo>#<pr> run <run_id>	<YYYY-MM-DD>
```

- `<path>` is a repo file, a directory that ends in `/`, or `*`. A `*` row puts
  a suite tagged `# test-impact: whole-repo` in the map's always rows.
- `<suite>` is `tests/<name>.sh` or `tests/mc/<name>.sh`.
- `<repo>#<pr> run <run_id>` is the batch the failure came from.
- The date is the `created_at` day of the `dequeue_events` row.

The map drops a row whose suite or path is not in the tree, and a line with
fewer than 2 fields. A fragment that cannot be read makes the map fail, and
`select` then names the whole corpus.

## Key

The file name is the first 16 hex characters of `sha1("<path>\t<suite>")`. The
same edge always has the same file name, so a replayed event writes nothing.

## Writer

`bin/impact-learn.sh record --event <dequeue_events row as JSON>` writes an
edge. `bin/impact-learn.sh expire --counts <tsv> --passes N` deletes the edges
that expired (see Expiry). Neither verb commits. A person can also add or widen
an edge by hand, for example a directory row.

In prod the writer is the hub lane `bin/impact-learn-lane.sh` (BH-6458). Each
hour it runs the learner in a worktree of `origin/main` for the new culprit
rows of `dequeue_events` and opens ONE PR on the branch `impact-learn/edges`
with the new fragments. It opens no second PR while that one is open.

## Expiry

An edge expires when its suite passed N times with no failure after the edge's
date (BH-6460). N is the lane knob `IMPACT_LEARN_EXPIRE_PASSES` (default 30,
0 = off).

- The counts come from the `suite_results` ledger through
  `GET /api/suite-results/passes?repo=R&since=YYYY-MM-DD`. Passes are the runs
  of `ok` rows first seen on or after `since`. Fails are every fail on a row
  written on or after `since`, in both classes (ci and builder).
- `since` is the day after the edge's date, so the failure that taught the
  edge never counts. The ledger deletes rows after 30 days, so `since` is never
  earlier than 30 days before the tick. An old edge needs N passes inside the
  last 30 days.
- A hand row (no `# bin/impact-learn.sh:` first line) never expires.
- An edge the same tick wrote or re-confirmed is kept.
- A ledger read or `expire` that fails deletes nothing.
- The lane deletes the expired files in its worktree and puts the deletions in
  its ONE PR on `impact-learn/edges`, next to any new edges. More expiries than
  `IMPACT_LEARN_MAX_EDGES` in one tick opens no PR and pages
  `impact-learn-mass-expire` once.
- An expired edge that fails again later is learned again: its file name is the
  same, and `record` writes it because it no longer exists.
