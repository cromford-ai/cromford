# BH-5934: box switches on /flags, and the long dated latch pin

Doc: none

## What changed

- `/flags` has a BOX SWITCHES section under ALL FLAGS. It lists every settings
  row `switch.<name>.<box>` whose value is 1, on or true (trimmed, any case).
  Columns: BOX, SWITCH, VALUE, SET BY (`actor`), SET AT (`updated_at`). SWITCH
  links to `/config/setting/<key>`. BOX links to `/machines`.
- The rows come from `GET /api/coord/settings`. `FlagsScreen` starts that read
  in the same mount as the flags read, so the two reads run in parallel. Both
  poll every 60 s.
- The pure half is `console-ui/src/lib/box-switches.js`. The key pattern is the
  one `_ls_box_key` in `bin/lib/lane-switch.sh` writes. The ON set is the one
  `lane_switch` uses.
- `tests/latch-long-name.bh-5934-test.sh` runs the real `bin/alerts-groom.sh`
  on a 150-char `alerted-model-runner-mismatch-*` latch. The suite builds the
  name with the same expression as `bin/agent-call.sh`.

## Why the settings rows and not /api/flags?scope=<box>

The ticket names `GET /api/flags?scope=<box>`. On main the box `*-disabled`
switches are settings rows (BH-2320, BH-2435), not `harness_flags` rows. That
route returns none of them. The section reads the store `lane_switch` reads.

Not listed: a box switch that is only a `flags/` file on its box. The console
cannot read a box's files.

## The rule for a later row store (item 2)

No code on main shortens a latch name. A store that does shorten one must keep
the date last: `<first 100 chars>-<md5>-<YYYYMMDD>`. `groom_alert_flags` reads
the date from the last `-` segment and keeps any name whose last segment is not
8 digits. If the date goes, the latch is never purged.
`tests/latch-long-name.bh-5934-test.sh` fails if the `bin/agent-call.sh` writer
drops `-$_ACDAY`, or if the groom stops purging a long dated latch.

## Visual check (1280 px and 375 px, dark and light)

`console-ui/tests/drive/box-switches.bh-5934-drive.mjs` serves the built
bundle with the flags and settings reads stubbed (3 ON box rows, 1 OFF box
row, 1 fleet row). It opens `/flags` in chromium in the mill (dark) and paper
(light) themes at 1280x900 and 375x780. It ran 56 checks, and all passed:

- The BOX SWITCHES title and table are visible. They list the 3 ON rows only,
  sorted by BOX.
- All 5 column heads carry `aria-sort`. A click on SWITCH sorts by it.
- The title, the column heads (sorted and not sorted), the cells and the links
  have the same computed values as the ALL FLAGS table. The section uses the
  console design and adds no new style.
- At 375 px the body does not scroll sideways (`scrollWidth` 375). The table
  scrolls inside its own `overflow-x:auto` container (720 px of 353 px).

The screenshots and the computed-value table are in `console-ui/docs/bh-5934/`.
The fixed mobile nav appears mid-page in the 375 px full-page shots. That is
how a full-page capture draws a fixed bar. It is the same on every screen.

To run it again:

```bash
cd console-ui && npm run build && node tests/drive/box-switches.bh-5934-drive.mjs --shots docs/bh-5934
```
