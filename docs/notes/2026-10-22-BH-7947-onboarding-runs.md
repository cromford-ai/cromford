# BH-7947 (BH-7934.0): onboarding run create and read

What changed:

- New D1 tables `onboarding_runs` and `onboarding_steps`, fragment
  `worker/jobs/schema.d/202610220114-bh-7934-onboarding-runs.sql`. Three
  indexes: `idx_onboarding_runs_state_updated`,
  `idx_onboarding_runs_project_created`, `idx_onboarding_steps_run_ord`.
  Settings seed `onboarding_runs_retention_days` = `30`. The retention rule
  that reads it ships in BH-7934.2.
- New gated route family `onboarding` (`worker/jobs/src/routes/onboarding.js`,
  fragment `worker/jobs/test/route-table.d/bh-7934-onboarding.txt`):
  - `POST /api/onboarding/runs`: `Idempotency-Key` header required. The run id
    is `ob_` + the first 20 hex characters of sha256(key). The body fields
    `repo, project, tracker, box` are required; `prefix, base, prod` are
    optional. Every other field is dropped. One batch writes the run (state
    `queued`) and 7 queued steps. 201 on create, 200 on a replay with the
    same inputs, 409 `idempotency_key_reused` on a replay with other inputs.
  - `GET /api/onboarding/runs/<id>`: `{run, steps}`, the steps by `ord`.
  - `created_by` is the `x-harness-actor` header when it is well formed,
    else NULL.
- New seam `bin/lib/onboard-stations.sh`: comments only (owner BH-7934.1).

Why: the tracer for the onboarding UI (BH-7934). The runner, the stations,
the actions and the console screen are sibling tickets.

Tests: `worker/jobs/test/onboarding.bh-7934.test.js`,
`worker/jobs/test/onboarding-explain.bh-7934.test.js`,
`tests/onboard-stations-seam.bh-7947-test.sh`.
