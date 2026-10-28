# catalog/ci-batch-escalate.d/ — the batch-escalation rules (BH-8608, BH-8649)

These files hold the merge-queue escalation rules: which changed paths make a
Mergify batch run the WHOLE corpus instead of its impact set (BH-4968). A new
row goes in a new file here. The old single file
`catalog/ci-batch-escalate.tsv` is retired (BH-8649): it was one shared tail,
and parallel PRs that each appended a row conflicted on it. Its 93 rows are in
the `seed-*.tsv` files, one file per kind. The lint refuses the old file if
it comes back (see "The lint").

## Format

One file per owner: `<ticket>.tsv` in lower case (for example `bh-9001.tsv`),
or a theme name for seeded rows (`seed-escalate.tsv`, `seed-infra.tsv`,
`seed-spa.tsv`, `seed-worker.tsv`). Only `*.tsv` files and this README belong
here, one level down; a sub-folder or another file name fails the lint.

The columns are tab separated:

```
<pattern>	<escalate|infra|allow|spa|worker>	<why>
```

- `<pattern>` ending in `/` is a prefix (`bin/lib/` matches everything under
  bin/lib); anything else is a bash glob matched against the whole path.
- `<why>` is one line, for the reviewer of the row.
- `#` lines and blank lines are skipped.

## The kinds

- `escalate`: the path runs the whole corpus. The escalate rows are a
  `.github/` path that is not a top-level workflow, `.mergify.yml`, the rules
  themselves when their diff deletes a row (see below), and the folder row in
  `bh-8608.tsv`. Rules with no escalate row (no fragment included) escalate
  every batch.
- `allow`: exempts a path an escalate or infra row would catch. A doc
  (`bin/lib/*.md`, `catalog/*.md`) never escalates on its own (BH-6059). A
  top-level workflow file (`.github/workflows/<x>.yml` or `.yaml`, BH-6876)
  selects the suites that read it plus the always set (`bin/test-impact.sh`,
  `TI_BATCH_SELECT=1`), and the nightly corpus is the backstop. An allow row
  beats a `CI_FULL_TRIGGERS` `+` row too: to escalate workflow edits again,
  remove the two allow rows by PR.
- `infra` (BH-7287, BH-7033.1): the paths the selection itself runs on: the
  planner, the selector and tier step, the libs and catalogs those three
  source and read, the runners, and `tests/lib/scratch.sh`. A batch that
  touches one runs, mode=infra:
  1. the self and reads suites of each infra path (`bin/test-impact.sh select
     --why --map-only`), the suites that test that file;
  2. the fixed canary list `catalog/ci-infra-canary.txt` over each runner path
     (scratch sandbox, docker runner, suite runner, tiers, reuse ledger); a
     list that cannot be read or checked runs the corpus;
  3. the normal selection of the batch's other paths, always set included.
  An escalate row beats an infra row, so `CI_FULL_TRIGGERS=+<path>` forces
  one back to the corpus with no PR. The nightly corpus is the backstop.
- `spa` and `worker` (BH-4969): read by `cbe_affects`, not `cbe_reason`. On a
  batch that stays batch-selected, `bin/ci-plan.sh` writes spa=0 (worker=0)
  when no changed path is affected, and the console-ui (worker-jobs) job then
  runs only its "not affected by this batch" step. A path under `console-ui/`
  (`worker/`) is always affected, row or no row. These rows add the paths
  OUTSIDE those trees each job builds or tests from: what `console-ui/` and
  `worker/jobs/` import or read by a relative path
  (`tests/ci-plan-spa-worker.bh-4969-test.sh` fails on one with no row), and
  the scripts the jobs' own workflow steps run. A path that also escalates
  still carries its row, so deleting an escalate row cannot un-gate a job.
  Every non-batch-selected run, and an escalated batch, runs both jobs whole.

BH-6059 replaced the blanket `bin/lib/` and `catalog/` rows with single files:
19 of 21 sampled batches ran the whole corpus through them, a README included.
Every other bin/lib/ or catalog/ path runs its impact set, and one the impact
map has no specific row for (a new file, a deleted one) still escalates, as
`unmapped path <p>`: `bin/test-impact.sh` does that under `TI_BATCH_SELECT=1`,
which only `bin/ci-plan.sh`'s batch select sets. The rows are derived from
what the scripts source and read; `tests/ci-batch-escalate-narrow.bh-6059-test.sh`
fails when a path in test-impact's infra list has no row. Not rows, on
purpose: `catalog/ci-suite-durations.tsv` (shard weights, not which suites
run), `catalog/test-impact-orphans.txt` and `catalog/ci-merge-reuse.tsv` (PR
lint, never read when a batch is selected).

BH-6371 replaced the blanket `tests/lib/` row the same way. A changed helper
under tests/lib/ selects every suite that sources or imports it, directly or
through another helper (`bin/test-impact.sh`'s helper closure, again only
under `TI_BATCH_SELECT=1`), and one that no suite reaches is
`unmapped path <p>`. An infra row under tests/lib/ is the list of GLOBAL
helpers: one whose change is a change to about every suite, so its impact set
is the corpus anyway.

## How the rules are composed

`cbe_rules` in `bin/lib/ci-batch-escalate.sh` prints every `*.tsv` here in
`LC_ALL=C` name order. Every reader uses it: `cbe_reason`, `cbe_affects`,
`cbe_infra`, `bin/ci-plan.sh`, the suite fingerprint
(`bin/test-impact.sh inputs`) and `bin/ci-plan-split-replay.sh`. A fragment
that cannot be read, or no fragment at all, fails closed: every batch runs the
whole corpus. `CI_BATCH_ESCALATE_TSV` (tests only) replaces the fragments with
one file. The full-trigger delta `CI_FULL_TRIGGERS` (BH-6838) adds and removes
escalate rows over the composed rules; its grammar is in the lib's header.

## What a batch does with a rules diff

`bin/ci-plan.sh` judges this folder and the retired old file as ONE diff
(`cbe_rules_diff`), so the diff that deleted the old file and seeded its rows
here is not a delete:

1. Only rows of kind escalate, spa or worker added: the batch selects through
   the map; an added spa (worker) row turns that job on.
2. No row deleted (a why edit, a comment edit, a row moved between files, an
   infra row added): the changed rules files are infra paths.
3. Anything else (a deleted row or file, a kind change, an added allow row, a
   malformed row, a mode change, a diff that cannot be read): the whole corpus,
   through the `catalog/ci-batch-escalate.d/` escalate row in `bh-8608.tsv`.

## The lint

`cbe_check` refuses: a row with fewer than 3 tab fields, an empty pattern, an
unknown kind, an empty why, the same `(pattern, kind)` in two different files,
a pattern whose literal directory does not exist, a file here that is not a
readable `*.tsv` or this README, a folder with no `*.tsv`
(`catalog/ci-batch-escalate.d:0: no rules fragment`), and anything at
`catalog/ci-batch-escalate.tsv` (`catalog/ci-batch-escalate.tsv:0: retired
(BH-8649)`). A PR that branched before BH-8649 and appends a row to the old
file conflicts with its delete: put the row in a new file here.
`tests/ci-batch-escalate-fragments.bh-8608-test.sh` runs the lint on the tree:

```bash
( . bin/lib/ci-batch-escalate.sh && cbe_check )
```
