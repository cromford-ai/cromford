# catalog/ci-batch-escalate.d/ — the batch-escalation rule fragments (BH-8608)

These files hold rows of the merge-queue escalation rules. A new row goes in a
new file here. Do not append a row to `catalog/ci-batch-escalate.tsv`: that
file was one shared tail, and parallel PRs that each appended a row conflicted
on it. A later slice (C1) moves its rows into this folder.

## Format

One file per owner: `<ticket>.tsv` in lower case (for example `bh-9001.tsv`),
or a theme name for seeded rows. Only `*.tsv` files and this README belong
here, one level down; a sub-folder or another file name fails the lint.

The columns are the same as in `catalog/ci-batch-escalate.tsv` (see its
header), tab separated:

```
<pattern>	<escalate|infra|allow|spa|worker>	<why>
```

- `<pattern>` ending in `/` is a prefix; anything else is a bash glob matched
  against the whole path.
- `#` lines and blank lines are skipped.

## How the rules are composed

`cbe_rules` in `bin/lib/ci-batch-escalate.sh` prints
`catalog/ci-batch-escalate.tsv`, then every `*.tsv` here in `LC_ALL=C` name
order. Every reader uses it: `cbe_reason`, `cbe_affects`, `cbe_infra`,
`bin/ci-plan.sh`, the suite fingerprint (`bin/test-impact.sh inputs`) and
`bin/ci-plan-split-replay.sh`. A source that cannot be read fails closed:
every batch runs the whole corpus. `CI_BATCH_ESCALATE_TSV` (tests only)
replaces all the sources with one file.

## What a batch does with a rules diff

`bin/ci-plan.sh` judges the old file and this folder as ONE diff
(`cbe_rules_diff`):

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
a pattern whose literal directory does not exist, and a file here that is not
a readable `*.tsv` or this README. `tests/ci-batch-escalate-fragments.bh-8608-test.sh`
runs it on the tree:

```bash
( . bin/lib/ci-batch-escalate.sh && cbe_check )
```
