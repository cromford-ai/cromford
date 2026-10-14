# Cost, health and orchestration alert writers go through alert-line.sh (BH-2314 part 3, BH-2364)

Doc: ALERTS-STATE-MACHINE

## What changed

- **Nine scripts now write their ALERTS.log lines through `bin/alert-line.sh`**
  instead of a bare `echo … >> ALERTS.log`: `reopen-metrics.sh`,
  `orchestrate.sh`, `cost-rollup.sh`, `healthcheck.sh`, `pipeline-health.sh`,
  `cost-reconcile.sh`, `context-gate.sh`, `cache-hit-report.sh`, and four sites
  in `agent-call.sh`. Each call is
  `HARNESS="$ROOT" "$ROOT/bin/alert-line.sh" "<text>"`, where `$ROOT` is the
  file's own root variable and `<text>` is what used to follow the stamp. The
  line on file is byte-identical to before. The alerts row is now noted at emit
  time rather than a minute later by the poll-commands re-beat. The
  `HARNESS=` prefix matters: several of these files set `H`/`HARNESS` without
  exporting it, and the helper reads `${HARNESS:-/root/harness}`.
- **cost-rollup's new-unpriced-pair alert still writes, then marks.** The helper
  exits 0 whether or not its append landed, so the ledger puts and
  `flags/alerted-unpriced-new-<date>` now wait until the exact stamped line
  (`ALERT_LINE_STAMP` is passed so the text is known) reads back from the last
  200 lines of ALERTS.log.
- **A per-tick cap in pipeline-health.sh and cache-hit-report.sh.** Both route
  every line through `alert_emit`, which calls the helper for the first
  `ALERT_LINE_TICK_MAX` lines of a run (the `alerts` conf row via `alert_cfg`,
  default **20**). Lines past the cap are the old plain append, which the
  poll-commands re-beat notes a minute later. That write is the one raw site
  left in each file, marked `# alert-writer overflow (BH-2364)`, so both keep
  a ratchet baseline of 1.
- **agent-call.sh:** the four literal-path sites were converted. That includes
  the `@file` unreadable line, which now writes under `${HARNESS:-/root/harness}`
  instead of the literal `/root/harness`. Its 22 `>> "$ALERTS"` sites are not
  converted yet, and its baseline is 22.

## By-design, kept on the file

Each of these has `# alert-writer: by-design — <why>` in its header, and its
baseline is deleted:

- `bin/hub-lease.sh`: its writes page that the jobs worker is unreachable, and
  that is the same worker the helper's beat needs. They are also the
  no-lane-alert.sh fallback in front of every hub cron lane's gate.
- `bin/alerts-medic.sh`: the medic consumes the alerts pipeline. Noting its own
  lines at emit time would feed the table it is triaging.
- `bin/iron-law-guard.sh`: a PreToolUse hook. Its LOUD path runs with PATH
  broken, and the helper drops the line when `tr` is missing. A network beat
  before `exit 2` also risks a hook timeout, which the CLI reads as allow.

## Knob

`ALERT_LINE_TICK_MAX` is read through `alert_cfg`: the environment first, then
the `alerts` settings row `alert_line_tick_max`, then `set ALERT_LINE_TICK_MAX <n>`
in `flags/alerts.conf`. It must be a non-negative integer, and its default is 20.

## Tests

`tests/alert-line-wave-cost-health.bh-2314-test.sh` runs the whole
`bin/cost-rollup.sh` against a stub beat.sh, checks the batch cap and the
write-then-mark gate, and counts the remaining sites. Suites that build a
scratch `bin/` now copy `bin/alert-line.sh` and `bin/alert_family.py` into it.
Suites that source a pipeline-health block also source the
`# >>> alert emit cap` block.
