Closes #9001

Fixture PR for tests/review-tier-medium.bh-6967-test.sh (M5). It is not a real change.

## What

`bin/a.sh` prints a greeting with the name it is given.

## Files to touch

- `bin/a.sh`

## Acceptance tests

- `tests/a.fixture-test.sh` A1: `bin/a.sh fixture` prints `hello fixture`.

## Verify

- `bash tests/a.fixture-test.sh` red before the change (exit 1), green after it (exit 0).

Lane: fly-pool (fixture)
