# BH-9629 (C1 of #9145): the bare-number lint is zero-tolerance, and screens do not call toLocaleString
Doc: console-ui/README.md

## Problem

BH-9145 C0 added the bare-number lint as a ratchet. Its `BASELINE` map held
53 sites in 24 screen files that still printed a count with no thousands
comma (`12224 rows`). `Outcomes.js` also printed its API CALLS and PEAK CACHE
READ cells with `toLocaleString()`. That call uses the browser locale, so a
German browser showed `4.823`, not the fixed en-US `4,823`.

## What changed

- The 53 sites in the 24 `BASELINE` files now wrap the count in `fmtNum(...)`
  from `console-ui/src/lib/format.js`. A partner number in the same phrase
  (`a/b`, `a of b`) is wrapped too. A plural ternary, a sort accessor and an
  attribute binding keep the raw number.
- The roadmap board `ColumnHead` formats only a number. Its loading text `…`
  stays as it is (`fmtNum('…')` would show `—`).
- `Outcomes.js` API CALLS and PEAK CACHE READ cells use `fmtNum`. Their sort
  accessors still read the raw number.
- `console-ui/tests/number-format-lint.bh-9145.test.js`: `BASELINE` is
  deleted. L1 now fails on any bare-number site in any screen file outside
  `ALLOW`. `ALLOW` (`WorldHex.js`, a cache key) and the 4 `SITE_ALLOW` lines
  stay.
- `console-ui/tests/number-format-lint.bh-9629.test.js` (new): L5 fails on
  any `.toLocaleString(` in a screen file. `toLocaleDateString` and
  `toLocaleTimeString` are not matched, because dates are out of scope.
- `console-ui/tests/number-format.bh-9629.test.js` (new) renders `HubView`,
  `WaitingView`, `OutcomesView` (under a simulated de-DE browser locale) and
  the loading `RoadmapBoardView`.

## Money

Money was done before this ticket, by `ceb02c31` (BH-9119 C0, PR #9128):
`fmtUsd` and `fmtUsdExact` group on `fmtNum`, and `fmtUsdExact(0.004)` is
`<$0.01`. `number-format.bh-9119.test.js` N1 and N5 pin it.

## Limits

The lint is line based and finds counts by shape or by name (S1 to S4). A
count in a variable with a neutral name that is never compared to 1 (for
example `${d.in_flight}`) is not seen. A new screen must still use `fmtNum`
for such a value.
