# A plain CREATE INDEX on a large table is a deterministic BLOCK (BH-7667)

Doc: LEAD-REVIEW, REVIEW-PRS, REVIEW-LEVELS

## Problem

On 2026-10-20 the lead review approved project-6 #2016 as MERGE-WITH-NOTES.
Its `prisma/sql/0338_salesforce_connector.sql:61` runs a plain
`CREATE INDEX IF NOT EXISTS … ON event (…)`. In prod, `event` is about 12 GB.
A plain CREATE INDEX blocks every write to the table for the whole build. A
person caught the same defect on #1920 and #1910. A model finding with those
words was also demoted to a NOTE by `rl_cap`, because no ALWAYS-BLOCK pattern
matched it.

## What changed

- `bin/lib/migration-index-lint.sh` (new) reads the PR's unified diff. A
  `CREATE [UNIQUE] INDEX` with no `CONCURRENTLY` directly after `INDEX`, in an
  added or changed statement of a `*.sql` file, on a listed table, gives one
  line: `- [BLOCK destructive-migration] <path>:<line>: CREATE INDEX on large
  table <t> without CONCURRENTLY …`. Comments are removed first, and the line
  is the line of `CREATE`. No model decides it.
- Lead review (`bin/lead-review.sh`): the block `# >>> migration index lint`
  runs after the console qa gate and before the patch-same replay. Red = a
  BLOCK report (`- migration lint: red`, `- reviewer model: migration-lint`)
  with no agent call. A diff git cannot read leaves the request for the next
  tick and is not counted. Each review logs `<key>: migration lint
  clean|off (<why>)|could not run (rc N)`, or `red (N finding(s))`.
- Box review (`bin/review-prs.sh`): the lint reads the `gh pr diff` file. A red
  lint refuses the `review_bought` reuse on that head. After the level cap, the
  lint lines go into the posted review and its verdict line becomes
  REQUEST_CHANGES (replaced, not repeated).
- `catalog/review-always-block.tsv`: the `destructive-migration` pattern also
  matches "large table … without CONCURRENTLY", so a model's own finding with
  those words stands under `rl_cap`. `prompts/lead-review.md` item 2 names the
  same case.

## The knob

The large-table list is the settings row `review.large_tables.<project>`
(then `review.large_tables`), comma- or space-separated, read through
`rl_knob`. Seed: `review.large_tables.project-6-os = event`. No row = no lint
and no diff read for that project. On a settings outage the list is empty for
that tick (`rl_knob`'s fail-open). `REVIEW_LEVEL_LARGE_TABLES` in the env wins.

To add a table:

    bin/jobs-client.sh setting-set review.large_tables.project-6-os "event, <table>" "<why>"

## Limits

- Only `*.sql` files. A migration in TS/JS and `ALTER TABLE … ADD CONSTRAINT …
  UNIQUE` are not linted.
- The in-build review (`bin/lib/rb/review.sh`) does not run the lint.
- The replay fixtures in `tests/fixtures/bh-7667/` are reconstructions, not
  verbatim copies of the project-6 files (the build had no GitHub egress).
