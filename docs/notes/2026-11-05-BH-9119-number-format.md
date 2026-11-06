# Console numbers have a comma separator (BH-9119, slice C0)

Doc: CONSOLE

## What changed

Mission Control printed numbers with no grouping: `$12224.73`, `4823`.
the operator asked on 2026-11-05 for `12,224.73`. Slice C0 adds one formatter and
moves the shared helpers and display components to it.

- `console-ui/src/lib/format.js` has `fmtNum(n, { decimals })`. It uses
  `Intl.NumberFormat('en-US')` with grouping, so the browser locale has no
  effect. With no `decimals` it uses the Intl default (up to 3 fraction
  digits, no padding). `null`, `undefined`, `''`, a boolean, `NaN` and
  `Infinity` read `—`. A numeric string formats. A rounded zero shows no
  minus sign.
- `fmtUsd(n, { decimals = 2 })`, `fmtUsdExact`, `usdBasis`, `countOrNull` and
  the `M` branch of `fmtTokens` use `fmtNum`. A negative reads `-$5.00`
  (it was `$-5.00` from `fmtUsd`). `fmtUsdExact` keeps `<$0.01`.
- `Stat`, `StatGrid` and `SortableTable` group a value only when it is a
  `number`. A string or a vnode (`#9118`, a date, `—`) shows as given.
  `SortableTable` still sorts on the raw value. A column with `plain: true`
  shows its number as is, for an id column. No column sets it yet.
- Every `toFixed(` and literal `$${` in `console-ui/src/screens/**` moved to
  `fmtNum` or `fmtUsd`.

## The lint

`console-ui/tests/number-format-lint.bh-9119.test.js` fails on a `toFixed(`
or a literal `$${` in `console-ui/src/screens/**`. The allowlist has one
entry: `WorldHex.js`, whose `toFixed` calls build SVG coordinates that a
person does not read. The suite also fails if an allowlist entry no longer
matches anything.

## Left for slice C1

Inline prose counts in screens (`${stops.total} stops`,
`${rows.length} of ${total}`) are not grouped yet, and the lint does not yet
catch a bare number interpolation. Lib helpers whose output stays below 1,000
(percents, ratios, contrast) keep their `toFixed`.
