# BH-6865: the ledgers.archive retention rule

Doc: OPERATING

## What changed

A new retention rule, `ledgers.archive`
(`worker/jobs/src/routes/retention.d/bh-6865-ledgers-archive.js`), moves old
`ledgers` rows of audited, allowlisted kinds from the hot D1 to the archive D1
(`env.ARCHIVE`). It is off by default. Before this change no rule touched
`ledgers`. The BH-9076 coverage contract changes with it: its C3 now allows
exactly one rule on `ledgers` (this one, off by default, with `kinds` and
`delCutoff`), and the `-- no-retention: ledgers` line of
`worker/jobs/schema.d/202611070341-bh-9076-no-retention.sql` is gone, because
`ledgers` now has a rule (C4 refuses a `no-retention` line for a ruled table).

- Per batch: copy to the archive, count the copy back, then delete. The delete
  re-checks `updated_at < cutoff`, so a row that a PUT changed after the copy
  stays hot. `removed` counts only the rows the delete removed.
- The archive copy is newer-wins (`ARCHIVE_TABLES.ledgers.newer`): a key that
  was written again after its move replaces the archived row only when the hot
  row is not older.
- `GET /api/ledger?kind&key` answers a moved key from the archive
  (`archived: true`) through the fallback of BH-6863.

## The per-kind audit

`worker/jobs/src/lib/ledger-kind-class.js` holds `LEDGER_KIND_CLASS`, a code
safety floor (not a setting). A listed kind moves only when its class is `key`,
`list-only` or `write-only`. A `never` kind or a kind not in the map
(`unaudited`) is refused, and the rule error names it:
`refused kinds: migration(never), made_up_kind(unaudited)`.

The map has 15 `key` kinds and 35 `never` kinds. It is the r2 rebuild of the
audit, approved in BH-6865 comment 6565721483 in place of the parent plan's
lost 98-row table. The 15 `key` kinds were re-checked on main 4ded20624,
69ce222bb, 41dd49ab2 (2026-11-02), 0bebd1d8d, 22d8c0ad9 (2026-11-03) and
45ae12e2 (2026-11-24). To make a kind
movable, repeat the audit in the file's doc comment for that kind and change
its class in a PR.

## Settings rows

| Row | Default | Meaning |
|---|---|---|
| `retention.ledgers.archive_days` | 0 | The window. 0 is off. A value below `archive_min_days` (default 91) is out of range and is off. |
| `retention.ledgers.archive_kinds` | empty | Kinds an operator allows to move. |
| `retention.ledgers.archived_kinds` | empty | Written by the rule only. Kinds that may have rows in the archive. Never remove a kind by hand. |
| `retention.ledgers.sticky_wait_s` | 120 | Seconds between the record of a kind and its first move. Valid 120..86400, else 120. |
| `retention.ledgers.archive_min_days` | 91 | The lowest window the rule accepts. Valid 91..3650. A value below 91 or not a whole number is ignored, so the floor stays 91 (`LEDGER_ARCHIVE_FLOOR_DAYS`). A row can raise the floor, never lower it. |

## The two-run start

1. A real run finds a listed, movable kind that is not in `archived_kinds`. It
   appends the kind to `archived_kinds` and moves nothing in that run.
2. A later run moves the kind's rows when the `archived_kinds` row is at least
   `sticky_wait_s` old. The wait is 2x the 60 s settings cache cap, so every
   isolate reads the kind as sticky before a row leaves hot.

A dry run writes no settings and counts only recorded kinds. With `ARCHIVE`
unbound, a real run writes no settings and its audit row says
`archive not bound`.

A new kind recorded later moves the `archived_kinds` timestamp, so the kinds
already recorded also wait one more `sticky_wait_s`. That delays a move; it
never loses a row. The fallback reader keeps the first 64 entries of the row;
with 15 movable kinds the row cannot pass that.

## Turn it on

1. Bind `ARCHIVE` (see `worker/jobs/src/lib/archive.js`).
2. Set `retention.ledgers.archive_kinds` to the kinds to move, for example
   `review_block_fp`.
3. Set `retention.ledgers.archive_days` to `retention.ledgers.archive_min_days` (default 91) or more.
4. Read the `retention_runs` rows for `ledgers.archive` after the next two
   hourly runs.
