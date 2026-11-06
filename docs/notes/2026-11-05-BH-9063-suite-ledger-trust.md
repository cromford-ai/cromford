# BH-9063 (C0): the suite ledger's trust knob, red rows and retention

Doc: CI-RUNNERS, DB-COORDINATION-SPEC

## What changed

The suite ledger (`suite_results`, BH-5354/BH-5366) is the one table every gate
can share. This slice changes the worker only. No gate calls it in a new way,
so no gate changes behavior on merge.

1. **Trust knob.** The settings row `lib.suite-reuse.suite_reuse_trust`
   (registry knob `SUITE_REUSE_TRUST`, read in `worker/jobs/src/lib/suite-trust.js`)
   decides which rows `POST /api/suite-results/lookup` serves.
   - `class` (seed and code fallback): the BH-5354 I1 rule. A lookup matches
     its own ctx, and a ci (token) caller sees ci rows only.
   - `image`: a lookup matches `(repo, suite, fingerprint)` in every class and
     every ctx. The fingerprint (`bin/lib/suite-fingerprint.sh`, v3) carries
     the runner image id, so the same fingerprint means the same image. That
     is the mechanical trust rule the ticket asks for. A fail at the key in any
     row hides every green.
   - Any other value, or a settings read that throws, answers `reuse: "off"`
     with a reason. It never falls back to the default (D11).
   - `repo` is always a hard filter (the tenant).
2. **Red rows.** The lookup answer gains `trust` (the mode that answered) and
   `reds: [{suite, fingerprint, run_id, class}]`: the fail rows at the asked
   keys, with `updated_at` inside the same `max_age_h` window as a green.
   `run_id` is the row's `last_run_id`, the run that last wrote it (a fail is
   sticky, so a later ok run can be that run). `bin/suite-reuse.sh` reads
   `.reuse`, `.reason` and `.hits` only, so the new fields change nothing for it.
3. **Index.** `idx_suite_results_fp (repo, suite, fingerprint)` serves the
   image-trust hit read, its fail probe and the reds read. It is an
   `ADDED_INDEXES` fragment (`worker/jobs/src/lib/core.d/bh-9063-suite-results-fp.js`);
   the lookup route runs `ensureColumns` after `ensureTable` to create it.
4. **Retention.** Two rules in `worker/jobs/src/routes/retention.d/bh-9063-suite-ledger.js`,
   run by the hourly `bin/d1-retention.sh` lane (`POST /api/retention/run`):
   - `suite_results.age`: rows whose last write is older than
     `retention.suite_results.days` (14) go. Index `idx_suite_results_updated`.
   - `suite_reuse_runs.age`: rows older than `retention.suite_reuse_runs.days`
     (60) go. 60 is `SAVED_DAYS_MAX`, the longest Mission Control SUITE REUSE
     range. Index `idx_suite_reuse_runs_created`.
   Both obey `retention.dry_run` (seed 1: count only) and write one
   `retention_runs` row per run. A window of 0 turns a rule off.

The inline 30-day prune in `PUT /api/suite-results` stays in this slice: with
`retention.dry_run=1` it is the only delete. `bin/impact-learn-lane.sh` step 7b
reads passes up to 30 days back; once the 14-day rule runs for real it sees 14
days, so a learned edge expires later, never sooner.

## Next slices

- **C1:** `bin/suite-reuse.sh plan --reds OUT [--rerun-red]`; the builder gate
  and the selection gate read and write the ledger with the test host's image
  digest as `SUITE_IMAGE_ID`; flip `lib.suite-reuse.suite_reuse_trust` to `image`.
- **C2:** the prequeue impact step reads the ledger only; remove the inline
  30-day prune after the dry-run audit rows are read; align the impact-learn
  floor; the 24 h "each suite runs at most 2 times" count.

## Tests

- `worker/jobs/test/suite-results-trust.bh-9063.test.js` (T1-T8)
- `worker/jobs/test/suite-results-retention.bh-9063.test.js` (R1-R4)
