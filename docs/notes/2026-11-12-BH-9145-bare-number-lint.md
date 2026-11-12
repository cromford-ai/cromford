# BH-9145 slice C0: counts in screen prose go through fmtNum, and a lint stops new bare ones
Doc: console-ui/README.md

SLICE: C0 of #9145.

## Problem

BH-9119 C0 moved money, `toFixed(` sites, `Stat`, `StatGrid` and number cells
in `SortableTable` to the shared formatter in `console-ui/src/lib/format.js`.
Counts in screen prose did not move. `${rows.length} rows` printed `12224 rows`,
not `12,224 rows`, and no lint stopped a new one.

## What changed

- `console-ui/tests/number-format-lint.bh-9145.test.js` (new) scans every
  `console-ui/src/screens/**/*.js` line. Plain JS has no types, so the lint
  flags 4 shapes of `${...}` that are numbers by construction or by name:
  - S1 `${<path>.length}` or `${<path>.size}`. A call chain is fine. An
    arithmetic operator at the top level is not, so `${100 / STEPS.length}`
    (geometry) does not count.
  - S2 `${Math.round(`, `floor`, `ceil`, `trunc`.
  - S3 `${<path>}` when the same line compares that path to 1 (the plural
    pattern `x === 1 ? 'item' : 'items'`).
  - S4 `${<path>}` whose last segment is `total` or `count`, or ends in
    `Total` or `Count`.
  - A `${` directly after `=` is an htm attribute or prop binding. It never
    counts.
- 26 screen files now wrap each flagged count in `fmtNum(...)`. A plural
  ternary keeps the raw number. Sort keys and attributes are not changed.
  Where a flagged count sits next to an unflagged partner (`${a}/${b}`,
  `${a} of ${b}`), the partner is wrapped too, so one phrase never mixes
  `1234` and `1,500`.
- `console-ui/tests/number-format.bh-9145.test.js` (new) renders
  `ComponentsView` and `BuildOrderView` with 1,234 and 12,224 rows and with 1.

## The ratchet

The lint is a ratchet in C0. `BASELINE` holds a count for each of the 24 files
C1 converts. A file fails when its count goes up. A count that goes down does
not fail. A file not in `BASELINE` must have 0.

## Exceptions

- `ALLOW` (whole file): `WorldHex.js`, a cache key, not text a person reads.
- `SITE_ALLOW` (one line, keyed by file and a slice of the line), each a
  value the scanner flags that is not a count:
  - `FlyIdlePanel.js` `${r.size}`: a Fly machine size name.
  - `PR.js` `${total}` in `buildCost`: a preformatted `$` cost string.
  - `Ideas.js` `${mockupCount}`: `mockupCountText()` prose.
  - `Outcomes.js` `width:${Math.round(...)}%`: a CSS meter width.
- L2 fails when an `ALLOW` or `SITE_ALLOW` entry no longer matches a flagged
  line, so a stale exception cannot stay.

## Limits

- The scan is line based. A `${...}` that spans lines is not seen.
- A count with a name outside the 4 shapes is not seen.

## C1

C1 of #9145 converts the 53 sites in the 24 `BASELINE` files and deletes
`BASELINE`. The lint is then zero tolerance.
