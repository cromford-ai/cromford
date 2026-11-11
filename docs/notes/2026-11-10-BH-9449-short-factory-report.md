# BH-9449: the daily factory report is short on Telegram

Doc: docs/verification-map/entries/archie-fm-report.md

## Cause

The report of 2026-11-09 filled two Telegram messages. `Spend vs caps` had 67
rows, and about 43 of them were per-build cost keys such as
`cromford.9317.2a7f0fd23c7e`. Five sections said only "none".

## Change

1. `bin/archie-fm-report.sh` sends `afr_render_short`
   (`bin/lib/archie-fm-report/render.sh`). What needs the operator comes first, one
   line each with its link: open stop-the-line incidents, failed Archie
   actions, a project over its day cap, open stuck items, and one
   "N more on Mission Control" line for a truncated list. Then the mode, the
   merge counts per project, the spend total against the total of the day
   caps, and `Full report: <console_pages_url>/factory?day=<day>`.
2. An empty section is left out. A section whose read failed keeps one
   "not measured" line.
3. The spend line lists a project over `report.spend_min_usd` (5.00) or over
   `report.spend_cap_pct` (50) percent of its cap, and `unknown` over
   `report.spend_unknown_min_usd` (1.00) with its call count. The rest is one
   "N other projects: $X in total" line. The three rows are seeded by
   `worker/jobs/schema.d/202611110543-bh-9449-report-short-settings.sql`. A
   bad or unreadable row uses the code fallback and writes one warn line.
4. Both texts add a key `<project>.<number>.<hex>` to its project row, and
   print "partial: U of C calls unpriced" once, as a total.
5. `archie-fm-report.sh render <day>` still prints the full text.
   `render <day> --telegram` prints the short text. Neither sends.

The route `GET /api/archie/factory-report` and the Mission Control
`/factory` screen do not change.

Tests: `tests/archie-fm-report-short.bh-9449-test.sh`.
