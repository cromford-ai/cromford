# Open PRs join the migration-number check; bare self-references move; foreign lock keys are noted (BH-7398)

Doc: MERGE-CONDUCTOR

## What changed

On 2026-10-18, 13 project-6 PRs took a migration number another open PR
already held (0270 five times, 0279 four times, 0281 four times). BH-7365
renumbered only against main. This change adds three things to
`bin/lib/migration-renumber.sh`.

- **Open PRs are taken too.** `mnr_fix <wt> <base-ref> <project> [<self-branch>
  [<self-pr>]]`. When `migration_renumber.open_prs[.<project>]` is `1`, the
  lib lists the repo's open PRs (one paged REST list), fetches their heads in
  one `git fetch` into `refs/mnr-open/<ns>/`, and reads the migrations each
  PR ADDED from its merge base. It drops the refs on every path.
  - Before the PR exists (the builder's pre-PR step) every open PR counts.
  - At a rebase (`mc_rebase`, the pool twin) only an open PR with a LOWER
    number takes a number. The older PR keeps it; the newer one moves. So two
    PRs never both move off one number.
  - Not taken: the PR whose head is the self branch, a PR of the same ticket
    (`ticket/<key>(-r<n>)?`), a file with the same name as one the branch
    added (a stacked child).
  - A move lands above every open PR's number, not only above main's.
  - Message: `0270 is taken by open PR #10 (0270_a.sql); this PR's number is 0271 (prisma/sql/0270_b.sql -> prisma/sql/0271_b.sql)`.
  - A read that fails prints one stderr line, `migration renumber: open PRs
    not read (<why>) — main only`, and the check runs against main only. The
    origin url is parsed for the slug and never printed.
- **Bare self-references move.** The moved file's own bare number (RAISE
  text such as `'apply 0270 as ...'`, `'0270: project-6_app ...'`) moves with
  it. An added non-migration file that names the old stem (`0270_x`) gets the
  bare number too, so a test asserting `'0270: ...'` follows. A modified file,
  a kept branch migration, and an added file that does not name the stem keep
  a bare number: there it can mean main's file. All forms are now one perl
  substitution, so a chain (0213 -> 0270 while 0270 -> 0271) moves each token
  once.
- **Lock notes.** `mnr_lock_notes <wt> <base-ref> <project>` prints one line
  per branch-added migration whose `pg_advisory_(xact_)lock` calls (outside
  `--` comments) take a `<prefix>NNNN` key and never the file's own key:
  `prisma/sql/0293_x.sql takes lock mk0270 (<int>), not its own mk0293 (<int>): a shared lock is legal, a stale one is not`.
  It is report-only. project-6 shares `mk0003` across 16 files on purpose, so
  no rule can tell a deliberate share from a stale key. The builder adds these
  lines to the `## Migration numbers (BH-7365)` PR-body section.

## The knobs

| Key | Env | Default |
|---|---|---|
| `migration_renumber.open_prs[.<project>]` | `MNR_OPEN_PRS` | off. `1` = on. Seeded `1` for project-6-os. |
| `migration_renumber.open_prs_max` | `MNR_OPEN_PRS_MAX` | 200. Valid 1..1000; another value reads as 200 with one warning. |

Seed: `worker/jobs/schema.d/202610182040-bh-7398-migration-renumber-open-prs.sql`.

## Not in this change

- Plan-time reservation (ticket item 1) is open PR #7346 (BH-7325).
- The project-6 CI check (item 4): the duplicate half is already in
  project-6's unit suite (TK-996). The "above every applied number" half
  reverses project-6's TK-1118 decision and needs that team's call.
- The pool twin sends the mnr_fix stderr to /dev/null, so a failed open-PR
  read is not logged there.

Test: `tests/migration-renumber-open-prs.bh-7398-test.sh`.
