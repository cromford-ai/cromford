# Tests never write cost rows into the production cost_rows table (BH-3223)

Doc: COST

## What changed

Suites run directly on Fly pool machines had put `project=testproj` stub-runner
rows into prod D1 `cost_rows`. A pool machine's environment carries
`HARNESS_SECRET` and `COST_ROWS_BOX`, and `tests/lib/scratch.sh` left
`JOBS_URL` unset, which `bin/lib/jobs/req.sh` defaults to the live worker. So
`bin/agent-call.sh` → `cost_row_emit` POSTed every stub row.

- **`tests/lib/scratch.sh`** exports `JOBS_URL=` (empty: "no worker here") and
  unsets `HARNESS_SECRET` and `COST_ROWS_BOX`, so a suite on a pool machine
  sees what CI gives it. A suite that wants a stub worker sets `JOBS_URL` (and
  its own secret) after sourcing, as the stubbed suites already do.
- **`cost_row_emit`** (`bin/lib/cost-row.sh`) still appends the row to
  `cost.csv`, then POSTs nothing when `HARNESS_TEST_SANDBOX=1` or when the row's
  project is `testproj` (exact, case-sensitive).
- **`bin/cost-rows-push.sh`** under `HARNESS_TEST_SANDBOX=1`: mirror and push
  modes print `cost-rows-push: HARNESS_TEST_SANDBOX=1, refusing to POST
  (BH-3223)` on stderr and exit 0 with the cursor untouched. `--verify` only
  reads and still runs.
- **`_metric_cost_rows_chunk`** (`bin/lib/jobs/cost.sh`) skips a `testproj`
  row and still advances the cursor past it; `--verify` does not count it as
  owed.
- Suites that talk to a stub on purpose opt back in right after sourcing
  scratch.sh: five that assert a cost-row POST to their own loopback stub
  `unset HARNESS_TEST_SANDBOX`, and the ones whose fake curl answers a worker
  URL `export JOBS_URL=https://jobs.invalid`. A new suite that relied on the
  old unset-means-live default needs the same line.

## Owed (prod D1, not done from a build)

Count the existing rows and record the count on BH-3223, then delete them
(database name from `worker/jobs/wrangler.jsonc`):

    wrangler d1 execute harness-jobs --remote --command "SELECT COUNT(*) FROM cost_rows WHERE project='testproj'"
    wrangler d1 execute harness-jobs --remote --command "DELETE FROM cost_rows WHERE project='testproj'"

Then, 24h after the fleet syncs this change, the same count restricted to rows
written after the sync (`<sync time>` is when the box last pulled main) should
be 0:

    wrangler d1 execute harness-jobs --remote --command "SELECT COUNT(*) FROM cost_rows WHERE project='testproj' AND ts > '<sync time>'"
