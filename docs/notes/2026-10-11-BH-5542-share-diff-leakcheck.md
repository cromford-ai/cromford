# Share-mirror leak check on every PR diff (BH-5542)

Doc: TESTING

## What changed

- New `bin/share/diffcheck.py`. It reads `git diff -U0 <merge-base> HEAD` and
  runs `bin/share/leakcheck.py`'s rules on each ADDED line, as the sanitized
  mirror sees that line:
  - It skips a path the mirror never ships: `bin/share/` (but not the
    overlay), the two publisher scripts, every `sanitize.dropped()` path and a
    path that `bin/share/overlay/` replaces whole.
  - It scans a `bin/share/overlay/<p>` line raw, because it ships raw as `<p>`.
  - It runs every other line through `sanitize.rewrite()` first. A client name
    that the mapping rewrites is not a hit.
  - It checks the mirror path of an added file for names.
  - It does not read a file outside `mapping.TEXT_EXT` or a font. The RUN
    answer of `--share-precheck` already sends that file to the full share
    suite.
  - Renames are off, so a dropped file that moves to a shipped path is a new
    file and gets scanned.
- `bin/fast-lints.sh --share-precheck` runs diffcheck first. The PR `lint`
  step `share-mirror leakcheck pre-check (BH-3860)` already calls that verb on
  every PR, so a text-only PR is now checked too. The workflow is unchanged.
- `bin/share/leakcheck.py`, `bin/share/mapping.py` and the two batch suites
  (`tests/share-publish-clean.bh-795-test.sh`,
  `tests/share-mirror-clean-test.sh`) are unchanged.

## Why

The old pre-check printed `SKIP` when a PR added only text files, and the step
then passed. #4124 (a uuid in two test fixtures) and #5281 (a full 64-hex sha
in a test) reached the merge-queue batch that way. Each failed whole batches.

## Contract

- diffcheck rc 0: clean. stdout ends with
  `diffcheck: clean, <n> added or changed file(s) since <fork12>`.
- diffcheck rc 1: hits. One `<path>:<line>: <label>: <full match>` line and
  one `  fix: ...` line per hit. With `GITHUB_ACTIONS=true`, also one
  `::error file=<path>,line=<n>,title=share-mirror leak::...` line, which
  GitHub shows on the PR's Files tab. The match is not cut short.
- diffcheck rc 2: it could not answer (no merge base, a git error, an import
  error, a crash, diff sections that do not pair with the file list). A crash
  is never rc 1 and never rc 0.
- `fast-lints.sh --share-precheck` writes the diffcheck report to stderr and
  keeps stdout for `SKIP`/`RUN`. diffcheck rc 1 gives rc 1. Any other non-zero
  gives rc 2. The CI step turns both into a red step.

## How to fix a hit

1. If the string is a name, replace it with its placeholder. Or add a row to
   `bin/share/mapping.py` so `sanitize.py` rewrites it.
2. If the string is a uuid, a key or a 64-hex token, replace it with a
   placeholder: an all-zero id, or a literal that says fixture, example or
   do-not-ship. Or have a human add the exact string to
   `KNOWN_FAKE_IDENTIFIERS`, `KNOWN_FAKE_CREDENTIALS` or
   `KNOWN_PUBLIC_CHECKSUMS` in `bin/share/mapping.py`.
3. To check before you push, run
   `python3 -I bin/share/diffcheck.py --base origin/main`.

Tests: `tests/share-diffcheck.bh-5542-test.sh` (D1-D15) and
`tests/fast-lints-run.bh-3860-test.sh` (A2).
