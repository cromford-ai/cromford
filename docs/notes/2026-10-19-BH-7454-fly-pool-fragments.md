# bin/fly-pool.sh is a committed render of config/fly-pool.d/ (BH-7454, slice BH-7542)

Doc: FLY-POOL

## Gap

`bin/fly-pool.sh` is one 5371-line file that many tickets edit. It took 6
merges (14 commits) on 2026-10-19 alone. Two PRs that each add a function to it conflict on
the same hunks, so one of them waits for a rebase.

## What changed

- The change lands in two slices. The lead review limit is 367232 bytes, and
  the two fragments together are about 388 KB of diff (lead review
  lr-7779-c061a4c1ac5b, split-required). Slice C0 (BH-7542, PR #7779) is
  this note. Slice C1 (issue #8561) adds `2000-tail.sh`, the list-files row
  and the real-tree `--check` case.
- `bin/fly-pool.sh` is not edited by either slice. Its bytes do not change, and
  cron runs the same file on every box. After C1 it is a committed render.
- `config/fly-pool.d/` holds the inputs. The plan is two coarse fragments:
  `0100-head.sh` (line 1 to the line before the cut) and `2000-tail.sh` (the
  `# <<< pool terminal / spawn cap / hold gate` line to EOF). The cut is the
  start of the contiguous `#` block directly above `^QROW()`. C0 adds only
  `0100-head.sh` (lines 1 to 2371 of main on 2026-10-27). On the C0 tree
  `--check` reports stale, and nothing runs it until C1.
- `bin/fly-pool-build.sh --check | --write | --absorb` is the generator. The
  render is the `cat` of the fragments in `LC_ALL=C` name order. `--check` is
  rc 0 equal, rc 1 stale or a `bash -n` failure, rc 2 a bad name or usage.
  `--write` replaces `bin/fly-pool.sh` through a temp file in `bin/` and `mv`.
- Two seams, both placeholders: `bin/lib/fly-pool-build-guard.sh`
  (`fpb_merge_guard`, returns 0) and `bin/lib/fly-pool-build-absorb.sh`
  (`fpb_absorb`, prints `fly-pool-build: --absorb is not built yet (BH-7454.3)`
  and returns 2).
- Slice C1 adds a `rendered config/fly-pool.d/` row for `bin/fly-pool.sh` to
  `catalog/list-files.tsv`. From then on `bin/list-file-lint.sh` refuses a PR
  that grows `bin/fly-pool.sh` with no add or edit under `config/fly-pool.d/`.
- `bin/state-paths-guard.sh` skips an added `config/fly-pool.d/*` file. The
  guard checks only ADDED scripts, and an edit of an existing writer such as
  `bin/fly-pool.sh` is not checked by design. A fragment is the source of that
  file, so an added fragment is the same thing as an edit of it. Without the
  arm, the cut itself was refused (`0100-head.sh:241: writes state/pool`, a
  byte copy of a `bin/fly-pool.sh` line). The arm is narrow: other `config/`
  dirs and every `bin/` path are still checked.
- `tests/fly-pool-split.bh-7542-test.sh` pins the order, the name rule, the
  rc map, the lint row (on a fixture catalog) and the guard arm. In C0 its
  scratch trees use the real `0100-head.sh` and a fixture tail. C3 checks that
  `0100-head.sh` is a byte prefix of `bin/fly-pool.sh` at the commit that last
  wrote `0100-head.sh`, so a sibling edit of `bin/fly-pool.sh` does not make
  it red.

The fragments are synced to boxes by `bin/harness-sync.sh` with the rest of
`config/`. They are data there: nothing runs `config/*.sh`.

## The cut command

History of slice C0. Slice C1 (BH-8740) did not land `2000-tail.sh`: it cut
the tail into 20 fine fragments in the same PR (see
`docs/notes/2026-10-28-BH-8740-fly-pool-tail-cut.md`). Do not run this
command now. To edit `bin/fly-pool.sh`, follow `config/fly-pool.d/README.md`.
As written for C0:

```bash
f=bin/fly-pool.sh; q=$(grep -n '^QROW()' "$f" | head -1 | cut -d: -f1); s=$q
while [ "$s" -gt 1 ] && sed -n "$((s-1))p" "$f" | grep -q '^#'; do s=$((s-1)); done
mkdir -p config/fly-pool.d
head -n $((s-1)) "$f" > config/fly-pool.d/0100-head.sh
tail -n +"$s" "$f" > config/fly-pool.d/2000-tail.sh
```

After slice C1 merges, an open PR that edited `bin/fly-pool.sh` by hand goes
red on the lint and on `tests/fly-pool-split.bh-7542-test.sh` C1. To fix it,
merge main, run the cut command, and commit the two fragments. Until then, an
edit of `bin/fly-pool.sh` needs no fragment change; C1 re-cuts the head.

## How to add an entry

1. Write the new code in `config/fly-pool.d/NNNN-bh-<n>-<name>.sh`. NNNN sits
   between the two fragments it must render between, for example
   `1950-bh-9001-alpha.sh`.
2. Run `bin/fly-pool-build.sh --write`.
3. Commit the fragment and `bin/fly-pool.sh` together.

`config/fly-pool.d/README.md` has the full format.

## Planned children of #7454

- Merge guard (issue #7543, seam owner BH-7454.2): `fpb_merge_guard` refuses a
  `--write` that would drop a hand edit.
- Absorb (issue #7544, seam owner BH-7454.3): `--absorb` moves a hand edit of
  `bin/fly-pool.sh` into the fragments.
- Fine cuts (issues #7545 and #7546): replace the two coarse fragments with one
  fragment per function block.
