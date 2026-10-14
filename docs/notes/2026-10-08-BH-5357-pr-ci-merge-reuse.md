# A merge-from-main PR push reuses the last green for the lint job's tree checks (BH-5357)

Doc: CI-RUNNERS

## What changed

- New `bin/ci-merge-reuse.sh`, a step `id: reuse` in the `lint` job of
  `.github/workflows/harness-ci.yml`, right after `bash -n`. It runs on every
  `pull_request` push with `continue-on-error: true` and decides `mode=full` or
  `mode=reuse`.
- `mode=reuse` needs all four of these: the knob is on, the action is
  `synchronize`, `bin/lib/merge-push.sh` `mp_classify` says the new commits only
  merge the base branch (`clean`, the `patch_same` main-merge proof, or
  `resolved`, the same shape with conflict hunks or a hand edit inside the
  merge), and the previous head (`github.event.before`) has a `Harness CI` run
  on the same branch with `conclusion == success`. Anything else is `mode=full`,
  which runs every step as before. That covers a real commit anywhere in the
  push, a force-push or rebase, a sibling or octopus merge, a merge-queue head,
  a cancelled or failed previous run, a failed or unparseable REST read, no gh,
  and a push that touches the decider's own inputs (`.github/**`, the catalog,
  the two scripts, `bin/lib/patch-same.sh`, `bin/lib/lane-gate.sh`, the knob
  file).
- New `catalog/ci-merge-reuse.tsv` maps four lint steps to the paths they read:
  `vmap` (verification-map index), `derived` (llm-sites + test-impact orphans),
  `renders` (lane renders) and `render-diff`. In reuse mode a step still runs
  when a conflict resolution matches its globs, or when main's incoming change
  and the PR's own patch both match them. Otherwise it gets `run_<id>=0` and the
  workflow skips it (`if: steps.reuse.outputs.run_<id> != '0'`). An empty output
  runs the step. Every other lint step, including the rules pack and
  `bin/fast-lints.sh`, has no such `if:` and always runs.
- The `lint` job now declares `permissions: contents: read, actions: read`, so
  the step can read the runs with the job's own token.
- New knob `PR_CI_MERGE_REUSE` (`on` | `off`, default `on`), registered in
  `catalog/lanes.d/_lib.ci-merge-reuse.json`. `mp_knob` reads it as settings
  row > cached row > env > registry default. CI can't read the settings row, so
  it gets the repo Actions variable `vars.PR_CI_MERGE_REUSE`, and when that's
  unset it falls back to the registry default. To turn it off:
  `gh api -X POST repos/example-org/cromford/actions/variables -f name=PR_CI_MERGE_REUSE -f value=off`.

## Why

On 2026-10-07/08, about 30 conflicted PRs had main merged into them. Every push
re-ran the lint job's tree checks from scratch, although the PR's own patch
hadn't changed and main's side was already green on main.

## What is still owed

- Part A (the suite-result ledger, #5354) has not merged, so this is the
  ticket's fallback: the patch-same proof plus a file-class intersection
  through the catalog's globs. That runs more than a per-suite fingerprint
  would, never less. When the ledger lands, its fingerprint rung replaces the
  glob intersection.
- Nothing mirrors a settings row into the repo variable yet.
- Ordinary PR CI has run no test corpus since 2026-09-24, so the "suites" this
  step can skip are the lint job's tree checks. The merge-queue batch still runs
  the impact set on the tree that lands.

Tests: `tests/ci-merge-reuse.bh-5357-test.sh` (classifier and entry point on
real git fixtures), `tests/ci-merge-reuse-wiring.bh-5357-test.sh` (workflow).
