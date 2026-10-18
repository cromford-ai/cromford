# A colliding migration number is renumbered at rebase time (BH-7365)

Doc: MERGE-CONDUCTOR

## What changed

On 2026-10-17 about half of the approved project-6-os PRs collided on a
migration number (`prisma/sql/NNNN_slug.sql`) with main or with each other.
Each build picks "highest on main + 1" at plan time, so parallel builds pick
the same number. git merges them cleanly, because the two file names differ,
and project-6's `tests/unit/migration-numbers.TK-996.test.ts` then fails.

The ticket offered two fixes. This change ships option 2 (renumber at rebase
time) plus item 3 (a clear message). Option 2 covers every PR, including PRs a
person opened and builds that never asked for a number. It adds no table, no
route and no plan-prompt change. Option 1 (a D1 counter at plan time) is not
built.

- `bin/lib/migration-renumber.sh` (new, prefix `mnr_`). `mnr_fix <wt>
  <base-ref> <project>` finds the migrations the branch ADDED whose number is
  taken on the base (or by an earlier branch file). It moves that file and
  every branch file after it to the next numbers above the base's highest, in
  order and at the same digit width. A free number below the base's highest
  is kept (project-6 TK-1118 allows it). It rewrites the references in one
  pass and makes ONE commit. `mnr_check` prints the messages only.
- References: the old stem (`0213_x`) in every text file the branch added or
  modified. In every text file the branch added (not a kept branch
  migration): `migration:0213`, `<prefix>0213` and the advisory lock key, the
  integer of the ASCII bytes of `<prefix>0213` (`mk0128` =
  120307137458744). A modified file keeps its `migration:NNNN`, because there
  the number can name main's own file. Base-only files are never edited.
- The commit: `BH-7365: renumber migration(s) past <base> <sha8>`, with one
  `Union-resolved: <old> -> <new> (BH-7365, migration renumbered)` trailer
  per move. `mc_rebase` already reads that trailer and does not rebind the
  approval (rc 5). A renumber writes lines no reviewer read (iron guardrail 1),
  so the head-bound re-review reads the new head.
- The message, one line per moved file:
  `0213 is taken on main by 0213_project-5_import.sql; this PR's number is 0235 (prisma/sql/0213_x.sql -> prisma/sql/0235_x.sql)`.
  A duplicate inside the PR says `0235 is used twice in this PR (0235_a.sql, 0235_b.sql); ...`.
  When no number fits the width: `...; no free number above 9999 for prisma/sql/0213_x.sql (width 4) — not renumbered`.

## Where it runs

- `mc_rebase` (bin/lib/mc/rebase.sh): after `mc_regen_generated`, before the
  typecheck and unit gates, only when the base is main. rc 0 logs each move.
  A decline logs `migration number collision not fixed — <message>` and
  answers rc 2 ("gate red, not pushed"). Could-not-run logs one line and goes
  on unchanged.
- The pool twin (bin/lib/rebase-job.sh step 6c): the same call. A decline is
  `GATE_RED migration-number: <message>`. The trailers join `UNION:`.
- The builder (bin/lib/rb/pr.sh, `# >>> migration renumber (BH-7365)`):
  after the pre-PR rebase, not for a stacked build. One pipeline.log line per
  move and a `## Migration numbers (BH-7365)` section in the PR body. It never
  stops the build.

## The knobs

| Key | Env | Default |
|---|---|---|
| `migration_renumber.dir[.<project>]` | `MNR_DIR` | empty = off. Seeded `prisma/sql` for project-6-os. |
| `migration_renumber.mode[.<project>]` | `MNR_MODE` | `fix`. `check` = message only. `off`. Another value reads as `check`. |
| `migration_renumber.lock_prefix[.<project>]` | `MNR_LOCK_PREFIX` | empty = no lock rewrite. Seeded `mk` for project-6-os. Must match `^[a-z]{1,3}$`. |

The env value wins over the rows, and a `.<project>` row wins over the bare key.
The seed is `worker/jobs/schema.d/202610180309-bh-7365-migration-renumber-settings.sql`.

## Known limits

- A migration that prod already applied under its old name is applied again
  under the new name. project-6 files are `IF NOT EXISTS` / `ON CONFLICT DO
  NOTHING`, so this is a re-apply, not data loss.
- A stacked child is renumbered only when it merges main.
- `migration:NNNN` in an added non-migration file is read as the branch's own
  number.

Test: `tests/migration-renumber.bh-7365-test.sh`.
