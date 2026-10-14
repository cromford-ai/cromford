# race-wall-bound: a test asserts the order of events, not elapsed seconds

Doc: TEST-DETERMINISM

## What changed (BH-6508)

- `tests/stuck-work-dispatch.bh-5943-test.sh` AT-1a no longer checks that
  `stuck-work.sh --dispatch` returns "within 5 s". The `alert-line.sh` stub
  writes `$T/p1-page-returned` when p1's blocked page returns. AT-1a reads that
  marker right after the dispatch exits and requires it to be absent. A
  dispatch that waits on its runs cannot exit before p1's page returns, so it
  goes red. A slow but detached dispatch stays green.
- `catalog/determinism-lint.conf` has a new rule, `race-wall-bound` (warn, sh).
  It matches a `SECONDS=0` reset and an `X=$((SECONDS - t0))` or
  `EPOCHSECONDS` elapsed capture. It does not match a start capture
  (`s0=$SECONDS`), a deadline (`END=$((SECONDS + 11))`) or a deadline loop.

## Why

On 2026-10-13, at gate load 50-120, AT-1a went red on #6482 (19 s), #6475 (7 s)
and #6496 (7 s). None of these PRs touched stuck-work. Each passed 58/0 alone.

## Why warn, not error

At this commit the rule matches 18 lines in 12 other suites. At `error` the
CI lint step goes red on every PR until all 12 change. A later ticket can fix
them and raise the rule with the settings row
`conf.determinism-lint.rule.race-wall-bound` or a conf edit. A hang-only
ceiling can stay with a line waiver:
`# determinism: ok race-wall-bound <why>`.

Tests: `tests/test-determinism-lint.bh-6508-test.sh`,
`tests/stuck-work-dispatch.bh-5943-test.sh`.
