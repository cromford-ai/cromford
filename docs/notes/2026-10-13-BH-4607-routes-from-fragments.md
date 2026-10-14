# Jobs-worker route families register through their fragment (BH-4607)

Doc: worker/jobs/README.md

## What changed

- `worker/jobs/src/index.js` no longer imports or spreads the 122 gated route
  families. It imports `ROUTES` from `#routes`. It still imports the four open
  families (webhooks, ci-durations, ci-test-tiers, suite-results) and builds
  `OPEN_ROUTES` itself, because those routes sit in front of the bearer.
- `ROUTES` is the `routes` lists of the families in
  `worker/jobs/test/route-table.d/`, in fragment-name order. The pure composer
  is `worker/jobs/src/lib/route-families.js`.
- `worker/jobs/package.json` maps `#routes` to `./src/routes.gen.js` under
  `workerd` and to `./test/lib/routes.node.js` under `default`. This is the same
  split as `#schema-sql` (BH-4987).
- `src/routes.gen.js` is git-ignored. `worker/jobs/scripts/routes-build.mjs`
  renders it. `wrangler.jsonc` runs that script as `build.command` before every
  bundle, so `bin/harness-sync.sh` needs no change. A refused fragment (a stray
  name, a shared number, a shared family, a fragment with no module) gives one
  `routes-build:` stderr line and exit 1, so `wrangler deploy` fails and
  harness-sync's existing deploy-failed ALERT fires.
- Node reads the fragments at load time through `test/lib/routes.node.js`, so no
  test suite renders anything first.
- The table is row-for-row the same as before. The three empty seam families
  (lane-fleet, lane-runs-metrics, lane-snapshots) have no fragment, export no
  rows and so leave the table with 0 rows lost. Each one is registered when its
  fragment lands.

## Why

Every new route family edited `index.js` twice (one import, one spread). Two
unrelated route builds conflicted there (BH-2659 #2825, BH-3150 #3180). The
fragment already said the same thing.

## The rule now

A new gated family is `src/routes/<family>.js` plus
`test/route-table.d/<NNN>-<family>.txt`. Never edit `index.js` for it.
`worker/jobs/test/route-registry.bh-4607.test.js` (N4) fails if a gated import
or spread comes back. The `route-fragments` rules-pack row runs it on every PR.
