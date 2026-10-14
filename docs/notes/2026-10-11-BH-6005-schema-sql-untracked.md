# worker/jobs/schema.sql leaves git (BH-6005.4, #6011)

Doc: OPERATOR-SETUP, EVENTS, MERGE-CONDUCTOR

## What changed

- `worker/jobs/schema.sql` is removed from git (`git rm --cached`) and listed in
  `.gitignore`. It is the composition of `worker/jobs/schema.d/`, and every
  reader composes its own copy:
  - the deploy: `bin/harness-sync.sh` composes it into its snapshot before the
    D1 apply and `wrangler deploy` (BH-6005.0);
  - CI and the lints: `bin/schema-build.sh --ref <rev>` for a base revision
    (BH-6005.2);
  - the test corpus: `tests/lib/jobs-schema.sh` and
    `worker/jobs/test/lib/jobs-schema.js` (BH-6005.1).
- `bin/schema-build.sh` reads how git holds the render:
  - tracked and ignored: `--check` is red, "must not be in git";
  - untracked and ignored: `--check` validates the fragments only, and a stale
    working copy is a one-line note, not an error; `--write` no longer treats the
    working copy as a source of statements (what a commit put in schema.sql is
    still checked);
  - anything else (another worker's schema, a non-git tree): as before.
- The `worker/jobs/schema.sql` row leaves `config/regenerated-paths.conf` and
  `MC_REGENERATED_PATHS_DEFAULT`: no branch commits it, so nothing conflicts on it.
- The Cloud worker's schema was deleted by BH-5239.4, so no other committed schema.sql is left.

## Operator steps

- By hand on a checkout, compose before a manual D1 apply:
  `bin/schema-build.sh --worker jobs --write` (worker/jobs/README.md,
  skills/console-deploy/SKILL.md).
- After the merge, on the hub: `grep 'worker jobs schema.sql'
  /root/harness/logs/update-runners.log | tail -3` shows `unchanged (<sha7>)` or
  `applied`, and `logs/ALERTS.log` has no `could NOT be composed` line.

## Why

Two branches that each added one fragment both re-rendered the committed file
and conflicted on it. On 2026-10-11 that parked 8 approved PRs for up to 1,300
minutes. With the render out of git, two fragment branches merge cleanly
(`tests/schema-untracked.bh-6005-4-test.sh` U1).
