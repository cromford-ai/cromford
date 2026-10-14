# BH-5526: spend alerts at 1.5x own p99 and at 3x the fleet $/PR median, refusing nothing (slice C2)

Doc: COST

**Why.** The only per-project spend alert compared a project's cost per merged
PR with a FIXED hand budget (`costrate:` in the cost budget block, rows in
`catalog/cost-caps.conf`). Nothing compared a project or a lane with its own
history, and nothing compared a project with the fleet. The ticket asks for
alerts, not stops.

**What changed.**

- New block `# >>> spend alerts` in `bin/pipeline-health.sh`, right after
  `# <<< cost budget`. It runs once per `SPEND_ALERT_INTERVAL_S` (default
  3600 s) under its own stamp `state/spend-alerts.stamp`.
- New script `bin/spend-alerts.sh` does the arithmetic and prints TSV:
  - `baseline`: the p99 daily spend of each project and each lane over the
    last `SPEND_ALERT_DAYS` (14) complete UTC days of `cost_rows`. The rule is
    the `bin/budget-defaults.sh` rule: identical lines count once, refused and
    settled rows are not spend, a day with no rows is not a sample, p99 is
    nearest-rank. A row with an empty `lane_id` is grouped under its `stage`.
    A key with fewer than `SPEND_ALERT_MIN_DAYS` (7) days has no alert line.
  - `over`: today's UTC spend per key against `SPEND_ALERT_P99_MULT` (1.5) x
    its p99.
  - `perpr`: `cost_per_merged_pr_7d` from `state/cost/summary.json` against
    `SPEND_ALERT_PERPR_MULT` (3) x the fleet median. Only projects with
    `SPEND_ALERT_PERPR_MIN_PRS` (3) or more merged PRs in 7d count; `other`,
    `fleet` and a null rate never count. With fewer than 3 such projects there
    is no median and no alert. A project must stay over for
    `SPEND_ALERT_PERPR_HOLD_S` (172800 s, 2 days) before it alerts.
- Alert keys: `spendp99:<project|lane>:<key>`, `spendperpr:<project>`,
  `spendalertnoeval:fleet`. Each goes through `alert()` (console row and
  Telegram beat) with a TTL of 86400 s, so a key alerts at most once a day.

**What it never does.** The block calls no `flag_set`, `cb_halt`,
`page_critical` or `setting_set` and writes nothing under `flags/`. No build,
merge or project is refused or held by it.

**Unreadable is not $0.** A failed or disarmed `cost_rows` read writes no
baseline and judges no key. It raises one `spendalertnoeval:fleet` alert a day.

**State.**

- `state/spend-alerts/baseline-<YYYYMMDD>.tsv`: today's p99 table, rebuilt from
  `cost_rows` when absent (one 14-day read a UTC day). Older files are deleted.
- `state/spend-alerts/perpr-over.tsv`: `project<TAB>first_over_epoch`, the start
  of the 2-day hold. Written tmp + `mv`. Losing it delays a per-PR alert; it
  never fires a false one.

**Not in this slice.** The unpriced-calls alert already exists
(`# >>> unpriced call alert` in `bin/cost-rollup.sh`, `costunpriced:` in the
cost budget block). Ceiling rows seeded from p99, the Mission Control view and
the project-2 unpriced calls are later slices.

**Tests.** `tests/spend-alerts.bh-5526-test.sh`.
