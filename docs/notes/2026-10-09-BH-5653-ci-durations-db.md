# CI suite durations go to a jobs worker table (BH-5653)

Doc: ci-durations

## What changed

- Three new D1 tables in `worker/jobs/schema.sql`. `ci_duration_runs` holds one
  row per accepted post, keyed on the CI run id and bound to the sha256 of its
  rows. `ci_suite_duration_samples` holds the newest samples per suite.
  `ci_suite_durations` holds their median, keyed on the suite path. The window
  is the settings row `ci_suite_durations.window` (1..15, code fallback 3).
- New routes `POST` and `GET /api/ci/suite-durations`
  (`worker/jobs/src/routes/ci-durations.js`). They are in `OPEN_ROUTES` and
  check their own bearer: `CI_DURATIONS_TOKEN` (CI's scoped token) or
  `HARNESS_SECRET`. A POST validates every row before it writes. The same run
  with the same rows answers `duplicate: true`. The same run with other rows
  answers 409. Both routes are `d1Guarded`.
- `bin/ci-durations.sh post --run-id <id> --timings-dir <dir>` posts one run's
  rc 0 timings. It is fail-open: it always exits 0, and a failure prints one
  `::warning::`.
- `bin/ci-durations.sh seed [--file F] [--dry-run]` imports a durations file,
  one POST per source run. The default file is the seed in git history.
- `bin/ci-durations.sh fetch` reads the worker first. The order is: the worker,
  then the box cache of its last usable answer, then the BH-5518 artifact
  chain, then the seed. An unusable answer never replaces the cache. When the
  worker is not configured, fetch sends nothing and reads no cache.
- New job `ci-timings` in `.github/workflows/harness-ci.yml`. It runs only on a
  Mergify batch whose shards all succeeded. It is `continue-on-error`, and no
  check in `.mergify.yml` names it. The plan job's fetch gets the token only on
  a push, a dispatch or a Mergify batch.
- `tests/fast-lints-data.bh-3860-test.sh`: a missing durations row is a D1
  note, never a failure (#5256). A row that exists and is not a number is still
  red. A7 skips when `FLD_ROOT` names a scratch tree.

## Steps a human must do

1. Set the worker secret: `wrangler secret put CI_DURATIONS_TOKEN` on `harness-jobs`.
2. Set the same value as the GitHub Actions secret `CI_DURATIONS_TOKEN` on
   `example-org/cromford`. Set the repo variable `JOBS_URL` to the jobs
   worker URL (the `JOBS_URL` value in `global.env`).
3. After the deploy applies the schema, run this once on the hub:
   `cd /root/repos/cromford && bin/ci-durations.sh seed`.

Until steps 1 and 2 are done, CI reads the artifact chain and the post job
prints "not configured". Nothing goes red.

## Not in this slice

`catalog/test-tiers.tsv` and `catalog/ci-merge-reuse.tsv` stay review-gated
files. They decide which suites and lint steps run, so moving them into a
table that a CI token can write is a separate decision.
