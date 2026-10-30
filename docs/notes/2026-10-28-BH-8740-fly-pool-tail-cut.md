# The fly-pool fragment set is complete (BH-8740: slice C1 plus the fine tail cut)

Doc: FLY-POOL

## Gap

Slice C0 (BH-7542, PR #7779) added `config/fly-pool.d/0100-head.sh`, the
generator and the seams. The tail had no fragment, so `bin/fly-pool-build.sh
--check` reported stale, and nothing kept `0100-head.sh` in step with
`bin/fly-pool.sh`. Issue #8561 was to add a coarse `2000-tail.sh`, and issue
#7546 was to cut that file again into 20 fine fragments. That is two byte
moves of the same tail. BH-8740 does both in one PR.

## What changed

- `0100-head.sh` is re-cut from `bin/fly-pool.sh` on main 8381f5e9 (lines 1
  to 2418).
- The tail (lines 2419 to 6205) is 20 fine fragments, `2000-qrow-and-machine-io.sh`
  to `3900-spawn-loop.sh`. `config/fly-pool.d/README.md` lists each one and
  what it holds. `2000-tail.sh` never lands.
- Each fragment starts at its `# >>>` marker, or at the contiguous `#` block
  above its function definition. `3900-spawn-loop.sh` starts at the SECOND
  `# >>> machines rows (BH-1035)`; the first one is in the head.
- `bin/fly-pool.sh` does not change. The `LC_ALL=C` cat of the 21 fragments is
  byte-equal to it, and `bin/fly-pool-build.sh --check` is rc 0.
- `catalog/list-files.tsv` holds the `bin/fly-pool.sh` row
  (`rendered config/fly-pool.d/`). From now on `bin/list-file-lint.sh` refuses
  a PR that changes `bin/fly-pool.sh` with no change under `config/fly-pool.d/`.
- `tests/fly-pool-split.bh-7542-test.sh` now checks the real tree (C1), and its
  scratch trees copy the real fragments (C2, C4) and the real catalog (C8).
  `tests/fly-pool-cut-tail.bh-8740-test.sh` pins the fine cut.

## What an open PR that edits bin/fly-pool.sh does now

It goes red on the lint and on the C1 case. Make the same edit in the fragment
that holds the lines, then run `bin/fly-pool-build.sh --write`. The README has
the steps.
