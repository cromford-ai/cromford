# config/fly-pool.d/ — the fragments of bin/fly-pool.sh (BH-7454)

`bin/fly-pool.sh` is a committed render. Do not edit it by hand. Edit the
fragments here, then run `bin/fly-pool-build.sh --write` and commit the
fragments and the render together.

## Format

- Each fragment is verbatim shell. The generator adds no banner and trims
  nothing.
- The render is the `cat` of every `[0-9][0-9][0-9][0-9]-*.sh` file here, in
  `LC_ALL=C` name order. The generator sets `LC_ALL=C` itself, so the order is
  the same in every caller locale (`x-y.sh` sorts before `x.sh`).
- A fragment name must match `^[0-9]{4}-[a-z0-9][a-z0-9-]*\.sh$`. `README.md`
  is the only other file allowed here. Any other name, a dotfile or a
  subdirectory is refused (rc 2).
- Each fragment must pass `bash -n` alone, must not be empty and must end in a
  newline.

The plan is two coarse fragments: `0100-head.sh` (line 1 up to the
`# <<< pool terminal / spawn cap / hold gate` line) and `2000-tail.sh` (from
that line to EOF).

## Adoption state

The fragments land in two slices, because together they are larger than the
review limit. Slice C0 (BH-7542, PR #7779) adds only `0100-head.sh`, the
generator and the seams. On that tree `--check` reports stale, and no lane, CI
step or suite runs it. Slice C1 (issue #8561) adds `2000-tail.sh` and the
`catalog/list-files.tsv` row. From then on, `bin/fly-pool.sh` is edited only
through the fragments. Until C1 merges, edit `bin/fly-pool.sh` as before; C1
re-cuts the head from the main of that day.

## A new entry

After slice C1, name it `NNNN-bh-<n>-<name>.sh`, where `<n>` is the ticket number and NNNN sits
between the two fragments the code must go between. Example: a function that
must render after `0100-head.sh` and before `2000-tail.sh` is
`1950-bh-9001-alpha.sh`. Code that must sit above `QROW()` uses an NNNN
between 0100 and 2000. Then run `bin/fly-pool-build.sh --write`.

`bin/state-paths-guard.sh` does not check a new fragment here (BH-7542): a
fragment is a source of `bin/fly-pool.sh`, an existing writer, and the guard
does not check an edit of an existing writer. A reviewer must read a new
`state/` write in a fragment as an edit to `bin/fly-pool.sh`.

## Verbs

- `bin/fly-pool-build.sh --check`: validate the names and `bash -n`, then
  compare the render with `bin/fly-pool.sh`. rc 0 equal, rc 1 stale or a
  `bash -n` failure, rc 2 a bad name, no dir or no fragment.
- `bin/fly-pool-build.sh --write`: the same validation, then the merge guard
  seam (`bin/lib/fly-pool-build-guard.sh`, owner BH-7454.2, issue #7543; today
  it lets every write through), then a temp file in `bin/`, `chmod 755` and
  `mv` over `bin/fly-pool.sh`.
- `bin/fly-pool-build.sh --absorb`: move a hand edit of `bin/fly-pool.sh` into
  the fragments (`bin/lib/fly-pool-build-absorb.sh`, owner BH-7454.3, issue
  #7544). It is not built yet: today it prints
  `fly-pool-build: --absorb is not built yet (BH-7454.3)` and returns rc 2.

## A hand edit of bin/fly-pool.sh, before --absorb exists

While there are only the two coarse fragments, re-cut them from the edited
file. Run this from the repo root:

```bash
f=bin/fly-pool.sh; q=$(grep -n '^QROW()' "$f" | head -1 | cut -d: -f1); s=$q
while [ "$s" -gt 1 ] && sed -n "$((s-1))p" "$f" | grep -q '^#'; do s=$((s-1)); done
mkdir -p config/fly-pool.d
head -n $((s-1)) "$f" > config/fly-pool.d/0100-head.sh
tail -n +"$s" "$f" > config/fly-pool.d/2000-tail.sh
```

Then `bin/fly-pool-build.sh --check` must print nothing and return rc 0.
