# BH-6175: failed calls write a priced $0 row; unpriced calls alert per lane (slice C5 of BH-5526)

Doc: COST

**Probe (as of 2026-10-12 08:15Z, read-only).** The plan session ran
`cost_rows_fetch` from `bin/lib/cost-rows-read.sh` for
2026-09-28T00:00Z..now (20,661 rows).

- project-2, 2026-10-05..10-12: 593 rows, 516 priced. The rest are 72
  `refused` rows, 4 `settled` rows and 1 blank row (`review-prs`, rc 127,
  0 tokens). No billed call is unpriced.
- The "81 unpriced calls in 7 days" of 2026-10-08 are all failed calls with
  0 tokens: 60 `run-triage` claude `<synthetic>` rows (rc 1,
  `row_source=transcript`), 20 `run-triage` codex rows (rc 1,
  `row_source=none`) and the 1 rc 127 row. `bin/cost-rollup.sh` `agg()`
  counted each one as unpriced.
- Fleet, 14 days: 10 billed rows with a blank cost, all `alert-triage` on
  2026-09-28. 0 since then.

**Writer.** `_ac_unbilled` in `bin/agent-call.sh` (block
`# >>> unbilled row (BH-6175)`) returns 0 when ALL of these are true: rc is
not 0; the four token counts are empty or 0; the cost is empty or 0;
`row_source` is `none`, `transcript` or `result`; and the stage is `canary` or
rc is not 124, 137 or 143. `ac_cost_row_write` then writes
`row_source=unbilled` and `cost_usd=0`. Before this, only stage `canary` with
`row_source=none` got this (BH-3222). A blank `cost_usd` is NULL in D1, and
the D1 readers count NULL as unpriced.

What stays blank: a timeout or kill rc (124, 137, 143) with no readable usage
on any stage but `canary`. A session killed partway may have been billed. Its
row stays `row_source=none` with a blank cost.

**Reader.** `bin/spend-alerts.sh unpriced --rows <csv> --since <iso>` prints
`lane<TAB>calls<TAB>pairs<TAB>projects`. A row counts when `ts >= since`, the
line is not a duplicate, `row_source` is not `refused`, `settled` or
`unbilled`, `cost_usd` is blank or not a number, and it is not (rc not 0 and
0 tokens). The lane is `lane_id`, else `stage`, else `(none)`.

**Alert.** Step 2 of the `# >>> spend alerts` block in
`bin/pipeline-health.sh` (hub only) runs the reader on today's `cost_rows`
before the p99 check and raises `alert 86400 "spendunpriced:<lane>"` per line,
so one lane alerts at most once a UTC day. The alert refuses nothing. If the
reader fails, the block raises `spendalertnoeval:fleet` and the p99 check
still runs on the same file.
