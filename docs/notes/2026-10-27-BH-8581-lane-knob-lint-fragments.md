# The lane-scoped knob lint allows the lane script's source fragments (BH-8581)

Doc: FLY-POOL

## What changed

- `bin/lane-scoped-knob-lint.sh` now allows `config/<lane>.d/NNNN-<name>.sh`
  (four digits, a dash, `.sh`, no subdirectory) as it allows `bin/<lane>.sh`.
- Any other path stays red: a subdirectory of `config/<lane>.d/`, a name with
  no `NNNN-` prefix, another suffix, another lane's directory, or
  `config/<lane>.d.bak/`.
- New suite `tests/lane-scoped-knob-lint.bh-8581-test.sh` pins the allowed
  fragments and the near misses.

## Why

BH-7542 split `bin/fly-pool.sh` into `config/fly-pool.d/` fragments.
`bin/fly-pool-build.sh` renders the script as the `cat` of the fragments, so a
fragment is the lane's own code. The lint did not know the fragments. It
reported 12 lines of `config/fly-pool.d/0100-head.sh`, and the nightly case C0
of `tests/lane-scoped-knob-lint.bh-7436-test.sh` was red on main.

## How to check

```bash
bash bin/lane-scoped-knob-lint.sh .
HARNESS_TEST_SANDBOX=1 bash tests/lane-scoped-knob-lint.bh-8581-test.sh
```
