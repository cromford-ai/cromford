# The builder gate runs the whole-repo suites on HEAD merged with fresh main, and ranks a learned edge above closure (BH-6459, slice C2 of BH-6390)

Doc: TESTING

## Why

A whole-repo ratchet (a line ceiling, a registry count, a generated-file
check) can be green on HEAD and green on main, and red on the merge of the
two. The builder gate (`bin/test-impact-gate.sh`) ran every suite on HEAD
only. So the first run on the merge was the merge-queue batch, and the batch
ejected the PR.

Slice C0 (BH-6390) added learned path edges (`catalog/test-impact-learned.d/`).
`select --why` printed those picks as `closure`, so the gate ranked them with
the weakest kind.

## What changed

- `bin/test-impact.sh select --why` prints the kind `learned` for a pick that
  comes from a learned path edge and that the suite text does not name. A
  learned `*` row stays `always`. With `--map <file>` the selector reads the
  learned rows itself, so the label does not change.
- The gate ranks `self > reads > always > named > source > learned > closure`.
- `bin/test-impact-gate.sh --fresh-main on|off` (env
  `TEST_IMPACT_GATE_FRESH_MAIN`, default off) and `--fresh-ref <ref>`. When
  on, the gate fetches origin's default branch into
  `refs/harness/fresh-main-<pid>` (deleted after the fetch and in the EXIT
  trap; `refs/remotes/origin/*` never moves), merges it onto HEAD with
  `git merge-tree --write-tree`, snapshots that tree, and runs the run list's
  `always` suites there. They move from HEAD to the merge. They do not run
  twice.
- Run order: segment A on HEAD (fast and nightly tiers, self and reads), then
  the fresh list on the merge, then the rest on HEAD. One budget covers all
  three, and the fetch, merge and snapshot time comes out of it.
- Suite reuse never sees a fresh suite.
- `bin/lib/rb/gates.sh` passes the `fly-pool` knob
  `TEST_IMPACT_GATE_FRESH_MAIN` (default 1) to the gate as an env value. The
  argv does not change. The fetch is bounded by
  `TEST_IMPACT_GATE_FRESH_FETCH_S` (default 60 s).

## What to look for

- `impact-gate: fresh main <sha12>: ran X of M whole-repo suite(s) on HEAD
  merged with it: passed|FAILED (rc 1)|NOT RUN (none started)`.
- `impact-gate: fresh-main: off (<why>)`. The reasons: `runner plan`,
  `runner remote`, `no origin remote`, `cannot resolve <ref>`,
  `fetch of origin <br> failed (rc N)`, `head already contains main <sha12>`,
  `head conflicts with main <sha12>`, `merge-tree failed (rc N)`,
  `could not snapshot the merged tree`, and
  `no always or whole-repo suite in the run list`. An off pass runs the gate as
  it ran before.
- `--table`: the fresh rows carry `(fresh main <sha8>)`. The second line says
  `Ran on HEAD merged with main <sha8>: M.` or `Fresh main: off (<why>).`

## Stacked on PR #6349 (BH-6335)

This branch merges `ticket/bh-6335`, because #6349 was still open at
2026-10-13 and the plan says to stack on it. The fresh pass combines with it:

- The `--also` rows run in segment A, on HEAD, before the fresh list. An
  `--also` suite that is also an `always` suite runs on the merge, and its row
  keeps the `learned (failed merge-queue batches)` reason first (X1, X2).
- `--runner traced` runs all three segments through `RUN_LOOP` with the hits
  file as the 6th argument (`traced_seg`). A trace hit in the fresh segment is
  named in `--trace-hits` (TR1, TR2).

## Not in this slice

- C1 (the hub lane that writes learned fragments) and C3 (edge expiry).

Test: `tests/test-impact-gate-fresh-main.bh-6459-test.sh`.
