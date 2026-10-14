# The worker route-table fixture is one fragment per route family

Doc: WORKER-JOBS

## What changed

`worker/jobs/test/route-table.test.js` kept the pre-split chain as one 220-line
`CHAIN` array. It now reads `worker/jobs/test/route-table.d/<NNN>-<family>.txt`,
one file per `src/routes/<family>.js` (53 files, 169 routes). `CHAIN` is their
concatenation in file-name order and is exactly the list it was, entry for
entry; every assertion runs against it unchanged. The three-digit prefix is the
cross-family order, spaced by ten.

Two checks are new: every file in the directory must be an `<NNN>-<family>.txt`
fragment with its own number, and each fragment must equal the routes its
family module exports, in order — so a route filed under the wrong family is
named, not just reported as a shifted index.

## Why

The array was touched by 20 commits between 2026-09-21 and 2026-09-24. Route PRs
for unrelated families spliced into the same region (BH-1942, BH-1607 and
BH-1381 each went "directly under the hub lease"), so they conflicted on a hunk
none of them was about. Now a route PR edits only its own family's fragment,
which it can only collide on with a PR that also edits that family's module.

## Adding a route

Put its signature in its family's fragment, where the module puts it. A new
family is a new fragment whose number sits between the neighbours that
`src/index.js` puts it between.
