# Model routes: seed lint, empty-remove tombstone, in-batch audit, bundle deadline

Doc: MODEL-ROUTES

## What changed

BH-1928 closes four follow-ups from the #1917 (BH-1572) review.

- **Seed changes to an existing role are linted.** Every `model_routes` seed in
  `worker/jobs/schema.sql` skips a role with hub audit history, and most live
  roles have some, so a seed edit for one of them only reaches a fresh
  database. `bin/model-route-seed-lint.sh` runs in CI's `lint` job on every PR.
  It fails when a role already in the base seed has different rungs at HEAD,
  unless the same diff ships the audited PUT (a changed `bin/` or `scripts/`
  file whose code makes a PUT call to `/api/model-routes` and names the role;
  reading the API or mentioning a PUT in a message is not enough) or carries
  `seed-only: fresh-db` in the PR body or on an added schema.sql line. New
  roles pass. rc 2 means it could not run.
- **An empty hub remove writes a tombstone.** `POST /api/model-routes/remove` on
  a role with no hub rows used to write nothing, so the next deploy re-seeded
  it. It now writes one audit row at position 0 with every before/after column
  NULL and answers `tombstone: true`. The MODELS history table labels that row
  "removed" (it used to label any before-NULL row "added").
- **remove and reset audit what they deleted.** Both used to read the rungs
  outside their batch. The audit rows are now an `INSERT … SELECT` in the same
  batch as the DELETE, and `removed` is the DELETE's own row count.
- **The route bundle has one total deadline.** `model_routes_bundle` had only a
  4 s cap per ask, so a slow worker that still answered could add about 68 s
  to a pool tick. `MODEL_ROUTES_BUNDLE_DEADLINE_S` (lib knob `model-route`,
  settings row `lib.model-route.model_routes_bundle_deadline_s`, default 15 s)
  bounds the whole build. Each ask gets the smaller of the per-ask cap and what
  is left. Once it is spent, the rest come from the cache and
  `logs/model-route.log` says so.

## Not changed

The PUT still reads its `before` values outside its batch. It uses them for
the keep/confirm decision, and the ticket named only remove and reset.
