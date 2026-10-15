# Lead protected paths are read from the DB rows; the TSV is only a seed now (BH-4148, slice 4 of BH-4140)

Doc: MERGE-CONDUCTOR

## Why

BH-4146 put the protected-path globs in the `lead_protected_paths` table, with a
`GET`/`PUT /api/lead-protected-paths` route and a one-time seed from
`catalog/lead-protected-paths.tsv`. BH-4147 put the add/remove UI on SETTINGS →
PROTECTED PATHS. Nothing read the rows yet: a glob added there governed nothing,
and the `lead_protected_paths_extra.<owner>.<name>` settings row still added
globs. This slice makes the rows the only source.

## What changed

- `bin/lib/lead-authority.sh`: `_la_catalog`, `_la_committed`, `_la_extras` and
  the `LA_CATALOG` knob are gone. `_la_db_globs <owner/repo>` runs in the
  caller's shell and sends `GET /api/lead-protected-paths?repo=<owner/name,
  lowercased>` through `_jobs_req`. It keeps live rows of that repo only
  (`removed_at` null, a string glob with no whitespace), deduped, in `LA_GLOBS`,
  and says where they came from in `LA_GLOBS_SRC` (`db`, or `cache <path>`).
- `la_scope` is rc 0 with rows, rc 1 on a successful empty answer, rc 2 when the
  rows are unreadable. A read error is never "not governed".
- The last-good cache: every successful read, an empty one included, is written
  atomically (mktemp in the same dir, then `mv -f`) to
  `state/lead-authority/globs-<owner_name>.cache`. It answers only when the GET
  fails (an outage, a 404 from a worker without the route, a body whose `rows`
  is not an array, no jobs client loaded), and only while it is younger than the
  settings row `lead_protected_paths_cache_max_s` (digits, at least 60; fallback
  86400 s). Missing or older: rc 2. An empty `HARNESS` root means no cache.
- `la_decide` reads the rows once per decision; scope and match use the same
  read. Unreadable: rc 2 with `the protected paths of <slug> could not be read
  (jobs worker, no cache younger than <max>s)`, so nothing publishes. Every repo
  now costs that one GET. The mode and authority logic (BH-4145) is unchanged.
- Blast radius of an outage: if the jobs worker is down and a repo has no cache
  younger than the cap, `la_decide` is rc 2 for that repo
  whether it has rows or not. A repo that has never been read on a box has no
  cache. So a long outage
  holds every lead MERGE in the fleet, and `bin/lib/risk-tier.sh` rule 1 caps
  every repo at medium. `lead-verdict post` needs the same worker to write its
  row, so the outage already stops those posts.
- `_la_key`'s headroom is now 20 (`lead_authority_mode.`), not 27 (the retired
  extras key).
- `bin/lead-verdict.sh authority <repo>` prints
  `globs (lead_protected_paths, from db|cache <path>): N` and the globs. The
  committed/extras lines are gone. Unreadable rows exit non-zero.
- `bin/lead-review-precision.sh`: wording only. rc 2 was already a skip; it now
  logs `protected paths unreadable (jobs worker, no fresh cache); held:
  authority unchanged`.
- Renamed: `catalog/lead-protected-paths.tsv` is no longer read as protection by
  itself. Its lines (39 cromford globs; count them with
  `grep -c ^example-org/cromford catalog/lead-protected-paths.seed.tsv`) live on as
  `catalog/lead-protected-paths.seed.tsv` (the self-glob renamed to the new
  file), which `bin/lead-protected-paths-seed.sh` now reads. The seed script and
  `tests/lead-protected-paths-seed.bh-4140-test.sh` stay.
- The seed floor (added after review). The GET asks `all=1`, so it sees removed
  rows too. A seed glob with NO row for its repo, live or removed, is still
  protected (`LA_GLOBS_FLOOR`; `authority` prints `of which N have no DB row
  yet`). Why: the live probe on 2026-10-05 ~06:30Z answered `{"rows":[]}` for
  example-org/cromford with `all=1` too, so the BH-4146 seed never ran. Without
  the floor, merging this would have made cromford ungoverned, which fails
  open on the merge-gate files with no error. The floor also keeps a partial seed
  (35 of 39) or a reset D1 table from opening anything. A console remove still
  un-protects a glob, because the removed row is a decision. The file changes no
  answer only when every seed glob has a row. For cromford that is true
  only after step 1 of "After merge (operator)" below. Until then the floor
  protects `catalog/lead-protected-paths.seed.tsv`, so the gap is fail-closed.

## Operating it

- Add or remove a glob: SETTINGS → HUB → PROTECTED PATHS, or
  `PUT /api/lead-protected-paths {"repo","glob","op":"add|remove","added_by"}`
  with the `HARNESS_SECRET` bearer.
- See what is in force: `bin/lead-verdict.sh authority example-org/cromford`.
- The seed ran on the hub on 2026-10-12 at about 15:15Z: `added 39, already 0`.
  That run used the seed file of #4614 head 534ca4267. So production holds the
  OLD self-glob `catalog/lead-protected-paths.tsv`. It has no row for
  `catalog/lead-protected-paths.seed.tsv`. The read:
  `bin/lead-verdict.sh authority example-org/cromford` at 2026-10-14T10:07Z,
  and again at 10:31Z, rc 0, `from db): 39`. A diff of the 39 globs against the
  cromford lines of the seed file has 1 difference: the `.tsv` glob in
  production, the `.seed.tsv` glob in the file. The fix is the operator steps
  below. A fresh hub runs the seed once:
  `bin/lead-protected-paths-seed.sh`. Then
  `curl -s -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/lead-protected-paths?repo=example-org/cromford" | jq '.rows|length'`
  answers 39 (`grep -c ^example-org/cromford catalog/lead-protected-paths.seed.tsv`). Until then the seed floor protects the same 39 paths, but the
  console can't remove one, because there is no row to remove. Don't loop the
  seed: a re-run re-adds a glob the console removed.

### After merge (operator)

1. After this PR merges, add `catalog/lead-protected-paths.seed.tsv` on
   SETTINGS → HUB → PROTECTED PATHS. Or run `bin/lead-protected-paths-seed.sh`
   once on the hub. It adds only that 1 glob, because no row has been removed.
2. Then remove the `catalog/lead-protected-paths.tsv` row there. Do not remove
   it before the merge: until then main still reads that file.
3. Run `bin/lead-verdict.sh authority example-org/cromford`. It must print
   `from db): 39` and no `of which` line.
4. On each box, remove `/root/harness/catalog/lead-protected-paths.tsv`.
   `bin/harness-sync.sh` copies without `--delete`, so the old file stays.
   No code reads it.

## Rollback

Revert this PR. The TSV and the extras row come back with it.

## Probe before merge

On 2026-10-13 at 17:42Z, `_jobs_req GET "/api/lead-protected-paths?repo=example-org/cromford&all=1"`
returned rc 0 with 39 rows, 39 live. This PR must not merge unless the same
probe shows 39 live rows.

## Follow-ups (out of this slice)

- `console-ui/src/screens/Settings.js` and `console-ui/src/ui/ProtectedPaths.js`
  still say the lead lane reads `catalog/lead-protected-paths.tsv`. That text is
  false after this PR. This slice does not edit `console-ui/` (#6663).
- `la_scope` and `la_globs` were a file read. Each call is now one jobs GET, with
  no in-process memo. The conductor calls them per row per tick (#6665).
- `PUT /api/lead-protected-paths {op:remove}` checks only the `HARNESS_SECRET`
  bearer. Any holder of that secret can remove a row. Before this PR a committed
  glob could only go through a PR to a protected file. The seed floor does not
  restore a removed row: `_la_db_globs` asks `all=1`, so a removed row counts as
  a decision and `_la_seed_floor` skips its glob. `bin/lib/risk-tier.sh` rule 1
  reads `la_globs` in every mode. So a removal takes the glob out of the
  always-high rule now, under `lane`. Under `human` it also removes the human
  gate. A signed `op:remove` (#6664) fixes both. #6664 must ship before any
  `lead_authority_mode=human` switch on a governed repo.
- A jobs-worker outage holds lead merges on every fleet repo. With no cache
  younger than `lead_protected_paths_cache_max_s` (fallback 86400 s), the read
  is rc 2: `mc_enqueue_mergify` holds (rc 3) and risk-tier rule 1 caps at
  medium. This includes repos with no seed line and no row. #6695 tracks a
  fallback to "not governed" for a repo with no seed line and no successful
  read.
- `lead_protected_paths_extra` stays in the signed-key mirrors
  (`bin/lib/jobs/settings.sh`, `bin/protected-setting.sh`), because the worker
  still signs it. No reader uses it.

Proven by `tests/lead-authority-db.bh-4148-test.sh`. This rebuild (#4614 closed)
re-applies the `ticket/bh-4148-r2` design onto main.
