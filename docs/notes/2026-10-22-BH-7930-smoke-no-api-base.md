# BH-7930: the bootstrap smoke test no longer ends silently on an env with no API base

Doc: OPERATING

## What failed

On 2026-10-21, `bin/load-project.sh` for `cromford-sandbox-linear` and
`cromford-sandbox-jira` on `box-small` printed
`FATAL: bootstrap block on <box> exited 1` with nothing above it. The env files
were written by hand before the load, with tracker credentials only.
load-project kept them as found, so they had no `<PREFIX>_API_BASE` and no
`BASE_BRANCH` line. In `bin/bootstrap-machine.sh`, the smoke test line
`BASE_VAR=$(grep … | head -1)` then got grep rc 1, `pipefail` carried it, and
`set -e` ended the bootstrap with no message.

## What changed

- `bin/bootstrap-machine.sh`, block `# >>> smoke board`: `|| BASE_VAR=""` on
  the grep line, so an env with no base line takes the GitHub-Issues branch. A
  failed gh issue read is now one `FATAL: smoke: gh issue read on <repo> failed`
  line and rc 1 (before, the failure was ignored and the bootstrap went on). A
  block-scoped ERR trap prints `FATAL: smoke test step failed (line N, rc R)`
  for any other failed step. The trap is cleared before `# >>> smoke model`.
- `bin/load-project.sh`, block `# >>> env stub`: an env file that already
  exists gets `<PREFIX>_API_BASE=<prod>` and `BASE_BRANCH=<base>` appended when
  they are missing, with one `env: added <keys>` line. Any
  `^[A-Z_]+_(API|APP)_BASE=` line counts as a base (the regex the smoke test
  reads). A file that has both keys is not touched. The append keeps every
  existing line and the file mode, inside the same harden-state release/rearm.

## Tests

- `tests/bootstrap-smoke-no-api-base.bh-7930-test.sh` runs the smoke board
  block as shipped.
- `tests/load-project-env-exists.bh-7930-test.sh` runs the env stub block as
  shipped, with harden-state replaced by a stub.
