# CI test tiers in the jobs worker

BH-5653 slice C1 (BH-5637.2), 2026-10-10. `catalog/test-tiers.tsv` can also live as data in the jobs worker. CI reads it from there first.

## What the tier file is

`catalog/test-tiers.tsv` says which tier each suite runs in: `batch`, `nightly` or `guard`. `bin/test-tiers.sh` has the format and the rules. `bin/ci-plan.sh` applies it to the merge-queue batch and to the nightly run. A suite with no row is `batch`.

Since BH-6838 the nightly run (`.github/workflows/harness-nightly.yml`) plans the whole corpus with `bin/ci-plan.sh --tier nightly-full`, so every `nightly` suite runs there each night. The batch still drops `nightly` suites after its tier step. Then it adds back each suite of the batch-fail regression list (`catalog/ci-batch-regression.d/`) whose paths the batch's diff touches. The day-boundary guard has a `nightly` row (BH-6838: test hygiene). The fixture-hygiene suite stays in the batch: its rules are leak checks. An operator copies the committed rows into the worker set with `bin/ci-test-tiers.sh put`.

The file decides which suites a batch skips. So the worker copy has two hard rules:

1. Only `HARNESS_SECRET` (a box or an operator) can write a set. CI's scoped `CI_DURATIONS_TOKEN` can only read.
2. A set is used only while it is based on the checkout's committed file. A PR that edits `catalog/test-tiers.tsv` always wins over an older set.

## The data

D1 table `ci_test_tier_sets` (`worker/jobs/schema.d/0019-bh-5653-test-tiers.sql`). One row per SET: a whole snapshot of the file.

| Column | Meaning |
|---|---|
| `id` | Grows with each write. The newest set is the highest id. |
| `base_blob` | The git blob sha of `catalog/test-tiers.tsv` at HEAD when the set was written. |
| `digest` | sha256 of `base_blob` and the rows sorted by suite. |
| `rows_json` | `[{suite, tier, runtime_s, paths, reason}]`, sorted by suite. |
| `source` | `seed` (the committed file) or `operator` (an edited copy). |
| `actor`, `created_at` | Who wrote it, and when. |

Sets are never pruned. A set is about 20 KB, and only an operator writes one.

## The routes

Both are in `OPEN_ROUTES` (`worker/jobs/src/routes/ci-test-tiers.js`). Each checks its own bearer.

- `GET /api/ci/test-tiers`: `CI_DURATIONS_TOKEN` or `HARNESS_SECRET`. Answers `{"set":null}` when the table is empty, else `{"set":{id, base_blob, digest, source, actor, created_at, rows}}` for the newest set.
- `PUT /api/ci/test-tiers`: `HARNESS_SECRET` only. Body `{base_blob, source, actor, rows}`. Every row is checked before the write. One bad row refuses the whole body with 400 and writes nothing. The rules are those of `bin/test-tiers.sh check`, except "the suite file exists": the worker has no tree. A body equal to the newest set answers `200 {id, duplicate:true}` and writes nothing. Any other body is a new set, `201 {id}`. A body equal to an OLDER set is also a new set, so re-applying an old set makes it the newest.

An unapplied table answers `503 ci_test_tier_sets schema not applied`.

## The reader chain: `bin/ci-test-tiers.sh fetch`

`fetch --out <file> [--root <checkout>]` writes one tier file in the catalog's own format. Its first line names the source:

1. `# source: api set <id> base <blob>`. The worker's newest set, when its `base_blob` is the blob of `catalog/test-tiers.tsv` at HEAD of the checkout AND `bin/test-tiers.sh check` accepts it. The answer is then copied to the cache.
2. `# source: cache set <id> base <blob>`. The worker answer was unusable (HTTP error, not JSON, a dead worker, a failed check). The cache names the same blob and passes check. One `::warning::`.
3. `# source: committed <blob>`. Everything else:
   - not configured (no `JOBS_URL` or no token): no request is sent;
   - `{"set":null}`: one `::notice::`;
   - a set on another blob (the committed file changed): one `::warning::` that names both blobs;
   - an unusable answer and no usable cache: one `::warning::`.

`fetch` always exits 0. A bad answer never overwrites the cache. The cache is `CI_TEST_TIERS_CACHE`, default `<harness>/state/ci-test-tiers/api.tsv`. In CI it lives in `runner.temp`, so it lasts one run.

## CI wiring

- `harness-ci.yml`, plan job: the step "the test tiers (ci-test-tiers)" runs BEFORE `bin/ci-plan.sh`. It writes `$RUNNER_TEMP/ci-durations/test-tiers.tsv`, and the plan step reads it through `CI_PLAN_TIER_FILE`. It gets the token with the same guard as the durations fetch: a push, a dispatch or a Mergify batch draft. An ordinary PR sends no request and uses the committed file.
- The file rides in the `ci-durations` artifact. Each `tests-shard` downloads that artifact BEFORE its own `bin/ci-plan.sh --expect-n`, and fails if `test-tiers.tsv` is missing. A shard never fetches on its own, so a set written between the plan and a shard cannot split the shards.
- `harness-nightly.yml`: the plan job fetches into `$RUNNER_TEMP/tiers/test-tiers.tsv` and uploads it as `nightly-tiers`. Each shard downloads it before its re-plan and fails without it.
- `tests/ci-test-tiers-workflow.bh-5653-test.sh` pins this wiring.

## How an operator changes a tier

1. Copy `catalog/test-tiers.tsv` to a file and edit it.
2. Run `bin/ci-test-tiers.sh put --file <file> --source operator --dry-run` and read the body.
3. Run `bin/ci-test-tiers.sh put --file <file> --source operator`. It runs `bin/test-tiers.sh check` first and refuses a bad file.
4. The next CI run reads the new set. The set stops applying when a commit changes `catalog/test-tiers.tsv` on main.

To seed the committed file as a set, run `bin/ci-test-tiers.sh put`. This is optional: with an empty table, CI uses the committed file.

## What does NOT read the worker

Box and hub readers stay on the committed file: `bin/test-impact-gate.sh`, `bin/lib/test-protected.sh`, `bin/lib/mc-foreign-red.sh` and `bin/nightly-ticket.sh`. They differ from CI only after an operator `put`. A builder's pre-push gate can then rank a suite by the committed tier while CI uses the set's tier.

`catalog/ci-merge-reuse.tsv` is not in the worker yet (child slice C2).

## Tests

- `worker/jobs/test/ci-test-tiers.bh-5653.test.js`: the routes over the real schema.
- `tests/ci-test-tiers-db.bh-5653-test.sh`: `put` and `fetch` against the real worker; the batch and nightly lists are byte-identical on both paths.
- `tests/ci-test-tiers-fallback.bh-5653-test.sh`: every unusable answer falls back, and the cache is never overwritten by one.
- `tests/ci-test-tiers-workflow.bh-5653-test.sh`: the CI wiring.
