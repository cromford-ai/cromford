# A data statement that changes 0 rows is `empty`, not `ok` (BH-8914)

Doc: MERGE-CONDUCTOR, OPERATOR-SETUP

## What changed

On project-3, the TK-488 grant UPDATE matched 0 rows on 2026-10-31. TK-477 had
already changed the same row. The ledger recorded the file `ok`, and the grant
had to be fixed by hand.

The hub migration lane (BH-8704, `bin/lib/migration-lane.sh`) now judges the
row count of each data statement in a member file, after `migrations/status`
proves the file applied. The judge is `bin/lib/migration-rowcount.py`.

- A data statement is UPDATE, DELETE, INSERT ... SELECT, or WITH ...
  UPDATE/DELETE/INSERT (the main verb after the CTE list; WITH ... INSERT
  takes the INSERT ... SELECT rule).
- CREATE, ALTER, DROP, GRANT, INSERT ... VALUES, DO blocks and function bodies
  are not counted.
- A data statement that changed 0 rows is `empty`, unless the file marks it
  `-- may-be-empty: <reason>`.

## The report contract

The lane does not run SQL. The row count exists only inside the project's apply
CLI. So the CLI prints one line per statement it ran, at the start of a line of
its stdout or stderr:

```
migration-rows: <file basename> <ordinal> <COMMAND> <rowCount or ->
```

- `<ordinal>`: the 1-based position of the statement in the file, over every
  non-empty statement.
- `<COMMAND>`: the Postgres command tag word (node-pg `Result.command`).
- `<rowCount>`: node-pg `Result.rowCount`, or `-` when the driver gives none.

Example (project-6 `scripts/db/apply-sql.mjs`, `applyFile`, after COMMIT):

```js
[].concat(await client.query(sql)).forEach((r, i) =>
  console.log(`migration-rows: ${file} ${i + 1} ${r.command} ${r.rowCount ?? "-"}`));
```

## The marker

`-- may-be-empty: <reason>` exempts one statement. The key is
case-insensitive and the reason must not be empty. It counts on the lines
above the statement, inside the statement, or on the line of its `;`, after
the `;`. A `/* */` comment or a string literal never counts.

## Verdicts and what the lane does

| Report for the file | Verdict | Member merges? | Log line |
|---|---|---|---|
| no `migration-rows:` line | `unreported` | yes, as before | `#N <file>: the apply output has no migration-rows lines; row counts not checked` |
| count >= 1 | `ok` | yes | none |
| count 0, marker | `marked` | yes | `#N may-be-empty: <file> statement <k> (<reason>)` |
| count 0, no marker | `empty` | NO | `#N empty: <file> statement <k> (<COMMAND>, line <L>) changed 0 rows` |
| no line for the statement, another COMMAND, `-`, or an ordinal past the last statement | `unaligned` | NO | `#N not merged: <file> row report does not match its statements` |
| the judge crashed | - | NO | `#N not merged: row-count judge failed on <file> (rc <rc>)` |

An `empty` member:

1. does not merge. The batch ends `failed` with the existing critical alert
   `migration-lane-<project>-<batch id>`. The other members still merge.
2. gets the jobs ledger row `pr <project>#<n>` = `empty <head> <file> statement
   <k>`. `ml_gate_pr` skips the PR (`#N skipped: a data statement changed 0
   rows on <sha8>; waits for a new head`) until the head moves.
3. gets one PR comment that names each empty statement and the two ways
   forward.

The judge prints no SQL text and no apply-output text, so nothing from
`apply.out` reaches a PR comment or the log.

## Known limits

- The check runs after the CLI committed. An `empty` file is already in
  production. A marker added after that changes a file that production holds,
  and the lane refuses it as `changed`. The fix is a new migration file, or an
  operator merge when 0 rows is correct.
- A CLI that prints no report line is not checked (fail open per file). That
  is project-6 and project-3 today, until their CLIs print the line.
- `DO $$ ... UPDATE ... $$` and function bodies are not counted: their command
  tag is `DO` or `CREATE`.
- Main's own pending files are not members and are not judged.

## Owed operator steps

- project-6 `scripts/db/apply-sql.mjs`: print the `migration-rows:` line (the
  example above).
- project-3: the same change in its apply CLI.

## Tests

- `tests/migration-rowcount.bh-8914-test.sh`: the judge (classifier, marker,
  report reader, verdicts).
- `tests/migration-lane-rowcount.bh-8914-test.sh`: the real lane entry point on
  the BH-8704 fixture, with the SQLite fake apply CLI
  `tests/lib/migration-rowcount-fake-apply.bh-8914.py`.
