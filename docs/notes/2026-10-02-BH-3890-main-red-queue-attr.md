# Merge-queue batch attribution (BH-3890, part 3 of BH-3886)

Doc: MERGE-CONDUCTOR

## What changed

`bin/lib/main-red-queue-attr.sh` is new. It defines `mrqa_attr`, the hook
BH-3888 wired into `bin/main-red-detector.sh`'s merge-queue arm. The detector
is not edited. Before this lib, every red merge-queue batch counted toward the
`reason=queue` freeze. Now a batch whose own diff broke it is left out.

`mrqa_attr <owner/repo> <run-id> <pr...>` sets `MRQA_VERDICT` to `own`,
`untouched` or `unreadable`, plus `MRQA_PR` and `MRQA_WHY`.

- It reads `gh run view <id> --log-failed`. The log is bounded at
  `FLAKY_LOG_MAX` bytes (default 2000000, the same default as
  `bin/lib/flaky.sh`).
- It keeps only failure lines: `--- tests/<x> rc=<non-zero>`, `FAIL:`,
  `not ok`, `Error`, `ERR_`, `raw gh call`. From those it takes repo path tokens
  ending in `.sh .js .mjs .ts .py .json .yml .yaml .sql .md`, with any `:<line>`
  removed. A token is a whole run of path characters, so
  `tests/foo-test.sh.bak` is never read as `tests/foo-test.sh`.
- It reads each batch PR's files with
  `gh api repos/<slug>/pulls/<n>/files --paginate -q '.[].filename'`.
- `own` means a failure-line path is exactly a file one of those PRs changes.
  The detector logs `queue batch <id> (#a + #b) red on <sha8> attributed to
  #<n>, not counted toward main-red — <failure line> (#<n> changes <path>)`
  and walks the page again without it.

## Fail direction

Only `own` removes a count. A failed or empty log read, a log over the cap, or
one PR's file list that cannot be read (or comes back empty) is `unreadable`.
That logs `<slug>: queue batch <id> attribution unreadable (<why>) — it stays
counted`, and the batch counts exactly as `untouched` does.

## Cache

Verdicts go to the ledger through `job_ledger_put`: kind `main_red_qattr`, key
`<owner>/<repo>#<run-id>`, value `own pr=<n> path=<p>` or `untouched`. A
completed run never changes, so a row is final. The next tick, and the
BH-1927 confirming re-read in the same tick, answer from the row with no
GitHub read. `unreadable` is never written. A ledger that cannot be read means
the batch is read again. `--explain` writes nothing.

## Turning it off

Set the settings row `lib.main-red-detector.main_red_queue_attr` to `0` (or env
`MAIN_RED_QUEUE_ATTR=0`). The detector then never calls `mrqa_attr`.

## Evidence

`tests/main-red-queue-attr.bh-3886-test.sh` drives the real detector on the
2026-10-02 incident pages with the real failed logs and PR file lists in
`tests/fixtures/bh-3886/attr/`, all fetched with `gh`. Batch 36969794399
(#3882 + #3855 + #3881) failed on `bin/lib/mc-foreign-red.sh`, which #3881
changes. It is attributed to #3881, two red batches are left, and the repo is
not frozen. The ratchet exemption is
`tests/gh-app-ratchet-by-design/lib/main-red-queue-attr.sh.txt`.
