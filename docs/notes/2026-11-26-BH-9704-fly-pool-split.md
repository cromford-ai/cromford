# 2026-11-26 BH-9704 C1: the Fly pool script is a declared split

What changed:

- `bin/render-split.sh` reads an optional 4th field in a `catalog/splits.d/*.tsv`
  row: the fragment extension, `txt` (the default) or `sh`. The name rule, the
  merge guard's side render and `--cut` use the row's extension. A 5th field, or
  any other extension, is rc 2.
- `catalog/splits.d/bh-9704-fly-pool.tsv` registers `bin/fly-pool.sh` as the
  render of `config/fly-pool.d/`, mode 755, extension `sh`.
- `docs/verification-map/index/tail.md` declares `bin/fly-pool.sh` as a
  committed Generated files row, command `bin/render-split.sh --write`.

Why: `bin/fly-pool.sh` was already a render of `config/fly-pool.d/` (BH-7454),
but it was not a Generated files row. So two plans that each added one fly-pool
fragment both listed the render, and `plan-overlap`, `plan-sibling`,
`conflict-check` and `overlap-guard` deferred one of them. With the row, they
do not. The row uses render-split's `--write` because its merge guard refuses a
regenerate over a hand edit (rc 4); `bin/fly-pool-build.sh`'s guard seam is
still a placeholder (#8741).

No fragment and no byte of `bin/fly-pool.sh` changed. `bin/fly-pool-build.sh`
still works and renders the same bytes.

Tests: `tests/fly-pool-split.bh-9704-test.sh` (F1 golden to F7 not-deferred);
`tests/split-overlap.bh-9704-test.sh` takes `SO_*` env vars for the split it
proves. Remaining slices: C2 merge conductor, C3 blocked resolver, C4 CI workflow.
