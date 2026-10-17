# A batch-fail suite fix goes first in the merge queue (BH-7279)

Doc: MERGIFY, MERGE-CONDUCTOR

## What changed

- New `bin/lib/queue-flake-fix.sh`. `qff_enqueue_step` runs inside `mc_enqueue_mergify` (marked
  block `# >>> queue flake-fix (BH-7279)`), before the queue-risk block and the `merge-queue`
  label. rc 0 always: it never holds a PR.
- The rule: a changed file is exactly a suite on the batch-fail list
  (`bin/prequeue-learned.sh --list --why`: seeds, plus counted suites at
  `flake_fix.min_fails`), and every changed file matches `flake_fix.scope_globs`. Then the PR
  routes `flake-fix` and gets `queue-flake-fix` before `merge-queue`. Every other PR routes
  `default`, and a stale `queue-flake-fix` from an older head is removed.
- One `QFLAKE <slug>#<n>@<head12> suite= queue= mode= reason=` line per decision in
  `logs/merge-conductor.log`.
- Rows, no seeds (the code fallback is the default): `flake_fix.mode` (enforce),
  `flake_fix.min_fails` (1), `flake_fix.scope_globs` (test and doc paths). Read once per
  conductor tick.
- `bin/mergify-template.sh` takes an optional `flake_fix_label=` conf key. It renders a
  `flake-fix` queue (batch_size 1) after `hotfix` and before `solo`/`default`, its rule, and a
  `-label=<flake_fix_label>` on the default and solo rules. `--check` refuses a render with
  `flake-fix` out of that order. The key refuses `merge-queue`, `fix-main-red`, `hotfix` and the
  `solo_label` value. `cromford.conf` sets `flake_fix_label=queue-flake-fix`;
  `.mergify.yml` carries the blocks.
- No priority rule: the queue never interrupts running checks. The `hotfix` build label and
  the `fix-main-red` hotfix queue do not change.

## Why

On 2026-10-17 the fix for a suite that kept failing merge-queue batches (#7194,
`tests/staff-watchman.bh-5565-test.sh`) waited in `default` behind the batches that suite failed.

## Known limit

A fix that also changes code routes `default`. #7194 itself changed five `bin/` and `catalog/`
files, so under the default scope row it routes `default`. Widen `flake_fix.scope_globs` to
change that.

## Rollback

`flake_fix.mode=off`. Then delete `flake_fix_label=` from the conf and re-render `.mergify.yml`.

Tests: `tests/queue-flake-fix.bh-7279-test.sh`, `tests/mergify-flake-fix-queue.bh-7279-test.sh`.
