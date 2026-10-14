# Mission Control phone floor: 44px tap targets and 11px text (BH-6001)

Doc: console-ui

## What changed

- New stylesheet `console-ui/src/phone-floor.css`, imported by
  `console-ui/src/main.js` right after `styles.css`. It is one
  `@media (max-width: 600px)` block. Nothing in it applies above 600px.
- Type: `--fs-3xs` becomes `var(--fs-2xs)` (11px) under 600px. It was 9px, and
  only the bottom-nav label on a <=420px phone read it. Every other step was
  already 11px or more. Body (`--fs-lg`) stays 15px. The desktop `:root` still
  says 9px.
- Hit area: every `a`, `button`, `summary`, `[role=button]` and
  checkbox/radio `label` gets `position: relative` (zero specificity) and an
  empty `::after` of `max(100%, var(--tap))` square, centred on it. `--tap` is
  44px and is declared only in the 600px `:root`. No theme can set it.
- Box rules where the `::after` is clipped or overlaps a neighbour:
  - `a.cell-wrap`, `.cell-wrap a`, `.stat__value a`: 44px line-height (one-line
    truncators clip an `::after`).
  - `:where(table.tbl td) a`: inline-block, at least 44px wide.
  - `.btn`, `.toggle`, `.tab`, `.navlink`, `.crumb`, `.themeswitch__btn`,
    `.stat--link`, `.statgrid__cell`: 44px min width and height.
  - `table.tbl a.tag`: 44px (the 768px block keeps it 32px above 600px).
  - `table.tbl tr:has(a, button) > td`: 44px tall. A row with no control keeps
    its dense height.
  - `.section__head:has(a, button)`: 44px tall, items centred.
  - `.tk-pair`: 12px column gap, and both links at least 44px wide.
  - `.bottomnav`: `grid-auto-columns: minmax(max-content, 1fr)`, and each tab
    is at least 44px wide. At 11px the 17 tabs no longer fit 390px. The row
    scrolls inside itself. The 420px comment "reachable without a swipe" is no
    longer true under 600px.
  - `.d-meta` (the ticket page meta line, `src/screens/Ticket.js`): 44px line
    height. This is the one screen-owned rule. That row wraps label-and-link
    spans 6px apart, and no shared component draws it.
- New browser drive `console-ui/tests/drive/tap-drive.mjs`
  (`npm run drive:tap`).

## Why

The ticket measured 28 to 636 controls under 44px per screen at 390px, and 9px
text on all five screens. The fix is in the shared layer, not per screen.

## Remaining gap

The `/world` SVG labels are 8 to 10 user units, scaled by the viewBox. A CSS
media floor cannot map those to CSS px, and `/world` is not one of the five
measured screens.

## How to check

    cd console-ui && node --test tests/tap-targets.bh-6001.test.js
    cd console-ui && npm run build && npm run drive:tap -- --shots /tmp/shots

The drive prints `hit<44: 0 of <n>` per route at 390px and exits 0. It was
observed on 2026-10-12, on Linux chromium (the hub) and on macOS chromium,
after the fix for the lead review at d661ae84b. Before that fix, Linux chromium
exited 1: on /now the "BH-7" key link was 44x18, and the table's scroll edge
clipped its ::after. A table-cell link now has a 44x44 box of its own. With the
`phone-floor.css` import removed it exits 1 (38 of 81 controls miss on `/`, and
the bottom-nav labels are 9px).
