# BH-5788: key-named fragments, and three lints for shared append points

Doc: VERIFICATION-MAP

## What changed

1. A new `worker/<w>/schema.d/` fragment is
   `<yyyymmddhhmm>-<ticket-key>-<name>.sql`: the UTC minute the builder creates
   it, then the lower-case ticket key. `bin/schema-build.sh` and
   `worker/jobs/test/lib/jobs-schema.js` accept
   `^([0-9]{4}|[0-9]{12})-[a-z0-9][a-z0-9_-]*\.sql$`. The sort is still plain
   `LC_ALL=C`, so every `NNNN-` fragment composes first and the stamp
   fragments follow in stamp order.
2. A new jobs-worker route family can take
   `worker/jobs/test/route-table.d/<ticket-key>-<family>.txt` next to the
   numbered `<NNN>-<family>.txt` fragments. `FRAG_RE` and `parseFragments` in
   `worker/jobs/src/lib/route-families.js` read both forms. A key-named
   fragment has no number. It sorts after every numbered one, and the render
   imports it as `f_<key>_<family>`. The module is still
   `worker/jobs/src/routes/<family>.js`. There is ONE route generator
   (#6520's `scripts/routes-build.mjs`); no second one is added.
3. Rules pack row `schema-fragment` (delta, `rp_schema_fragment`): an added
   `CREATE [TEMP|TEMPORARY|VIRTUAL] TABLE` line in a schema.d fragment that
   exists at the base is a finding. A new table goes in a new fragment.
4. Rules pack row `schema-fragment-name` (delta, `rp_schema_fragment_name`): a
   new fragment that reuses an `NNNN` number the base has is a finding. A
   stamp-form fragment must have a real UTC minute, and a stamp later than
   the newest stamp fragment of the same worker at the base. Any other name is
   a finding. A new `NNNN` fragment on a free number passes, and the
   self-check row `body-schema-stamp` (catalog/pr-self-check.tsv) notes it.
5. Rules pack row `discipline-dupes` (tree, `rp_discipline_dupes`): two
   `- **D<n> ` openers with one number in `prompts/build-discipline.md` are a
   finding. Gaps and order are not judged.
6. The plan prompt (`bin/lib/rb/plan.sh`, `bin/run-preplan.sh`) carries
   `th_fragment_rule` (`bin/lib/test-home-lib.sh`) after `th_plan_rule`. It
   names both fragment forms with the ticket's key, and prints only in a
   checkout with `worker/*/schema.d/`.

## Why

A picked "next free" number collides with the next build's pick. Main held two
`0022-` schema fragments on 2026-10-14 (`0022-bh-5561-staff-heartbeat.sql`,
`0022-bh-6047-lane-fleet.sql`). The ticket key cannot collide, and a stamp gives
the order without a shared counter.

## Commands

- `HARNESS_TEST_SANDBOX=1 bin/rules-pack.sh --tree . --base origin/main --only schema-fragment,schema-fragment-name,discipline-dupes`
- `HARNESS_TEST_SANDBOX=1 bin/schema-build.sh --check`
- `cd worker/jobs && node scripts/routes-build.mjs --print`
