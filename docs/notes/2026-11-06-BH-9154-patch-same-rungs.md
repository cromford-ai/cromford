# Lockfile and whitespace rungs for the review rebind (BH-9154, Fix 1)

Doc: MERGE-CONDUCTOR

## What changed

`bin/lib/patch-same.sh` has a new rung, `patch_same_semantic`.
`patch_same_review` asks it after `restamp-rebase`. It prints one of two names.

- `lockfile`. The two heads' diffs from their merge-bases differ only in files
  whose basename is in `PATCH_SAME_LOCKFILES`. Every such lockfile that differs
  must:
  - have a path from `git diff --name-status -z`, in the safe set
    `[A-Za-z0-9._@+/-]`. A path such as `x b/package-lock.json` is rc 1. The
    rung never parses `diff --git` header text.
  - have status M on each side that changes it, and mode 100644 on the new
    head. An added or deleted lockfile is rc 1.
  - have a sibling `package.json` whose diff (index lines dropped) is
    byte-equal on the two heads.
  - install the same code on both heads. The rung reads the lockfile blob at
    the reviewed head and at the new head with `jq`. Every `packages` entry
    (v2, v3) and every nested `dependencies` entry (v1) must have the same key
    and the same `version`, `resolved`, `integrity` and `link`. Every
    non-link `resolved` on the new head must be an https URL on a host in
    `PATCH_SAME_LOCK_HOSTS`. So only a reorder or a metadata-only rewrite
    passes. Only `package-lock.json` has a parser; any other named lockfile
    is rc 1.

  The commit author is never the permission. An author email is what the
  commit claims, so a rule based on it is no rule. Before BH-9154 any lockfile
  byte forced a re-review. Now only a change that cannot alter what `npm ci`
  installs keeps the review.
- `whitespace`. The diffs are equal when each file outside
  `PATCH_SAME_WS_SIGNIFICANT` is diffed with `--ignore-space-at-eol` (CR
  included), and each file in that list is diffed exactly. The rung is rc 1
  when a changed line has trailing whitespace after a `\` (a continuation),
  and when the head adds more CR-ended lines than the reviewed head did
  (`_ps_cr_added`: LF to CRLF in a shell script is not whitespace to bash).
  Indentation, blank lines, modes and file types stay a change. The file and
  mode header lines must also be equal.

Every git failure, binary file or bad knob entry is rc 1. The rung does not
combine with a schema restamp: a restamp plus a whitespace edit is still a
change.

## Who uses it

Only the review callers, through `patch_same_review`: the conductor rebind,
gate 50, `bin/review-prs.sh` and `bin/review-autopilot.sh`. The callers did
not change. The CI and test result reuse callers stay on byte `patch_same`.

## Knobs

`catalog/lanes.d/_lib.patch-same.json`:

- `PATCH_SAME_LOCKFILES` (default `package-lock.json`;
  empty turns the lockfile rung off).
- `PATCH_SAME_LOCK_HOSTS` (default `registry.npmjs.org`; empty allows no
  host).
- `PATCH_SAME_WS_SIGNIFICANT` (default `.py .yml .yaml .md .mk Makefile .patch
  .diff .tsv`).

## Test

`tests/patch-same-semantic.bh-9154-test.sh` (cases L1-L19, W1-W8).
