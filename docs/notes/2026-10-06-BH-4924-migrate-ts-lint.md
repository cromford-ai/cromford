# The appliability gate reads a scripts/migrate-*.ts migration (BH-4924)

Doc: LANES, migration-ledger

## What changed

- `bin/lib/migrate-ts-ddl.sh` (new). `mtd_extract <file>` strips `//` and
  `/* */` comments (string literals are matched first and kept, so a `//`
  inside a string survives), then prints one line per statement found in the
  literal first argument of `.execute(`, `.executeMultiple(`,
  `$executeRawUnsafe(`, `db.run(` (and `.batch(`, `.migrate(`, `$executeRaw(`,
  `$queryRawUnsafe(`, `$queryRaw(`, `db.exec(`, so those cannot slip past),
  and in the body of a `$executeRaw`…``, `$queryRaw`…`` or `sql`…`` tagged
  template. A `/…/` regex literal is blanked before the comment strip, so a
  quote inside one cannot turn a real `/* */` span into a comment that hides a
  live call. rc 2 when the file is unreadable.
- Anything it cannot read as a literal is one `COMPUTED <reason>` line:
  `template interpolation` (`${` in a backtick), `string concatenation`,
  `non-literal expression`, `non-literal first argument` (an identifier,
  `{ sql: … }`, an array), `ORM write <op>()`, `SQL literal outside a
  recognised call site` (any other literal that reads as write SQL, the
  backstop for a sink the call list never names), and `no literal SQL found`
  for a file with none of the above.
- Known limit: the regex-literal test is lexical. A regex in a position it
  does not recognise, holding a quote, can still desync the comment strip.
- `bin/check-migration-appliable.sh`: a `.ts` file goes through `mtd_extract`
  (sourced lazily, only when a `.ts` is in the list) and then the same case
  block as `.sql`. `.ts`-only arms run first: every `COMPUTED` line is
  `FLAGGED (computed SQL — never auto-applied)`, `PRAGMA table_info(<t>)` is
  allowed (table bare, `"…"` or `'…'`), an INSERT is allowed only with
  `WHERE NOT EXISTS`, `ON CONFLICT [(cols)] DO NOTHING` or `INSERT OR
  IGNORE` (`ON CONFLICT … DO UPDATE` and `INSERT OR REPLACE` flag), and
  `UPDATE` flags as a data rewrite. A `.ts` also prints `<file>: allowed:
  <stmt>` per statement it passes. Without the lib beside the script,
  a `.ts` is `FLAGGED (ts extractor unavailable — not linted)`.
  The default list (no file args) now also picks up added
  `scripts/migrate-*.ts`. The exit code keys on a `: FLAGGED (` line, and a
  `.sql` report is byte-identical to before.
- `tests/hotfix-migrate-endpoint-test.sh` case 13 no longer pins the gate's
  bytes against main (`git diff --quiet`); it checks that the copy it installs
  still flags a `.sql` DROP and passes a `.sql` ADD COLUMN. The `.sql` byte
  parity is pinned by `tests/migrate-ts-lint.bh-4924-test.sh` P1.

## Why

The data lane (`bin/data-lane-apply.sh`, BH-4923) applies a `migrate-*.ts`
ahead of merge after this gate passes it. Before this change the gate read a
`.ts` as SQL, so every one flagged and the lane could never apply it. Fail
closed: SQL this lint cannot read is never passed.
