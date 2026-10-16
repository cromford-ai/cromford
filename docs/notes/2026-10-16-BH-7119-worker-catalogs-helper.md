# BH-7119: one helper writes the worker catalogs for a suite

Doc: none

## What changed

- New `tests/lib/worker-catalogs.sh` with one function, `worker_catalogs <root>`.
  It runs `bin/lanes-build.sh --root <root> --write`, then
  `bin/llm-sites-build.sh --compose --repo <root>`. On a failure it prints the
  same FAIL line as the old inline code and returns 1. It never exits.
- A suite that loads `worker/jobs/src/index.js` uses two lines after `DIR=`:

  ```bash
  . "$DIR/tests/lib/worker-catalogs.sh" || exit 1
  worker_catalogs "$DIR" || exit 1
  ```

- `tests/worker-node-catalog-compose.bh-6452-test.sh` and
  `tests/worker-node-lanes-build.bh-6540-test.sh` accept a suite that sources
  the helper and calls `worker_catalogs` on a non-comment line. A source with
  no call is still flagged. The inline builder lines are still accepted.
- The 23 suites that had the exact two inline lines now use the helper. The
  suites with a variant shape (a sandbox prefix, an `if !` arm, a `bad`
  handler, compose only) keep their inline lines.

## Why

On 2026-10-16 four PRs failed the R0 case of one of the two guards, because a
new suite loaded the worker before it composed the catalogs. One helper line
pair is easier to copy correctly than two long builder lines.
