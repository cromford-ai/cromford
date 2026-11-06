# Product board provenance (BH-8918)

This note records where the hosted product board came from. It also records
the rule that keeps its names our own.

## What we used

- We copied no code, text, schema, name or screen from another product.
- We read one Apache-2.0 project for its pattern only. We do not name it here.
- Each name in the hosted board is our own word, or a plain word for the thing.

## Rule for a new product noun

Every PR that adds a new product noun (a screen, a route, a table, a role, a
label a user reads) must carry a knockout-search note in its PR body. The note
gives three facts:

1. Where: the places searched (for example: a web search, the trademark
   register, the app stores, the package registries).
2. What: the exact words searched.
3. Result: what the search found, and why the noun is safe to use.

If the search finds a product of the same kind with that name, pick a
different noun.

## Enforcement

- `bin/name-guard.py` reads the lines a diff adds. It refuses a deny term
  outside an allow-listed path.
- `catalog/name-guard.d/` holds the lists. Each `*.txt` file other than
  `allow.txt` is a deny list. `allow.txt` holds the exempt paths.
- The rules-pack component `name-guard` (`catalog/rules-pack.tsv`) runs
  `tests/name-guard.bh-8918-test.sh` on every PR.
- The deny terms are written only in the files under `catalog/name-guard.d/`.
  To add a term, add a line to a deny list in the same PR as its reason.
