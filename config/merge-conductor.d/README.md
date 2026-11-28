# config/merge-conductor.d/ — the fragments of bin/merge-conductor.sh

`bin/merge-conductor.sh` (the merge conductor driver) is a committed render of
this directory (BH-10226). Its registry row is
`catalog/splits.d/bh-10226-merge-conductor.tsv`.

Do not confuse this directory with `bin/merge-conductor.d/` (BH-7453). That
one holds optional conductor libs that the driver SOURCES at run time. This
one is the SOURCE of the driver file itself.

- The render is the `NNNN-<slug>.txt` files concatenated verbatim in LC_ALL=C
  name order. This README is not part of it.
- Most fragments are slices of the `pr_worker` function body. One fragment
  alone is not valid bash and need not be; the render must pass `bash -n`.
  The `.txt` extension keeps them out of `*.sh` scans.
- Edit a fragment, then run `bin/render-split.sh --write bin/merge-conductor.sh`,
  and commit both. Never edit `bin/merge-conductor.sh` by hand:
  `bin/render-split.sh --check` and CI refuse the drift, and the conductor's
  regenerate refuses to write over it (rc 4).
- A new block is a new fragment numbered between its neighbours:
  `2950-<slug>.txt` goes between `2900-...` and `3000-...`.
- A fragment must be non-empty and end in a newline.
- A new optional lib still goes in `bin/merge-conductor.d/` as its own file
  (`catalog/list-files.tsv`); only its call site goes in a fragment here.

## How the fragments were cut

Each fragment starts at the first line of a comment block (a line that matches
`^ *# ` after a line that does not), once the fragment before it has 60 lines
or more. The slug is that comment line. The cut is deterministic.

## Re-cut (only when main moved before this split merged)

```bash
rm config/merge-conductor.d/[0-9]*.txt
bin/render-split.sh --cut bin/merge-conductor.sh --min-lines 60 --at '^ *# '
bin/render-split.sh --check
```
