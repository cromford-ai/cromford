# BH-10128: the suite-preflight setup used npm on a pnpm repo

Date: 2026-11-25. Ticket: #10128 (hotfix).

## What failed

Five project-3 pool builds stopped at the suite preflight between 18:02 and 18:26 UTC with `could-not-run: node_modules after one setup attempt (npm install --no-audit --no-fund --no-package-lock (rc=1))`. example-org/project-3 has `pnpm-lock.yaml` and no `package-lock.json`.

## Cause

`sp_install` in `bin/lib/suite-preflight.sh` (BH-7695) knew only npm. It ran `npm ci` with a `package-lock.json` and `npm install --no-package-lock` with any other repo. npm stops on a pnpm repo.

## Fix

A new function `sp_pm` picks the install command from the lock file in the build worktree:

| Lock file | Command |
|---|---|
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` |
| `yarn.lock` | `yarn install --frozen-lockfile`, or `yarn install --immutable` with `.yarnrc.yml` (berry) |
| `package-lock.json` | `npm ci --no-audit --no-fund` (unchanged) |
| none | `npm install --no-audit --no-fund --no-package-lock` (unchanged) |

If more than one lock file is present, the order is pnpm, then yarn, then npm. If `package.json` has a `packageManager` field, or the tool is not on PATH, pnpm and yarn run through `corepack`. If neither the tool nor corepack is on PATH, nothing runs and the rc is 127. A pnpm or yarn repo never falls back to npm.

The one-attempt rule, the `SUITE_PREFLIGHT_SETUP_S` bound and the log append do not change.

## How to read it

- `HARNESS_PREFLIGHT: setup <cmd> (rc=<n>)` stays the same. A note in brackets follows the rc in two cases.
- `[pnpm not found on this box]`: the box has no pnpm and no corepack. The record is `HARNESS_EXIT: could-not-run: node_modules`, and the one daily alert carries the same text. This is an infra fault, not a PR finding.
- `[pnpm-lock.yaml chosen over package-lock.json]`: the repo has more than one lock file, and the note names the one that was used.

## Proof

`tests/suite-preflight-pm.bh-10128-test.sh`: red on origin/main (9 passed, 31 failed), green after the fix (40 passed). `tests/suite-preflight.bh-7695-test.sh` stays green with no change.
