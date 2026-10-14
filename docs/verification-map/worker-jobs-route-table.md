# The jobs worker answers from a table, not a chain (BH-1195)

**What it is:** `worker/jobs/src/index.js` is the worker's ENTRY, and nothing
else; the gated ROUTE TABLE is built from `test/route-table.d` (BH-4607, below). Every handler lives in `worker/jobs/src/routes/<family>.js`
as a `[method, matcher, handler]` row; the shared half — constants, transition
graphs, `computeDora`, `computeAnchored`, `decorateLane`, the SQL the routes
bind — lives in `worker/jobs/src/lib/core.js`; the clock, the JSON response and
the bearer live in `worker/jobs/src/lib/http.js`; `worker/jobs/src/lib/router.js`
resolves a request against the table, first match wins.

**Why it exists.** Until BH-1195 all 104 routes were one flat
`if (path === … && req.method === …)` chain inside `fetch` — 3,497 lines in a
5,758-line file. Two builds touching two unrelated routes conflicted on the same
function; a reviewer could not see a route's edges without paging through the
ones above it; and nothing anywhere stated which routes the worker answers, so a
route could be dropped in a refactor and only a caller would find out.

**What the split does NOT change.** Every handler body moved VERBATIM — same
SQL, same validation, same status codes, same response keys — and the table
preserves the chain's ORDER, which is load-bearing: `GET /api/jobs/:id` sits
above `GET /api/jobs`, `GET /api/settings` above the `/api/settings/` prefix. The
bearer still sits between the two tables: `OPEN_ROUTES` holds exactly one route
(`/webhooks/github`, which carries its own HMAC), `ROUTES` is reached only after
`bearerOk`. Schema untouched.

**How an operator reaches it:** nothing to turn on. The table is read on every
request. Locally:

```sh
cd worker/jobs && npm test
```

**Two things about this table that are deliberate:**

- **Every matcher is DATA, never a closure** — a string, a list of strings, a
  `{ prefix }`, a `RegExp`, or a `{ re, not }`. That is the only reason
  `test/route-table.test.js` can read the whole table back and compare it, route
  for route, against the chain it came from. A closure would match just as well
  and prove nothing.
- **`{ re, not }` keeps a fall-through that looks like a bug.** The chain
  guarded the machine-detail regexp with `machineMatch[1] !== "observe"`, so a
  `PATCH /api/machines/observe` matched the regexp, failed the guard and fell
  through to the 404. The matcher returns `null` in that case rather than
  answering, which is the same behaviour and not an obvious one.

**How to drive it:**

| what | how |
|---|---|
| the table carries every route the pre-split chain answered, exactly once, in chain order (the fixture is the chain, extracted from `git show d5f53aa8:worker/jobs/src/index.js`) | `cd worker/jobs && node --test test/route-table.test.js` |
| `matchRoute` lands on the same handler the chain did, for the pairs whose order was load-bearing; `PATCH /api/machines/observe` still falls through | same file, `RESOLVES` and the fall-through case |
| every route still behaves as it did — the whole worker suite, driven through the real `fetch` handler | `cd worker/jobs && npm test` |
| wrangler still bundles the tree into ONE worker | `cd worker/jobs && npx wrangler deploy --dry-run --outdir /tmp/jobs-bundle` |

**Files it writes on a live box:** none. This is source layout; the worker's
rows and the boxes' files are exactly what they were.

**What must never regress:**

- **A new route is added to the table AND to the fixture.** The fixture is the
  record of what the worker answers; a route that appears in only one of the two
  lists fails `route-table.test.js`, which is the point.
- **The fixture is fragments, one per family (Lane E, 2026-09-24).**
  `worker/jobs/test/route-table.d/<NNN>-<family>.txt` holds the signatures of
  `src/routes/<family>.js` in order; the chain is their concatenation in name
  order, so the three-digit prefix is the cross-family order (spaced by ten, so
  a new family takes a free number between its neighbours). A route goes into
  its family's fragment — never a shared list every route PR edits. The suite
  also refuses a file that is not `<NNN>-<family>.txt`, two fragments with one
  number, and a fragment that is not exactly its family module's routes.
- **The order stays the chain's order.** Sorting `ROUTES` alphabetically, or
  keying the table on path, re-points routes whose overlap the order resolves.
- **Handlers stay out of `index.js`.** The file is the entry and the table; a
  body inlined back into it is the chain growing again, one route at a time.
- **The fragment IS the registration (BH-4607).** `index.js` lists only the
  four open families. `ROUTES` comes from `#routes`: under wrangler the
  git-ignored `src/routes.gen.js`, which `wrangler.jsonc`'s `build.command`
  renders with `node scripts/routes-build.mjs`, and under node
  `test/lib/routes.node.js`, which reads `route-table.d` at load time. A new
  family is `src/routes/<family>.js` plus its fragment, never an `index.js`
  edit, and a module with no fragment is not mounted (404). Verified by
  `cd worker/jobs && node --test test/route-registry.bh-4607.test.js` and
  `HARNESS_TEST_SANDBOX=1 bash tests/worker-routes-render.bh-4607-test.sh`.
