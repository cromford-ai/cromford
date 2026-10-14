# No tracked file is git-ignored or says "do not commit" (BH-5518, slice C2)

Doc: verification-map

## What changed

Main tracked two files that the repo declares it does not want:

- `worker/jobs/src/routes.gen.js`. Its line 2 says "Do not edit and do not
  commit: git-ignored". Merge 5023639a (PR #5138) brought it in from open PR
  #4624 (BH-4607). Nothing imports it: `worker/jobs/src/index.js` imports each
  `routes/*.js` directly. Its generator and its `.gitignore` line belong to
  #4624, so this slice only deletes the file.
- `locks-worker/.wrangler/cache/cf.json`. This is wrangler's own cache.
  `.gitignore` ignores `.wrangler/`, but gitignore cannot act on a path that
  is already tracked. Nothing reads it.

Both are deleted from git. The new suite
`tests/generated-not-tracked.bh-5518-test.sh` makes the next leak red:

- G1: `git ls-files -ci --exclude-standard` is empty.
- G2: no tracked file other than `*.md` has, in its first 5 lines, both a
  `GENERATED` line and a `do not commit` line.

The suite runs `git -C "$ROOT" ls-files` with no pathspec, so
`bin/test-impact.sh always` lists it (the BH-4551 signal). It runs on every PR
with no edit to `catalog/test-impact-always.txt`.

`GNT_ROOT=<dir> bash tests/generated-not-tracked.bh-5518-test.sh` runs only G1
and G2 against `<dir>`. A `<dir>` with no `.git` is indexed into a throwaway
repo, so its contents are the tracked set.

## Not changed

Committed renders (`rules/CLAUDE.md`, `docs/PR-OWNERSHIP.md`) stay committed.
They say GENERATED but not "do not commit", so G2 does not flag them.
