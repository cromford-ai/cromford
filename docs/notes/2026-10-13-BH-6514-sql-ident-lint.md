# The SQL identifier ratchet and `sqlIdent` (BH-6514, slice BH-6521)

Doc: TESTING, OPERATING

## Why

D1 binds values, not names. A table or a column name goes into the SQL text
as part of the string. The worker builds that text at run time in about 190
places. Every name found so far comes from a code constant, but nothing checks
that, and nothing stops a new site that takes a name from a request.

## What changed

- `bin/sql-ident-lint.sh` is a ratchet over
  `git ls-files 'worker/*/src/*.js' 'worker/*/src/**/*.js'`.
- `worker/jobs/src/lib/sql-ident.js` exports `sqlIdent(name)`. It returns
  `name` when it matches `/^[A-Za-z_][A-Za-z0-9_]*$/`. Otherwise it throws
  `TypeError`.
- `worker/jobs/src/routes/registry.js` passes every table and column name
  through `sqlIdent` at its 4 sites, and each site carries a marker.
- `tests/fixtures/sql-ident-baseline/` holds one fragment for each source file
  that still has unmarked sites.
- `catalog/silence-markers.tsv` has a `sql-ident` row. A diff that adds a
  marker sends that line to the lead review, and `bin/marker-reason-lint.sh`
  refuses a marker with no reason.

## What a site is

A site is a `prepare(` call in code (not in a comment or a string, and not
`prepareStatement(`). Its first argument must do one of these:

- hold a template literal with `${`, at any depth;
- join operands with a `+` at depth 0, where 1 or more operands is not a
  literal (a string, a template without `${`, or a number).

`prepare("a " + "b")`, `prepare("LIMIT " + 5)` and `` prepare(`SELECT 1`) ``
are not sites.

## The marker

Write the marker in a `//` comment on the site's line, or in the run of
comment-only `//` lines that ends directly above the `prepare(` line:

```js
// sql-ident-ok: TABLES const (table, pk)
stmts.push(env.DB.prepare(`DELETE FROM ${sqlIdent(spec.table)} WHERE ${where}`)
```

The text after the marker must hold a word of 3+ letters. It names where the
text comes from. A blank line or a code line between the marker and the site
breaks the run. A marker in a string or a `/* */` comment does not count.

## The baseline

A fragment is `<path with / as __>.count.txt`. It holds one integer: the
number of unmarked sites that file may keep. A file with no fragment keeps 0.

- A file over its count is rc 1. The lint names the last sites of the file by
  line, because it cannot tell an old site from a new one.
- A count above the unmarked sites is a `NOTE` line, not a failure.
- A fragment whose source file is gone is a `NOTE` line, not a failure.

Never write a fragment by hand. Regenerate the whole directory from the repo
root with the recipe in the script header:

```bash
B=tests/fixtures/sql-ident-baseline; rm -f "${B:?}"/*.count.txt; mkdir -p "$B"
bin/sql-ident-lint.sh --print-baseline | while IFS=$'\t' read -r f n; do printf '%s\n' "$n" > "$B/$f"; done
```

A sibling slice that marks the sites of a file deletes only that file's
fragment. No two slices edit one fragment.

## Commands and exit codes

- `bin/sql-ident-lint.sh` scans the tree. The last line is
  `sql-ident-lint: <n> sites in <f> files, <m> marked, <u> unmarked, <b> within baseline, <r> over`.
- `bin/sql-ident-lint.sh --print` adds one row per site:
  `<path>:<line>`, `marked` or `unmarked`, and the first argument.
- `bin/sql-ident-lint.sh worker/jobs/src/routes/registry.js` scans one file.
- rc 0: no site is over. rc 1: 1+ sites are over. rc 2: bad arguments, a
  root that is not a git work tree, no `python3`, a missing FILE, a file that
  does not parse, or a bad fragment.

`tests/sql-ident-lint.bh-6514-test.sh` runs the lint on the real tree (case
L14), so the merge-queue corpus runs the ratchet. CI's `lint` job does not run
it yet. The checkout-hardening slice of BH-6514 adds that step.

## Known gaps

- `prepare(sql)`, where `sql` is a variable built on an earlier line, is not a
  site. A name that goes into such a string is not seen.
- The lexer reads a `/` after `)` or `]` as division. A regex literal there
  (rare) can make the lexer misread the rest of the file. An unterminated
  token is rc 2 with the file named, so the error does not pass silently.
- The removed Cloud code (BH-5239) had 13 sites when this lint was built.
  Those files were gone from main before this PR merged, so their baseline
  fragments were deleted with the regenerate recipe. When a later PR deletes
  a source file, the lint prints a `NOTE` for its fragment. Delete the
  fragment then.
- `sqlIdent` checks one identifier. `ORDER BY ${spec.order}` in `readAll` is
  a list (`position, project`), so it stays as text under the marker.

## Still owed

The connection to Aikido is not made. the operator decides it.
