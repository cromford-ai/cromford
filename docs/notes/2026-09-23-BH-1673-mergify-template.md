# BH-1673 (BH-1698) — one Mergify template, rendered per repo

Doc: MERGIFY

## What changed

- `config/mergify/template.yml` is the one `.mergify.yml` template. It has the
  same shape as cromford's root `.mergify.yml`: a `hotfix` queue first,
  then `default`, then `priority_rules`, then two `pull_request_rules` keyed on
  `label=merge-queue` (+/- `label=hotfix`). `base=<base>` is in every rule, and
  `checks_timeout` is on both queues. Its tokens are `@@BASE@@`,
  `@@MERGE_METHOD@@`, `@@BATCH_SIZE@@`, `@@BATCH_MAX_WAIT@@`,
  `@@CHECKS_TIMEOUT@@` and `@@MAX_PARALLEL@@`. A line that holds only
  `@@CHECKS@@` becomes one `- "check-success=<name>"` per check. The hotfix
  queue's `batch_size: 1`, `batch_max_wait_time: 0 s` and
  `max_checks_retries: 0` are literals, so no conf can change them. There is no
  `speculative_checks` key.
- `bin/mergify-template.sh` no longer stubs its verbs. Its interface (BH-1697)
  is unchanged:
  - `render <conf>` prints the repo's YAML. A bad conf is rc 2 with
    `<conf>:<line>: <problem>` on stderr and nothing on stdout. A bad conf is
    an unknown key, a duplicate scalar, a non-integer, `max_parallel_checks` > 3,
    or a missing `slug=`/`check=` line. Nothing is clamped. Defaults fill only
    keys that are absent.
  - `compare <conf> <yaml>` `safe_load`s both files and normalizes every
    condition string (it trims, turns `\s*=\s*` into `=`, and drops one pair of
    quotes round the value, so `check-success = "X"` equals
    `"check-success=X"`). Then it compares sorted-key JSON. rc 0 means in sync.
    rc 1 prints a unified diff. rc 3 means it cannot compare: no PyYAML, an
    unreadable or unparseable file, a non-mapping, or a bad conf. List order
    is kept, because queue order means something.
  - `marker <yaml>` prints the reason from the first
    `# harness-mergify: override <reason>` line whose reason isn't blank
    (rc 0). Otherwise it's rc 1. It's plain shell and needs no PyYAML.
  - `--check` renders every `config/mergify/repos/*.conf`, parses the result,
    and checks `hotfix` comes before `default`. For `cromford.conf` it also
    requires `compare` rc 0 against the root `.mergify.yml`, or the marker on it.
    No root file means nothing to sync, and that passes. It's rc 0 or 1. No
    PyYAML, or zero confs, is rc 1.
- docs/MERGIFY.md §2's block is now project-5.conf's render with its comments:
  default `batch_size: 4`, `batch_max_wait_time: 3 min`,
  `checks_timeout: 45 min`, and `base=main` in both routing rules.
  `tests/fixtures/mergify/project-5.mergify.yml` is the byte-exact render
  under its kept header.

## Why

the operator's rescope of BH-1673 (2026-09-23 17:17Z): project-5 already batches, the
`speculative_checks` ask is void, and `max_parallel_checks` multiplies CI runner
minutes (docs/CI-RUNNERS.md), so it is capped at 3. The doc block, the fixture
and each repo's file used to be hand copies of one another. Now they are
renders of one source, and `compare` tells you which one drifted.

## Commands

    bin/mergify-template.sh render config/mergify/repos/project-5.conf
    bin/mergify-template.sh compare config/mergify/repos/cromford.conf .mergify.yml
    bin/mergify-template.sh marker .mergify.yml
    bin/mergify-template.sh --check

`compare` and `--check` need PyYAML (`python3 -c 'import yaml'`).
`tests/mergify-template.bh-1673-test.sh` pins all of the above. Without PyYAML
it prints one `SKIP (no PyYAML): <section>` line for each section it couldn't
run.
