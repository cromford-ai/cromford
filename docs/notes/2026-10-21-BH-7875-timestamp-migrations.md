# Timestamp migrations are not renumbered (BH-7875)

Doc: MERGE-CONDUCTOR

## What changed

example-org/project-6 moves new migrations to a 14-digit UTC timestamp prefix,
`YYYYMMDDHHMMSS_slug.sql` (example-org/project-6#2215). Before this change
`bin/lib/migration-renumber.sh` read that prefix as a sequence number. A
timestamp file that followed a moved file got a zero-padded name
(`20261021183000_a.sql` -> `00000000000453_a.sql`), two equal timestamps were
renumbered, and a timestamp on main made every 4-digit collision a decline.

- A name in the migration dir whose prefix is exactly 14 digits is a timestamp
  migration. `_mnr_names` skips it. It is never renamed, never TAKEN, never
  read from an open or queued PR, and never in `mnr_lock_notes`. A 13- or
  15-digit prefix is still a sequence number. 4-digit files work as before.
- A file the branch added that is a timestamp migration is an ordinary added
  text file for the reference rewrite: a stem of a moved 4-digit file inside it
  changes, its own name does not.
- The pre-queue hook (`bin/lib/mc-prequeue.d/migration-numbers.sh`) counts only
  sequential names (`mnr_seq_added`). A head that adds only timestamp files
  answers `none` with no lock, no fetch and no REST read.
- New knob `migration_renumber.format[.<project>]` (env `MNR_FORMAT`):
  `sequential` (no row, the default) or `timestamp`. `timestamp` sets the mode
  to `off`, so the conductor rebase, the pool rebase, the builder's pre-PR step,
  the pre-queue hook and the pool review comment all stop for that project.
  `mnr_fix` then writes one stderr line per branch that adds a file in the dir:
  `migration renumber: skipped — migration_renumber.format.<project> is timestamp (<n> added file(s) in <dir>)`.
  Another value prints one warning and reads as `sequential`.

No seed row ships. With the 14-digit skip, a project can keep `sequential`
while it has both kinds of file.

## How to switch a project to `timestamp`

1. After the project numbers every new migration by timestamp, write the row
   from a box with the jobs lib loaded:

       setting_set migration_renumber.format.project-6-os timestamp "BH-7875: migrations are timestamped"

   Or in the D1 `settings` table:

       INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES
         ('migration_renumber.format.project-6-os','timestamp','BH-7875: migrations are timestamped','<you>','<now ISO>');

2. On the next conductor rebase of a PR that adds a migration, look for the
   skip line: `grep 'skipped — migration_renumber.format' logs/merge-conductor.log`.
   A builder writes the same line to its `pipeline.log`. The pre-queue hook
   writes no `MIGRATION_RECHECK` line for the project.
3. To go back, set the row to `sequential`:
   `setting_set migration_renumber.format.project-6-os sequential`.

Verified by `tests/migration-renumber-timestamp.bh-7875-test.sh`.
