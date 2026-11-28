# 2026-11-26 BH-10226 (C2 of #9704): the merge conductor is a declared split

What changed:

- `bin/render-split.sh --cut` takes an optional `--at <ERE>`. With it, a
  fragment starts at a block start: a line that matches the ERE when the line
  before it does not, once the current fragment has `--min-lines` lines. The
  slug comes from that whole line. Without `--at`, the cut is the same as
  before (`# >>> ` markers). `--at` with another mode, or with an empty value,
  is rc 2. A bad ERE is rc 2 and writes nothing.
- `config/merge-conductor.d/` holds 53 `NNNN-<slug>.txt` fragments and a
  README. They were cut once with
  `bin/render-split.sh --cut bin/merge-conductor.sh --min-lines 60 --at '^ *# '`.
  The largest fragment has 115 lines.
- `catalog/splits.d/bh-10226-merge-conductor.tsv` registers
  `bin/merge-conductor.sh` as the render of `config/merge-conductor.d/`, mode 755.
- `docs/verification-map/index/tail.md` declares `bin/merge-conductor.sh` as a
  committed Generated files row, command `bin/render-split.sh --write`.

Why: three open PRs at a time edit `bin/merge-conductor.sh` (3,631 lines).
Plan-overlap, plan-sibling, conflict-check and overlap-guard deferred any two of
them, and their hunks conflicted. The plain `# >>> ` cut gave only 3 fragments,
one of about 3,320 lines (the `pr_worker` function is 2,188 lines), so it
removed no collision. The comment-block cut gives 53 fragments.

No byte of `bin/merge-conductor.sh` changed. To change the conductor, edit a
fragment and run `bin/render-split.sh --write bin/merge-conductor.sh`. An open
PR that edited the driver by hand is red on `bin/render-split.sh --check`
until its edit moves into a fragment. Do not confuse `config/merge-conductor.d/`
with `bin/merge-conductor.d/` (optional libs the driver sources, BH-7453).

Tests: `tests/merge-conductor-split.bh-10226-test.sh` (C1 golden to C6
not-deferred, M1 and M2 mutants). Remaining slices: C3 blocked resolver, C4 CI
workflow.
