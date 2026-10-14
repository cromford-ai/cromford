# The cost rollup's checkpoints live in the DB (BH-4158)

Doc: COST, verification-map

Slice C0 of BH-4158 (wave 6 of BH-4141, "cost, quota and pool state to the
DB"). It moves the three checkpoints `bin/cost-rollup.sh` kept under
`state/cost/` and deletes their file writers. The rollup inputs, the quota,
gh-budget, pool and model-route state, and the DB-vs-files parity report are
later slices (C1-C5); this one does not deliver the parity report.

## Where each checkpoint lives now

| Was | Now | Writer | Reader |
|---|---|---|---|
| `state/cost/stamped.json` | `ledgers` row, kind `cost-final-bill`, key = the PR URL, detail = when | the nightly rollup's python block, through `bin/jobs-client.sh ledger-put` | the nightly rollup's `# >>> final bill ledger (BH-4158)` block, a full `ledger_page` cursor walk |
| `state/cost/last-success` | `ledgers` row, kind `cost-rollup`, key `last-success`, status `ok`, detail = the ISO-Z time | `# >>> rollup last success` | `bin/pipeline-health.sh` `# >>> cost rollup liveness` |
| `state/cost/rollup-running` | `locks/cost-rollup.running` (`<pid> <ISO-Z>`) | the rollup's lock block | the same block, when a second run finds the lock held |

The run mark stays a file because a pid means nothing off its own box. It
moved beside `locks/cost-rollup.lock`, out of `state/`.

## The final-bill status vocabulary

- `pending`: claimed before `gh pr comment` ran. The outcome is unknown.
- `stamped`: `gh pr comment` returned 0.
- `retry`: the comment failed (non-zero rc, or an exception). The next nightly
  run bills it again. The detail is `attempt <n> <ts>`. A retry row whose
  detail is a bare timestamp (written before the count) counts as attempt 1.
- `failed`: the comment failed 3 times. The run writes one ALERTS line that
  names the PR and never tries again. Without the cap, a PR whose comment
  always fails (archived repo, locked PR, lost token scope) would take one of
  the 30 nightly slots forever.

`pending`, `stamped` and `failed` all count as done. A crash between the claim and
the comment leaves `pending`, which is never retried by itself: a missed bill,
never a second comment on a client's PR. When the claim itself cannot be
written, the run posts no comment for that PR or any later one.

To re-arm a PR stuck at `pending` or `failed` after checking it has no bill comment:

```bash
bin/jobs-client.sh ledger-put cost-final-bill https://github.com/<owner>/<repo>/pull/<n> retry
```

The nightly run reads every `cost-final-bill` row before it bills anything. A
failed page, a page that is not a ledger list, or more than 50 pages of 1000
rows makes the set unknown. Then the run bills nothing and logs
`final-bill ledger unreadable — no PR bills this run` to `logs/agent-rules.log`.

## The legacy `stamped.json`

Every run (hourly and nightly) imports up to `COST_STAMP_IMPORT_CHUNK` entries
(default 200) as `stamped` rows, keys and times unchanged. An entry leaves the
file only after its PUT landed, the import stops at the first failed PUT, and
the file is deleted once it is empty. The first import copies the whole file to
`logs/cost-stamped-legacy-<UTCdate>.json`. While the file exists the python
block reads it as well, so an entry not imported yet is never billed. Each run
logs `cost-rollup: final-bill import: <n> imported, <m> remaining`.

## Liveness

`bin/pipeline-health.sh` takes the newest of the row, a legacy
`state/cost/last-success` and `summary.json`'s mtime. A ledger it cannot read
is neither stale nor absent: it just stops counting, and the page text says
`(ledger unreadable)` or `(no ledger row yet)`. A box with neither
`summary.json` nor a legacy stamp makes no ledger request.

When the last-success put fails, the rollup logs
`last-success row NOT written` and still exits 0. That run's `summary.json`
mtime covers it.

No new table, route, cron line, setting or flag. `COST_STAMP_IMPORT_CHUNK` is
optional, with a code default.
