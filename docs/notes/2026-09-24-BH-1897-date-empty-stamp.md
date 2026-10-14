# date-empty-stamp: an empty `date -d` argument is today's midnight

Doc: TEST-DETERMINISM

## What changed

BH-1897 (slice 0 of BH-1816, from #1815). `bin/test-determinism-lint.sh` has a
new rule, `date-empty-stamp`, at `warn`. It finds `date -d "$VAR"` (also
`"${VAR}"` and `"${1:-}"`) in `bin/**.sh` where no `[ -n "$VAR" ]` or
`[ -z "$VAR" ]` test sits on the call line or on a non-comment line within
`date_guard_lookback` (6) lines above it. Every `date` on a line is judged on
its own, so `DUR=$(( $(date -d "$END" …) - $(date -d "$START" …) ))` reports
when either variable is unguarded. `[ -d "$dir" ]` beside a date call is never
read as a date argument.

## Why

GNU `date -u -d ""` exits 0 and prints today's 00:00:00Z. So
`e=$(date -u -d "$x" +%s) || e=0` never takes the fallback when `$x` is empty,
and the lane carries on with an epoch nobody wrote.

## Conf and waivers

`catalog/determinism-lint.conf` carries the `rule`, a
`scope date-empty-stamp (^|/)bin/.*\.sh$` line and `opt date_guard_lookback 6`.
The rule is bin/-only and skips test files too, and its name doesn't start with
`clock-`, so a `NOW=` pin doesn't exempt a file. A site that is safe for a
reason the guard scan can't see takes a trailing waiver:

    e=$(date -u -d "$x" +%s) || e=0  # determinism: ok date-empty-stamp <why>

A waiver with no reason is a `waiver-no-reason` finding (error).

## Severity

`warn`: the repo run prints the existing bin/ sites under "determinism
warnings" and still exits 0. This slice guards or waives none of them. Sibling
slices of BH-1816 are planned to do that, and a later slice to flip the rule to `error`.
Suite: `tests/test-determinism-lint.bh-1897-test.sh`.
