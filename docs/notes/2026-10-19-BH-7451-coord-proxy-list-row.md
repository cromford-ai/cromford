# BH-7451: the coord proxy is a list file

Doc: catalog/list-files.tsv

The hotspot lane counted 17 merge conflicts in 30 days on
`console-ui/functions/api/coord/[[path]].js` (measured at `3c6d2d042edb`).
Before BH-6487, a new write route was a row appended to its `WRITES` table.

## What was already done

BH-6487 (`ccede3f2`) split the table. The 37 rows in `WRITES` stay in the
file, and a new write route is a new file
`console-ui/functions/_lib/coord-writes.d/<NNNN>-<slug>.js`.
`console-ui/scripts/coord-writes-build.mjs` renders
`console-ui/functions/_lib/coord-writes.gen.js` from that directory. The render
is git-ignored. Node reads the directory through
`console-ui/tests/lib/coord-writes.node.js`. The steer route (BH-5839) moved
to a fragment in that change. The routes added since then (BH-6823, BH-6824,
BH-6825, BH-7243) are fragment files too.

## What this ticket adds

One row in `catalog/list-files.tsv`:

```
console-ui/functions/api/coord/\[\[path\]\].js	console-ui/functions/_lib/coord-writes.d/	...
```

`bin/list-file-lint.sh` now refuses a PR that makes the proxy grow and adds no
file under `coord-writes.d/`. The fix it prints is "put the new entry in its
own file under console-ui/functions/_lib/coord-writes.d/". The input kind is
`<dir>/`, so the PR must ADD a fragment. A PR that grows the proxy for a
reason that is not a route (new logic in `onRequest`) is also refused. Put
that logic in a `functions/_lib/` module.

`bin/hotspot-split-ticket.sh` reads the same catalog. It now counts the proxy
as `listed` and files no new split ticket for it.

## The escape

Both readers match a row with an unquoted bash `case "$F" in $G)`. In a glob,
`[[path]]` is a bracket expression, not literal text. The raw path does not
match the real file, and it does match a path such as `coord/p].js`. The row
escapes each bracket with `\`, so it matches only the literal path. The
catalog header now says: escape a `[`, `]` or `*` meant literally with `\`.

## Tests

`tests/coord-proxy-split.bh-7451-test.sh` runs the real lint in scratch repos.
It proves that two sibling branches that each add a fragment merge with no
conflict, that two that each append a `WRITES` row conflict and are each
refused, and that the render equals the table the proxy loads today.
