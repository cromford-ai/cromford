# Migration autopilot ledger is DB only (BH-2532.1, BH-2623)

Doc: migration-ledger

## What changed

- `bin/migration-autopilot.sh` no longer reads or writes
  `state/migration-autopilot-done.txt`. The `LEDGER=` path and its `touch` are gone.
- `ledger_has` answers from `job_ledger_get` alone. The three answers from BH-1040
  are unchanged: rc 0 present, rc 1 absent, rc 2 unknown, and unknown still HOLDs
  the run. A DB hit is no longer back-filled into a file.
- `ledger_put` writes the `ledgers(kind=migration)` row only. When
  `job_ledger_put` fails, or the client is missing, it logs one
  `migration ledger write failed (status '<s>' not recorded)` line to
  `logs/<project>.log`. It used to be swallowed by `|| true`. It still returns 0,
  so `FAIL` and the per-file loop keep their flow.
- Existing done-files on boxes are left where they are. Nothing deletes them.

## Why

The file was read first, so a row in it made a file "present" without asking the
DB. A migration the DB had no record of could be skipped on the file's word, and
the two stores could drift with nothing reconciling them.

## What it costs

Every tick asks the DB once per candidate file (48 h window). A row lost to a
failed write costs a re-check, not a re-apply: the next tick's `is_applied` reads
the app's own applied list before any apply POST. A `failed-alerted` file whose
row was lost is retried and alerted again on the next tick. So is every
`failed-alerted` file on a box with no worker configured. The lane runs only on
the hub, which has a worker.

## Tests

- `tests/migration-autopilot-ledger.bh-2623-test.sh` (new): A1-A6, N1.
- `tests/migration-ledger-three-answers-test.sh` cases 2 and 3: the back-fill
  assertions became "no done-file" and "the second run re-asks the DB".
