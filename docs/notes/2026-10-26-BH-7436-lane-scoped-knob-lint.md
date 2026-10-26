# POOL_GH_READ_TIMEOUT_S stays a fly-pool knob: the lane-scoped knob lint (BH-7436)

Doc: FLY-POOL

Follow-ups from the BH-7421 re-review (#7435).

## What changed

- **The `pool_rest_read` comment is true.** `bin/fly-pool.sh` said a read cut at
  `POOL_GH_READ_TIMEOUT_S` answers with an empty code. Since BH-7421 it prints
  `TIMEOUT` as line 1. The header and the body comment now say that. No code changed.
- **The knob note is true.** `catalog/lanes.d/fly-pool.knobs.d/POOL_GH_READ_TIMEOUT_S.json`
  said "A cut read answers with no HTTP code". It now says the code is `TIMEOUT`, and
  that the knob is lane-scoped.
- **New lint: `bin/lane-scoped-knob-lint.sh`.** It is red (rc 1) when
  `POOL_GH_READ_TIMEOUT_S` is named in a tracked file outside fly-pool's own script
  and registry entry: an env template, a cron line, another lane's or a lib's knob
  entry, or another `bin/` script on a line that is not a comment.
  `bin/lib/hold.sh` may read the knob; it is red there only on an assignment or export.
  `tests/`, `docs/`, `.harness/specs/` and `*.md` are not read.
  `--env-file <path>` also checks a box file such as `$HARNESS/env/global.env`.

## Why

`bin/lib/hold.sh` `hold__gh` cuts a hold read when the knob is a positive number.
Some `hold_check` callers outside the pool proceed on an unreadable hold. A global
value can let a cut read skip a hold in those lanes.

## How to run

```bash
bin/lane-scoped-knob-lint.sh .                                   # the checkout
bin/lane-scoped-knob-lint.sh --env-file /root/harness/env/global.env .   # plus a box file
```

rc 0 clean, rc 1 findings (one per stdout line), rc 2 bad args, not a git work tree,
or an unreadable `--env-file`.

## Not wired

The lint is not a rules-pack row: `catalog/rules-pack.tsv` is a shared list. Its suite,
`tests/lane-scoped-knob-lint.bh-7436-test.sh`, runs the lint on the checkout, so the
merge-queue corpus is red when the knob leaks into a tracked file.

Not in this change (ticket items marked optional): `timeout -k 5` in `pool_rest_read`,
and a rotated start row for the pool's row walk.
