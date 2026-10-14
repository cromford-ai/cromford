# A mirror mid-sync retries the apt update once, and apt fails in an `infra:` step

Doc: CI-RUNNERS

## What changed

- **`bin/ci-apt-update.sh` runs every `apt-get update` in
  `.github/workflows/harness-ci.yml`.** It calls `sudo apt-get -o
  Acquire::Retries=3 update -q`. On a failure it prints a `::warning title=CI
  infra (apt)` line, sleeps `CI_APT_RETRY_DELAY_S` (default 20) and tries once
  more. A second failure prints `::error title=CI infra (apt)` and exits with
  apt's own rc. A delay that is not a whole number of seconds is rc 2 and apt
  never runs.
- **Every apt install is in its own step, named `infra:`.** The two PyYAML
  steps are now `infra: install PyYAML (apt)`. The age/zstd and rsync installs
  moved out of `tests/ suite (shard n of 8)` into `infra: install age, zstd,
  rsync (apt)` right before it. Job names did not change.
- The `apt-get install` lines and their `bin/ci-tool-present.sh` guards are
  byte-identical, so a runner that already has the package still skips the
  update and the install.
- `tests/ci-apt-update.bh-2128-test.sh` pins the helper (stubbed apt) and the
  workflow shape.

## Why

Runs 36029556164 and 36029663354 went red in `apt-get update` with "File has
unexpected size (46392 != 46384). Mirror sync in progress?". One attempt under
`set -e` killed the shard, and the install ran inside the corpus step, so the
job looked like a test failure.

## Rules this touches

- A new apt install in the workflow calls `bin/ci-apt-update.sh` for its update
  and lives in a step whose name starts `infra:`. No step that runs
  `bin/test-suite-run.sh` or `bin/test-trace-safety.sh` runs apt.
- Not changed: `bin/main-red-detector.sh` reads failing JOB names only, so it
  still cannot tell an `infra:` step failure from a test failure. That needs its
  own ticket.
- Not verified here: on the Fly bh-ci image `sudo apt-get` is the
  `/usr/local/sbin/apt-get` flock wrapper, which is built outside this repo. It
  is assumed to pass `-o Acquire::Retries=3` through to the real apt-get.
