# BH-9704: the PLAN-stage lib is a render of a fragment folder

Doc: BUILD-CONCURRENCY, MERGE-CONDUCTOR

## Why

`bin/defer-report.sh --last 7d --project cromford --top 40`, run over
the hub's 500 parked build rows (2026-11-10T22:18Z to 2026-11-14T14:12Z),
printed `builds=500 deferred=92 attributed=55 other=37`. The top files that
are lists or hubs (counted as top-level `# >>> <name>` blocks, or a CI job
list):

| # | file | deferrals | slice |
|---|---|---|---|
| 1 | `bin/lib/rb/plan.sh` | 21 | C0 (this change) |
| 2 | `bin/fly-pool.sh` | 14 | C1 |
| 3 | `bin/merge-conductor.sh` | 4 | C2 |
| 4 | `bin/blocked-resolver.sh` | 3 | C3 |
| 5 | `.github/workflows/harness-ci.yml` | 1 | C4 |

`bin/lib/gh-cache.sh` (2 deferrals) is not a list or a hub and is not split.

## What changed

- `bin/render-split.sh` is a generic renderer. A split registers itself with
  its own file `catalog/splits.d/<key>-<name>.tsv`: one row
  `<render path> TAB <fragment dir>/ TAB <octal mode>`. `--check` renders
  every row and compares it with the committed file. `--write` writes the
  render. Print writes one render to stdout. `--cut <render> --min-lines <n>`
  makes the fragment dir from the committed file once.
- The merge guard of `--write`. During a merge, a cherry-pick or a rebase
  stop, or on a merge commit, each side that changed the render since the
  merge base must hold a fragment dir whose render is that side's render.
  Else `--write` writes nothing and exits 4. A render whose bytes already
  equal the fragments' render is never refused: that write drops nothing. So
  a fix round that moves a hand edit into a fragment gets rc 0 on the merge
  commit, and so does `--write` on a checkout whose HEAD is a merge commit
  with a pre-split side.
- `bin/lib/rb/plan.sh` is now the render of `config/rb-plan.d/` (24
  `NNNN-<slug>.txt` fragments, `--cut --min-lines 60`). Its bytes did not
  change.
- `docs/verification-map/index/tail.md` declares `bin/lib/rb/plan.sh` as a
  committed Generated files row, last in the table. So the overlap scripts
  no longer defer two builds on it, and the conductor runs
  `bin/render-split.sh --write` after each rebase.
- `catalog/list-files.tsv` has a `rendered config/rb-plan.d/` row, so
  `bin/list-file-lint.sh` refuses a PR that grows the render with no
  fragment edit.
- The CLAUDE.md union command runs `bin/render-split.sh --check`.

## Why the fragments are `.txt`

The share mirror refuses every file whose extension is not in `TEXT_EXT`
(`bin/share/mapping.py`; `bin/share/leakcheck.py` reports it as an
un-auditable non-text file). The first build of this change named the
fragments `.part`, and the built mirror was refused on all 24 of them.
`.txt` is already in `TEXT_EXT`, so no share file changes.
`tests/render-split.bh-9704-test.sh` R13 pins this.

## Open PRs that edit the render by hand

When such a PR is rebased, the guard refuses the regenerate.
`mc_regen_generated` logs `regenerate FAILED: bin/render-split.sh --write`
and keeps the PR's edit. The PR's CI is red on `bin/render-split.sh --check`
until a fix round moves the edit into a fragment. A red PR is the intended
outcome. A dropped edit is not.

## How to add a split

1. Add `catalog/splits.d/<key>-<name>.tsv` with one row.
2. Run `bin/render-split.sh --cut <render> --min-lines <n>`.
3. Run `bin/render-split.sh --check`.
4. Add the Generated files row (`committed`) and the `catalog/list-files.tsv`
   row. The union command needs no new line.
