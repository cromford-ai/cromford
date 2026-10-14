# A rendered.sh helper that dies inside $(...) turns its suite red (BH-2263)

Doc: CI-RUNNERS

## What changed

- **`_rendered_die` in `tests/lib/rendered.sh` records itself.** Before its
  `exit 1` it appends its message to `$T/.rendered/FAILED`. Callers run the
  helpers inside `$(...)`, so that exit only ever ended the subshell, and a
  suite could print the FAIL and still exit 0.
- **New `rendered_verdict`.** It returns 0 when no helper died, else prints the
  recorded failures to stderr and returns 1.
- **rendered.sh installs its own EXIT trap** when sourced. It replaces
  scratch.sh's and chains to it, owner-guarded the same way. It reads the
  verdict before scratch cleanup deletes `$T`, turns an exit 0 into 1, and
  keeps a suite's own nonzero exit.
- **A suite that installs its own EXIT trap after sourcing rendered.sh must
  call `rendered_verdict` in it**, before `scratch_cleanup`.
  `tests/lane-reaper.bh-1770-test.sh` and `tests/heartbeat-reaper.bh-638-test.sh`
  now do. `tests/llm-lane-id.bh-2303-test.sh` sourced rendered.sh only inside
  `$(...)` and now sources it at top level.

## Test

`tests/rendered-lib.bh-2263-test.sh` runs child suites on the real libs with
stub renderers and asserts on their exit codes.
