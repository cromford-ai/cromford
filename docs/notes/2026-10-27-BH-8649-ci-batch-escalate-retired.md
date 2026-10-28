# The old batch-escalation rules file is retired (BH-8649)

Doc: MERGIFY, TESTING

## What changed

- `catalog/ci-batch-escalate.tsv` is deleted. Its 93 rows are in 4 seed
  fragments in `catalog/ci-batch-escalate.d/`, one per kind:
  `seed-escalate.tsv` (escalate and allow), `seed-infra.tsv`, `seed-spa.tsv`
  and `seed-worker.tsv`. The rows are byte for byte the same, in the same
  order inside each file. The old file's header prose is now the "The kinds"
  section of `catalog/ci-batch-escalate.d/README.md`.
- `cbe_rules` reads only the fragments. No reader reads the old file. A file
  planted at the old path changes no answer.
- `cbe_check` (the lint) refuses anything at `catalog/ci-batch-escalate.tsv`
  with `catalog/ci-batch-escalate.tsv:0: retired (BH-8649)`, and a folder with
  no fragment with `catalog/ci-batch-escalate.d:0: no rules fragment`.
- No fragment fails closed: `cbe_reason` escalates every path (the text
  `selection input: catalog/ci-batch-escalate.tsv unreadable` is unchanged),
  and `cbe_affects` now answers "affected" when the rules hold no row.
- The old path stays a key of the rules diff (`cbe_rules_path`,
  `cbe_rules_diff`) and a self row of the full-trigger delta. So the diff that
  deletes the old file and seeds the fragments deletes no row, and a batch
  runs it as infra, not as the whole corpus.

## Why

The old file was one shared tail. BH-8608 (C0) added the fragment folder;
this slice moves the rows and removes the second source.

## Tests

`tests/ci-batch-escalate-retired.bh-8649-test.sh` compares the seeds with the
frozen old file (`tests/fixtures/bh-8649/old-rules.tsv`), replays every row and
the real planner with both, and checks the lint. A later edit of a seeded row
must update the fixture.
