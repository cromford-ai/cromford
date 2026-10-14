# Scratch trees copy a script's source closure, not a hand list (BH-4552)

Doc: tests/README.md

## What was wrong

Suites that build a scratch harness copied "the libs this lane sources" by
name. Each list was right on the day it was written and went red in the merge
queue the first time the lane sourced one more file:

- #4242 D9 copied `bin/lib/*.sh` and missed the new `bin/lib/tracker/`.
- #4002's switch fixture did not install the new `bin/lib/pr-owner/` libs.
- #4415 left `bin/lib/deployment.sh` out of `main-red-bisect-p1-confirm` and
  `extra-usage-loud`, which run their lane under `env -i`.

## What changed

`tests/lib/scratch.sh` has two new functions.

- `scratch_closure_list <repo-rel-script>` prints the script, then every
  `bin/lib` file it sources, transitively, sorted.
- `scratch_install_closure <repo-rel-script> <dest-root>` copies that list to
  `<dest-root>/<rel>` with `cp -p` and prints what it copied.

Return codes: 0 ok; 1 when a source line names a literal file that resolves
nowhere (stderr says which file and which path, and nothing is copied); 2 for
an empty, absolute, `..` or nonexistent script, or a dest outside `SCRATCH`.

**No-clobber.** A file already at the destination is kept. Write your stubs
first, then call the helper, and the stubs win.

**Only `bin/lib` files join.** Other `bin/*.sh` a lane runs or sources (the
`bin/jobs-client.sh` stub most suites write) are not copied. Copy those
yourself.

### How it reads a file

It looks at three kinds of non-comment lines: `.`/`source` statements, `for x
in …` lists, and `NAME=` assignments. Each `.sh` word on them is cut after the
last `}`, `)` or `$NAME` that comes before a `/`, so `$(dirname "$0")/lib/x.sh`,
`${HARNESS:-/root/harness}/bin/lib/x.sh`, `"$dir/x.sh"` and
`${X-$(dirname …)/x.sh}` all come down to a relative tail.

- `bin/…` resolves from the repo root. `lib/…` resolves from the sourcing
  file's directory, then `bin/`. Anything else resolves from the sourcing
  file's directory, then `bin/lib/`, then `bin/`.
- A `NAME=` whose value cuts to a literal directory (`MC_LIB_DIR=…/mc`) is
  remembered, and `"$NAME/x.sh"` later in the same file is tried as `mc/x.sh`
  first.
- A `$` or `*` in the last segment is a glob. It is used only when the segment
  has a literal part (`fc-$lane.sh` → `fc-*.sh`) or sits under a `bin/lib`
  subdirectory (`tracker/$a.sh` → `tracker/*.sh`). A bare `$mod.sh` never
  expands to all of `bin/lib`.
- "Missing" is only the operand of a `.`/`source` with a literal tail that no
  rule finds. An assignment or `for` candidate that does not resolve
  (`${HARNESS_DEPLOYMENT_FILE-}`) is skipped.
- Words are split on whitespace and quotes, so a path with a space in it is
  not supported. `bin/lib` has none.

`SCRATCH_CLOSURE_REPO` points the helper at another repo. Only
`tests/scratch-install-closure.bh-4552-test.sh` uses it, for its synthetic repos.

## Migrated suites

- `tests/main-red-bisect-p1-confirm.bh-4318-test.sh`
- `tests/extra-usage-loud.bh-3985-test.sh` (its `ln -sf` links and stubs are
  written first, so they are kept)
- `tests/switch-convert-scripts-a.bh-2409-test.sh` (`swf_setup`'s
  `lane-gate.sh`, `lane-switch.sh` and stub `jobs-client.sh` are kept)

The other suites that copy from `bin/lib` are grandfathered. `#4242 D9` in
`tests/context-pack.bh-3494-test.sh` copies all of `bin/lib` on purpose to
build a tree minus one lib, so it is not a hand list and was not touched.

## The lint

`tests/scratch-closure-lint.bh-4552-test.sh` runs in delta mode
(`tests/lib/ratchet-delta.sh`). It goes red when a diff raises a suite's count
of hand-copy lines: a `cp` or `install -…` naming `bin/lib/<x>.sh`, a `for … in
… .sh …` loop that copies from `bin/lib/`, or `swf_install` of a `bin/lib/`
file. A suite that copies one lib to unit-test it directly opts out with

    # scratch-closure-allow: <reason>

An empty reason is still red. Out of scope: trees built with `git archive`.

The lint is not in the always-run set, because that set needs a CI-measured
row in `catalog/ci-suite-durations.tsv` and this suite has no CI run yet. It
names `"$DIR/tests/"` as a directory, so `bin/test-impact.sh` selects it for
any diff that touches a suite, and the merge-queue batch runs it with the rest
of the corpus.
