# Suite ledger across gates: prequeue reads and writes it, and the runner image is in the key (BH-6925)

Doc: CI-RUNNERS, MERGIFY

## Why

The suite ledger (BH-5366) already had readers and writers: the builder gate
(`bin/test-impact-gate.sh`, class builder, BH-5367) and the merge-queue batch
and push shards (`bin/ci-plan.sh` and the harness-ci record step, class ci,
BH-5368). The prequeue gate (`.github/workflows/prequeue-gate.yml`) did not
take part. It runs `bin/test-impact-gate.sh --runner traced`, and the gate did
reuse only on the local and isolated runners, with a builder credential a
GitHub runner does not have. So a suite that passed in prequeue ran again in
the batch, at the same input fingerprint, on the same runner fleet.

The fingerprint also had no runner image in it, so a green on one image could
be reused on another.

## What changed

- `bin/lib/suite-fingerprint.sh`: fingerprint v3. The canonical text has an
  `image\t<id>` line after the `suite-fp v3` header. `sfp_image_id` picks the
  id: `SUITE_IMAGE_ID` when non-empty (it must match `^[A-Za-z0-9._:@+/-]{1,128}$`,
  else the fingerprint is refused and reuse is off), else
  `gh:<ImageOS>:<ImageVersion>` on a GitHub-hosted runner, else
  `os:<ID>:<VERSION_ID>:<arch>` from `/etc/os-release`. It holds OS-level facts
  only: the batch plan job has no setup-node step, so a tool version in the id
  would never match the gate that ran the suite.
- `bin/suite-reuse.sh plan` prints `suite-reuse: image <id>` once the
  fingerprints are written.
- `bin/test-impact-gate.sh`:
  - New inputs: `SUITE_REUSE_CLASS` (builder, the default, or ci),
    `SUITE_REUSE_CTX` (default: the runner name) and `SUITE_LEDGER_TOKEN_FD`
    (an fd, 3-9, that holds the ci token).
  - The gate reads the token first, then unsets `SUITE_LEDGER_TOKEN` and
    `SUITE_LEDGER_TOKEN_FD` and closes the fd. Only the two
    `bin/suite-reuse.sh` calls get the token, so no suite inherits it.
  - Reuse now also runs on `--runner traced`.
  - Class ci records only from a traced run, because the batch writes a ci ok
    only for a traced-clean suite. Another runner prints
    `suite-reuse: record skipped (class ci records traced runs only)`.
  - On traced, a suite in the hits file is recorded fail whatever its rc.
  - A bad class, ctx or fd prints one `suite-reuse: off (<why>)` line and
    every suite runs.
- `.github/workflows/prequeue-gate.yml`: a `ledger credential` step writes the
  `SUITE_LEDGER_TOKEN` secret to a 0600 file in `$RUNNER_TEMP`. The verdict
  step reads and removes that file before any fetch, invariant or suite. It
  hands the token to the gate on fd 9, with class ci, the batch's ctx
  expression (`CI_REUSE_CTX` in harness-ci.yml), the repo and run key
  `prequeue-<run_id>-<attempt>`. It uses the secret and the
  `SUITE_LEDGER_URL` variable that harness-ci.yml already reads.
  - The credential step writes the token only when `github.actor` and
    `github.triggering_actor` both equal the new repo variable
    `PREQUEUE_LEDGER_ACTOR`. Set it to the hub app's bot login, which
    dispatches only a READY head. That is the trust level of a merge-queue
    batch. Any other dispatch runs unreviewed PR code (its own gate and
    `bin/suite-reuse.sh`), so it gets an empty file, prints
    `suite-reuse: credential withheld (...)`, and the gate runs every suite
    with reuse off.
  - New variable: `PREQUEUE_LEDGER_ACTOR` (GitHub repo variable). Until it is
    set, no prequeue run reads or writes the ledger.
- `catalog/suite-reuse-never.tsv`: the header says how to list a flake
  (`<suite>\tflake: <why>`). No suite is listed.

## What to expect after merge

Every v2 ledger row stops matching once, because the header and the image line
changed. Each suite runs in full the first time it is seen at its new
fingerprint, which is the cost of a run without reuse. After that, a prequeue
green is reused by the batch, and a batch or earlier prequeue green is reused
by prequeue. Look for `impact-gate: reused <suite> from prequeue-...` in a
prequeue log and `suite-reuse: reused <suite> from prequeue-...` in the batch
plan job.

## Left out

- The Mac gate (operator-a5 `combo.sh`) is not in this repo, and BH-6924 and
  BH-6736 replace it.
- Builder greens stay invisible to ci lookups (BH-5354 I1).
- Raising the Mergify `batch_size` from 4 to 6 to 8 (thread comment
  6199935073) is the next step. It needs 50 batches of data from after the
  ledger works.
- The metrics (suite runs per merged PR, batch minutes per merged PR, the rate
  of reused suites that later went red) come from the Actions API and
  `suite_reuse_runs` after merge. This change ships no report.

Tests: `tests/suite-ledger.bh-6925-test.sh`, `tests/prequeue-ledger.bh-6925-test.sh`.
