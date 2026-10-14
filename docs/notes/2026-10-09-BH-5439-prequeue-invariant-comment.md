# An invariant red posts its evidence on the PR (BH-5439)

Doc: MERGE-CONDUCTOR

## What changed

- `pq_read_run <slug> <title> [<path>]` in `bin/lib/mc-prequeue.d/dispatch.sh`
  also reads the `prequeue-invariant-timing`, `-fail` and `-slow` annotations.
  `pq_settle` passes its cache path. Given a parsed verdict, three sidecars go
  next to the cache entry, each written tmp + mv:
  - `<path>.why`: the why of a red (`invariant:<ids>`).
  - `<path>.fail`: one `### <id>` block per fail message, then its FAIL lines.
  - `<path>.timing`: the timing line, then each slow line.
  A timing sidecar also logs one line:
  `<slug>#<n> PREQUEUE_INVARIANTS head <h8> main <m12>: <timing>`.
  The two other callers (`batch-solo.sh`, `archie-fm-queue/culprit.sh`) pass
  no path and write nothing.
- The conductor's pre-queue red arm reads `$PQ_PATH.why`. For `invariant:<ids>`
  the park reason is
  `prequeue-red: <suites> on main <m12> — invariant:<ids>: the head merged onto current main fails them`.
  Every other red keeps the reason it had.
- Inside the `pqred KEY HEAD MAIN` attempt row, an invariant red with a
  non-empty `.fail` calls `pq_red_comment` (new
  `bin/lib/mc-prequeue.d/red-comment.sh`). It posts ONE PR comment with each
  id, its suite from the hub's `catalog/prequeue-invariants.tsv`, the FAIL
  lines in a text fence, a repro command and the marker
  `<!-- prequeue-invariant:<head>:<main> -->`. An id with no catalog row is
  named as missing and gets no repro line. A refused POST (rc 75 included) is
  one log line with the rc. The attempt row is written first, so there is no
  retry. An empty `.fail` is one log line and no comment. The park happens in
  every case.
- `br_prequeue_brief` in `bin/blocked-resolver.sh` adds one sentence for an
  invariant park. It names the catalog and the PR comment.
- `pq_prune` ages the sidecars out with their entry. The 40-hex sibling loops
  in `pq_resolve` skip them.

Tests: `tests/mc/prequeue-invariants-conductor.bh-5429-test.sh` (K1-K5).
