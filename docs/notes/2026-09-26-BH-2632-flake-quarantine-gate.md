# Audited flake quarantine routes and the merge gate (BH-2632, BH-2517.1)

Doc: FLAKY-TESTS

## What changed

- **Three worker routes** in `worker/jobs/src/routes/flakes.js`, over the
  `flaky_quarantine` and `flaky_quarantine_changes` tables BH-2631 shipped:
  - `PUT /api/metrics/flakes/quarantine` with body `{repo, test, active, reason, actor}`.
    `active` must be exactly `0`, `1`, `true` or `false`. `reason` is 1-512
    chars after trimming, `actor` 1-128, `test` 1-512 and `repo` 1-256.
    Anything else is a 400, and nothing is sliced to fit. A `job:*` or
    `workflow:*` test is refused. The before-read, the audit row and the upsert
    go in one `env.DB.batch`. Setting the state a row already has still writes
    an audit row and answers `changed:false`.
  - `GET /api/metrics/flakes/quarantine?repo=&active=` returns current rows,
    newest first, capped at 2000, with `truncated` when the cap was hit.
  - `GET /api/metrics/flakes/quarantine/changes?repo=&test=&limit=` returns
    the audit trail, newest first. `limit` is 1-200 and defaults to 50.
    Anything else is a 400.
- **`bin/lib/flaky.sh`** gains two functions:
  - `flaky_quarantined_set <slug>` returns the repo's active quarantine through
    `metric_flake_quarantine_list`. A read that fails, or a box with no
    client, gets the empty set.
  - `flaky_gate_set <slug>` is the ledger's `flaky_known_set` plus the
    quarantine, deduped.
- **`flaky_all_known` now reads `flaky_gate_set`.** Its one production caller
  is `mc_flake_rerun`, so a red where every failing test is quarantined gets
  the known-flake rerun instead of a red strike.

## What did not change

- **Retry, not ignore.** `mc_flake_rerun` still takes its one rerun per head,
  guarded by `mc_attempt_has`/`mc_rerun_mark`, before it checks the gate. A
  second red on the same head still counts, quarantined or not.
- **`flaky_known_set` is untouched.** `bin/flaky-quarantine.sh` still reads
  only the ledger, so an operator's quarantine never becomes a
  `ci/flaky.txt` proposal in a product repo.
- **The match is exact.** Names are trimmed at write and case is kept, so a
  quarantined `t1` does not forgive `T1`. One unquarantined, unknown failure
  next to a quarantined one still counts the red.
- **Before the worker deploys,** the quarantine read 404s and the gate falls
  back to the ledger set alone. That is the same gate as before this change.
