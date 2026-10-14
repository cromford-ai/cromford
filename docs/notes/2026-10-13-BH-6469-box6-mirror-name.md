# The publisher maps project-6's box short-name (BH-6469)

Doc: MIRROR-NOTES

## Why

The public mirror kept project-6's 4-letter box short-name in 48 files:
the cost accounts, the lane box lists, the per-box cron paths and some
comments. `bin/share/mapping.py` mapped every other box short-name, but not
this one, and the leak guard did not know the name.

## What changed

`BOUNDED_PROJECTS` in `bin/share/mapping.py` has one more row. The name now
maps to `project-6`. The row feeds two readers with no other edit:

1. `sanitize.build_rules()` rewrites the name on a word boundary, case
   insensitive, in text and in paths.
2. `NAME_TOKENS` and `leakcheck.BOUNDED` now hold the name, so a publish that
   leaves it in the tree is refused.

`tests/share-publish-clean.box6.bh-6469-test.sh` pins both readers and the
look-alikes that must stay untouched.

## Known residual

Two boxes now share the name `project-6` in the mirror. The project-6 box
already maps to `box-project-6-1`. Both boxes' `cron/boxes/<box>.d` and
`.order` paths land on `cron/boxes/project-6.d` and `.order`. The files are
byte-identical today, so the mirror loses no content, but the later write
wins. `bin/box-lists-check.sh` over the mirror reports 13 findings. Six of
them come from the shared name: `MISSING ... project` four times,
`BAD box_aliases` and `BAD cost_rows project-6 in 2 accounts`. That check's
suite does not ship to the mirror, so no shipped test goes red. This needs a
follow-up ticket.
