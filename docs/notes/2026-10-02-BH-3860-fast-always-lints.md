# Fast always-lints: the before number, why, and the after number we still owe (BH-3860, BH-3865)

Doc: none

## What changed

`bin/always-eject-report.sh` is new. It is a read-only operator CLI that counts
batch ejections per UTC day whose failing suites are always-suites, from the
dequeue-watch event rows (`GET /api/dequeue-watch/events`). It has no cron line
and writes nothing. Its suite is `tests/always-eject-report.bh-3865-test.sh`.

```
bin/always-eject-report.sh [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--repo example-org/cromford]
```

It prints `day dequeues by_always_suite by_fast_suite prs` as TSV. Only events
with class `rule-break` or `semantic-test` count in the two `by_` columns. rc 1
means a set or the rows could not be read, rc 3 means there are no rows in the
window, and rc 4 means the worker capped the list (500 rows), so the numbers are
partial.

The sets come from the current tree (`bin/test-impact.sh always` and
`bin/fast-lints.sh --list`). So the report answers "would today's always-set
have caught this", not "was it an always-suite on the day it failed".

## The before number

4 batch ejections by always-suites on 2026-10-01/02, hand-counted for #3860:

- [#3833](https://github.com/example-org/cromford/pull/3833), batch [#3848](https://github.com/example-org/cromford/pull/3848): `tests/gh-rest-no-subshell-lint.sh`
- [#3847](https://github.com/example-org/cromford/pull/3847), batch [#3858](https://github.com/example-org/cromford/pull/3858): `tests/gh-rest-no-subshell-lint.sh`
- [#3809](https://github.com/example-org/cromford/pull/3809), batch [#3836](https://github.com/example-org/cromford/pull/3836): `tests/gh-app-ratchet-test.sh`
- [#3852](https://github.com/example-org/cromford/pull/3852), batch [#3853](https://github.com/example-org/cromford/pull/3853): `tests/share-publish-clean.bh-795-test.sh`

The source is issue [#3860](https://github.com/example-org/cromford/issues/3860),
not this CLI. No dequeue-watch rows existed to count: the lane that writes
them is PR #3833.

## Why (from the #3860 plan, as BH-3865's plan summarizes it)

D1: the fast set runs as a step in the existing lint job, not as a new job,
because `tests/harness-ci-cost-shape-test.sh` pins the CI job set.

D3: the set is derived, not a hand list. It is `bin/test-impact.sh always`
joined with the measured durations in `catalog/ci-suite-durations.tsv`, kept at
or under `FAST_LINTS_MAX_S`. A new fast always-suite joins it with no workflow
edit.

## The after number: owed

There is no after number yet. The CLI exits 3 until the dequeue-watch lane
writes rows (PR #3833). Once it does, and a week has passed after the fast-lint
step landed, run:

```
bin/always-eject-report.sh --since 2026-10-03 --until 2026-10-09
```

Compare the `by_always_suite` total against 4 over 2 days. If it answers rc 4,
narrow the window and add the parts up.
