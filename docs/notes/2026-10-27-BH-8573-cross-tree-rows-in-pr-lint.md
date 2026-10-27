# The console/worker cross-tree row check runs in PR lint (BH-8573)

Doc: TESTING

`tests/ci-plan-spa-worker.bh-4969-test.sh` X1/X2 fails when console-ui/ (spa) or worker/jobs/ (worker) source
reads a file outside its own tree by a quoted `../` path and `catalog/ci-batch-escalate.tsv` has no row of that
kind for it. That suite takes 11-15 s and runs only in the merge-queue batch. Four batches went red on it in one
night (#8523, #8534, #8564, #8566).

`tests/cross-tree-rows.bh-8573-test.sh` makes the same decision in one pass: one `git ls-files`, one grep, awk
for the path, and `cbe_affects` (`bin/lib/ci-batch-escalate.sh`) in-process. It runs in about 0.7 s. Its
unscoped `git -C "$DIR" ls-files` puts it in the derived always set of `bin/test-impact.sh`, so:

- `bin/fast-lints.sh` runs it in the PR `lint` job and in `bin/prepush-gate.sh`;
- `bin/test-impact-gate.sh` runs it on every builder diff (always tier);
- the merge-queue batch still runs it.

No list, workflow or knob changes. bh-4969 does not change and still runs its own X1/X2.

## A miss

A miss prints a FAIL line and then the row to paste into `catalog/ci-batch-escalate.tsv`, tab-separated:

```
FAIL: X2: worker/jobs/test/a.test.js reads tests/fixtures/x.json with no worker row; add to catalog/ci-batch-escalate.tsv (replace <TICKET> with the ticket key):
tests/fixtures/x.json	worker	worker/jobs/test/a.test.js reads tests/fixtures/x.json (<TICKET>)
```

The pattern is the target for a file, `<target>/` for a directory or a literal that ends in `/`, and
`<target>*` for a literal cut at a `${` template. Replace `<TICKET>` with the ticket key.
