# Stale READY/WAIT_CI rows of merged or closed PRs settle; the backstop skips unchanged rows (BH-8310)

Doc: MERGE-CONDUCTOR

## The defect

`example-org/cromford#912` merged on 2026-09-18, outside the conductor. On
bh-hub-2, 2026-10-25, its `pr-state.tsv` row still read `READY` with the oldest
`since`. The closed probe (`closed_unmerged_rows`, `bin/lib/mc/settle.sh`) read
the PR as `MERGED` and wrote only a closed-watch memo `merged`. It wrote no row.
A `merged` memo takes the PR out of every later probe, so no tick touched the
row again. The */5 backstop sorts READY rows first, oldest first. With
`MC_BACKSTOP_MAX_RUNNING=1` it ran #912 on every fire, and no open PR got a
backstop run.

## What changed

- `mc_settle_offlist_rows <slug> <open-nums> <apply|dry>` (`bin/lib/mc/settle.sh`).
  `tick_project` (`bin/merge-conductor.sh`) calls it after the closed-unmerged
  pass, inside the same `MC_BUDGET_LOW != 1` guard. It moves a `READY` or
  `WAIT_CI` row whose PR is off the open list:
  - memo `merged` -> `MERGED`, reason `merged outside the conductor (closed-watch)`
  - memo `closed` -> `CLOSED`, reason `closed without merging (closed-watch)`
  It is a row-only `mc_transition`. It runs no `conductor_settle`: no issue
  close, no deploy request, no page. These PRs merged outside the conductor,
  often weeks ago, and `bin/reconcile-prs.sh` owns the issue close of merged PRs.
  A `gone` (404) memo is not moved, because a 404 can be a token scope problem.
  `QUEUED` rows keep the queue settle. Other parked states are not touched.
- In a keyed tick (`MC_ONLY_KEYS`), a key with no `merged`/`closed`/`gone` memo
  is read once through `mc_rest_pr_json` and memo'd as the closed probe memos
  it. A read that is not 200/404 stops the pass with no write and no memo. A
  full tick reads memos only and makes no new GitHub call.
- `bin/merge-conductor-backstop.sh`: each keyed run records whether it changed
  its row, in `state/merge-conductor/backstop-unchanged/<key>` (key, cksum of
  the row line, count). A run that hit the timeout counts too. A key whose last
  `MC_BACKSTOP_UNCHANGED_SKIP` runs left its row byte-identical (same head
  included) is skipped with one line:
  `<key>: its last <n> keyed runs left its row unchanged on head <sha8> — skipped until the row changes (MC_BACKSTOP_UNCHANGED_SKIP=<n>)`.
  A skipped key uses no `MC_BACKSTOP_MAX_RUNNING` slot. Any change to the row
  lifts the skip. Every fire removes the counter of a key that is no longer a
  candidate (retention).
- Knob `MC_BACKSTOP_UNCHANGED_SKIP`: row
  `lane.merge-conductor-backstop.mc_backstop_unchanged_skip`, default 3, 0 = off
  (`catalog/lanes.d/merge-conductor-backstop.knobs.d/MC_BACKSTOP_UNCHANGED_SKIP.json`).
- `bin/mc-stale-rows-sweep.sh [--apply]`: a one-time, hand-run sweep. It is a
  dry run unless `--apply`. It makes 0 GitHub calls: it reads `pr-state.tsv` and
  the closed-watch memos only, and calls `mc_settle_offlist_rows` per repo. One
  line per row: `STALE-ROW <key> <state> -> <target> memo=<word> (dry-run|applied)`,
  then `stale-rows-sweep: <n> rows, <m> merged, <c> closed (<mode>)`. rc 1 when
  the rows file cannot be read.

## Operator steps (bh-hub-2, once, after deploy)

1. Run `bin/mc-stale-rows-sweep.sh`. Read the `STALE-ROW … (dry-run)` lines and the totals line.
2. If the lines are correct, run `bin/mc-stale-rows-sweep.sh --apply`.
3. Check: `awk -F'\t' '$1=="example-org/cromford#912"{print $2}' state/merge-conductor/pr-state.tsv` prints `MERGED`.

The first full tick after the deploy moves the same rows without the sweep. The
sweep only makes it happen at once, with an audit line per row.

## Tests

- `tests/mc-backstop-stale-row.bh-8310-test.sh`: the real backstop starts the real keyed conductor (gh stubbed).
- `tests/mc-backstop-unchanged-skip.bh-8310-test.sh`: the skip, the knob, the timeout count, retention.
- `tests/mc-stale-rows-sweep.bh-8310-test.sh`: dry run, negatives, apply, idempotence, 0 GitHub calls.
- `tests/merge-conductor-closed-settle.bh-1592-test.sh` C4: TEST-CHANGE, the merged row now becomes `MERGED`.
