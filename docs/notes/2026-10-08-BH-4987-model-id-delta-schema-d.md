# 2026-10-08: model-id-delta reads schema.sql and schema.d/ as one file (BH-4987)

PR #5129 splits `worker/jobs/schema.sql` into fragments under
`worker/jobs/schema.d/`. Each of the 20 seed rows that carry a model id moves
into a new fragment file. The rules pack's `model-id-delta` check read each
moved row as an added line and reported 20 BLOCK findings. The lead-review lane
runs the box's own rules pack, which is main's copy, so the fix must land on
main before #5129.

The change is in `rp_model_id_delta` (`bin/lib/rules-pack-checks.sh`):
- A worker with a `schema.d/` in the tree or at the base is read as one logical
  file on each side. That file is the fragments in name order, or else
  `schema.sql`.
- The check compares the model-id lines of the two sides as a multiset. A row
  moved from `schema.sql` into a fragment, or between fragments, cancels out.
- A line that is new on the logical file is one finding, named on the fragment
  that holds it. This is true when `schema.sql` was re-rendered and when it was
  not.
- Every other path under `bin/`, `catalog/` and `worker/` is checked as before.

Tests: `tests/rules-pack.bh-3510-test.sh` R6c to R6g. The fixtures build their
own `schema.d/`. All five cases failed with the old check.
