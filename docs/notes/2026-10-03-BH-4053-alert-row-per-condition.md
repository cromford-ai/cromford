# One console row per alert condition (BH-4053)

Doc: ALERTS-STATE-MACHINE

## What changed

- `bin/alert-line.sh --id <id>` now keys the console row on `alert:<id>` (the id
  folded to `[A-Za-z0-9_.-]`), not on the line's derived `alert:auto-<row_key>`.
  `alertid` is still the raw `--id`. The helper also records an alias from the
  line's derived key to the id, so the poll-commands re-beat of the same line
  lands on the same row.
- `bin/pipeline-health.sh` `alert()` passes `ph-<key>` (`stalepr:ts` →
  `ph-stalepr_ts`) through `alert_emit`; past the tick cap the plain append
  writes the same alias.
- `bin/alert_family.py` gained `shape()`; `family()`, `identifiers()` and
  `row_key()` are unchanged.
- `bin/alerts-supersede.py` resolves open `alert:auto-*` rows whose shape
  matches an open explicit `alert:` row, reason `superseded by <akey> (legacy
  auto key, BH-4053)`. That pass runs before the subject collapse, and its rows
  are left out of the subject's newest pick, so a legacy row can never
  supersede the explicit row.

## Why

The stalepr alert named its PR list, and the derived akey hashed that list, so
every change in the set of aging PRs opened a new console row for the same
condition (two rows on 2026-10-02 for one `ts` stalepr condition).

## What it touches

Every existing `--id` caller's akey moves from `alert:auto-…` to `alert:<id>`
on deploy: `bin/deploy-train.sh`, `bin/oauth-refresh.sh`,
`bin/factory-stop.sh`, `bin/stuck-work.sh`, `bin/lead-review-land.sh`,
`bin/lib/build-tripwire.sh`, `bin/hub-probe.sh`. Their already-open rows are
retired by the supersede pass on the next groom run once the new row is open.
