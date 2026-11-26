# BH-9304: the period contract, proven end to end on JOBS (BH-9120.0)

Doc: console-ui/README.md

## Why

#9120 puts a date range on every report screen. Its 4 siblings (BH-9120.1-.4)
need one shared period contract first: one URL form, one server parser, one
picker. This ticket ships that contract and proves it on one screen, JOBS.

## What changed

- URL form: `?from=<ISO>&to=<ISO>`, UTC, `to` exclusive. A missing `to` means
  "until now". Rolling presets start at 00:00Z.
- `console-ui/src/lib/period.js` (pure): presets, URL parse and write,
  bucket pick, previous period, `withPeriod` for side-menu links.
- `console-ui/src/ui/PeriodPicker.js`, `PeriodChart.js`, `period-picker.css`.
- `worker/jobs/src/lib/period.js`: `parseRange` (the validator of record),
  `bucketExpr`, `readPeriodKnobs` (one settings statement), `toCsv`,
  `csvResponse`. `console-ui/functions/_lib/period.js` is a copy for the Pages
  functions. PAR1 in `worker/jobs/test/period.bh-9304.test.js` keeps the two
  equal.
- `GET /api/period/knobs` (bearer-gated, reached as `/api/coord/period/knobs`).
- Knobs, seeded by `worker/jobs/schema.d/202611260541-bh-9304-period-knobs.sql`:
  `mc.period.max_range_days` 366, `mc.period.csv_row_cap` 100000,
  `mc.period.default_preset` last_7_days, `mc.period.max_buckets` 2000. Each
  has a code fallback with the same value.
- `GET /api/jobs` takes `from`/`to`. A bad range is a 400 before the jobs read.
  With no range param, the SQL text and the answer do not change.
- JOBS: the picker under the headline. The period comes from the URL, else
  from `mc.period.default_preset`. A closed past range does not poll.
- Side menu: Reports and Logs links carry the current `from`/`to` only.
- `console-ui/src/screens/period-report.d/`: `REPORTS` and 9 null seams, one
  file per sibling.
- `catalog/ci-batch-escalate.d/bh-9304.tsv`: a test in each CI job reads the
  other tree's period module, so a change to one runs the other job.

## Rollback

Revert the PR. The 4 settings rows can stay: no other reader uses them.
