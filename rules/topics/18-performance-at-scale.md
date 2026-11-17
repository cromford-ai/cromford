## Performance at scale (2026-11-17)

PERFORMANCE AT SCALE (iron law, 2026-11-17). The performance-by-default law (BH-6946) also binds a background job, sweep, queue worker and agent poll. Plan for the row count in 12 months.
PLAN, for a change to a database read, a list screen, a job or poll, or a queue table, states:
- each table it reads, and its expected row count in 12 months
- the index for each filter and sort (existing, or added here)
- which reads run in parallel
- a list screen's payload budget (default: 10,000 seeded rows under 300 KB)
- for an agent or vendor call, the check before the spend that the output is still needed
- for a mirror or backfill, the readers of each table it fills
EXECUTE:
- If package.json has a `test:perf` script, run it with the final checks. A new violation is a failing test.
- A migration that adds an index states its EXPLAIN at seeded volume in its header and the PR body.
- With Prisma, a partial index never names an enum column in its WHERE (Prisma sends a cast). Put the enum in the index key.
REVIEW, each a [NOTE]:
- a job or poll query with no index or no bound
- a plan with no 12-month row count
- a partial index on an enum column under Prisma, or index proof with SQL the ORM does not send
- one loading boundary around two or more independent read groups
- a queue table with no end state by age, or a screen that renders the full queue
- a draft LLM or vendor call with no still-needed check (no dedup before the spend stays `[BLOCK money]`)
REVIEW BLOCK: `[BLOCK perf-at-scale]` for a measured regression on a key screen over the speed thresholds. Also for an unbounded or unindexed read that this diff adds or changes, on a table the plan expects past 100k rows.
