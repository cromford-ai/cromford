# Reserve migration numbers before a build writes one (BH-7325)

Doc: LEAD-REVIEW, RUN-BUILD-GRAPH, DB-COORDINATION-SPEC

## What changed

A build in a project with numbered migrations (`<dir>/NNNN_<name>.sql`) now
gets its number from the harness before the plan is written, and the
pre-review self-check refuses a PR that adds a number someone else holds.

1. **Allocator.** `bin/lib/migration-number.sh` computes a floor: 1 + the
   highest NNNN on `origin/main` and in the files every open PR adds
   (`repos/<slug>/pulls?state=open`, then `pulls/<n>/files`; status `added` or
   `renamed`, at most 3 pages each). Gaps are never filled.
2. **Reservation.** `POST /api/migration-numbers/reserve` (jobs worker,
   `worker/jobs/src/routes/migration-numbers.js`) returns
   `max(floor, highest reserved number + 1)` in one upsert statement, so two
   builds that start in the same minute get two numbers. One row per
   (project, ticket key). A rebuild keeps its number unless the floor passed it.
3. **Plan stage.** `bin/lib/rb/plan.sh`, block `migration number note
   (BH-7325)`, runs before the pre-plan adoption and the CC plan call. It puts
   one sentence into the plan prompt (`MIGRATION NUMBER (BH-7325): ... name it
   <dir>/<n>_<name>.sql ...`), writes `$BUILD/migration-number.txt` and logs a
   `migration-number: MIGRATION_NUMBER: ...` line to `pipeline.log`.
4. **Review check.** Self-check rule `migration-number`
   (`catalog/pr-self-check.d/bh-7325-migration-number.tsv`, mode `refuse`). It
   runs wherever the self-check runs: the builder's pre-open check and the
   lead-review enqueue. Messages: `migration number 0158 taken by main
   (prisma/sql/0158_agent_tool_call.sql); next free: 0164` and `migration
   number 0164 taken by #1149 (<path>); next free: ...`. The PR itself (the
   local branch, the head sha) is excluded. If the open PRs cannot be read, the
   rule writes one NOTE and checks main only.
5. **CLI.** `bin/migration-number.sh floor <project>`, `reserve <project> <key>`
   (a second migration of one ticket uses `<KEY>.2`) and `taken`.

## Why

On 2026-10-17 builders on example-org/project-6 picked a taken number five times
(#1140, #1149, #1150, #1173, #1178). Each read only main's `prisma/sql/`. Each
collision cost a rename and a review round. `tests/migration-number.bh-7325-test.sh`
replays the five: each now gets a free number (0149, 0164, 0165, 0167, 0168).

## Who is affected

Only a project with a `migrations_glob.<project>` settings row and at least one
numbered file on main. On 2026-10-17 that is `project-6-os`
(`prisma/sql/*.sql`). Every other project sees no prompt line, no reservation
and no rule finding.

## Knobs and kill switches

- `MIGRATION_NUMBER_RESERVE=0` (env of the build) turns the plan-stage
  reservation and the prompt sentence off. Unset means on.
- The catalog row's mode: set `note` or `off` in
  `catalog/pr-self-check.d/bh-7325-migration-number.tsv` to stop the refusal.
- `migrations_glob.<project>`: delete the row and the project leaves both.

## Failure semantics

- Worker down, no `JOBS_URL`, or a 503: the number is the floor, the line says
  `unreserved`, and the prompt sentence says the number is NOT reserved. The
  build goes on.
- GitHub read failed: `incomplete=<why>` in the line; the floor comes from main
  and the reservations. The review rule refuses only on what it read.

## Store and retention

D1 table `migration_reservations` (schema fragment
`worker/jobs/schema.d/202610211920-bh-7325-migration-reservations.sql`),
primary key `(project, number)`, unique index
`idx_migration_reservations_ticket (project, ticket_key)`, index
`idx_migration_reservations_at (reserved_at)`. Retention rule
`migration_reservations.age` deletes rows older than
`retention.migration_reservations.days` (seed 30) in the hourly
`bin/d1-retention.sh` lane; `retention.dry_run` applies. A row is a short
claim, not history, so it is deleted, not archived.

## Known gap

A plan adopted from a pre-plan skips the CC plan call, so it does not see the
sentence. The reservation is still made, and the review rule catches a
collision.
