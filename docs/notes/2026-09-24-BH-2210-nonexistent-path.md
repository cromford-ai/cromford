# A directory is never a conf file, and a test that creates /nonexistent is a trace-safety hit

Doc: MERGE-CONDUCTOR

## What changed

- **`mc_regen_paths` and `mc_generated_globs` (`bin/lib/mc/rebase.sh`) need a
  regular file.** The guard is `[ -f "$CONF" ] && [ -r "$CONF" ]`. A conf path
  that is a directory now falls back to `MC_REGENERATED_PATHS_DEFAULT` /
  `MC_GENERATED_PATHS_DEFAULT`, the same as an absent one. Before, `[ -r dir ]`
  was true, `sed` failed on the directory and the table came back empty. A
  regular conf, or a symlink to one, is read as before.
- **Seven suites stop using a fixed `/nonexistent` to mean "missing".** They use
  a path under their own `$T`: regenerated-path-conflicts.bh-1162,
  generated-path-conflicts, gh-app-ratchet, prompt-ceiling, planned-files-cheap,
  env-path-port-b, readiness-report.
- **`bin/test-trace-safety.sh` flags creation under `/nonexistent`.** Two new
  verbs, `mkdir` and `touch`, are hits only when the resolved target is
  `/nonexistent` or below it. A per-test existence probe adds
  `HIT <test> created /nonexistent` when the dir was absent before a test and
  present after, whatever wrote it. If it already exists when the run starts,
  the runner prints `CHECK-NOTE test-trace-safety: /nonexistent already exists,
  creation probe cannot attribute` on stderr and rc is unchanged. The root is
  the `TRACE_SAFETY_CREATE_ROOT` knob (default `/nonexistent`), which exists so
  the suite can aim the probe at a scratch path.

## Why

`tests/regenerated-path-conflicts.bh-1162-test.sh` was red on testhost-1 and
green in CI. On testhost-1 `/nonexistent` was a root-owned directory holding
`state/` and `logs/`. It came from `tests/gh-app-ratchet-test.sh:872`, which ran
`HARNESS=/nonexistent; . bin/lib/merge-conductor-lib.sh` as root; sourcing that
lib runs `mkdir -p "$h/state/lane-gate" "$h/logs"` at `bin/lib/lane-gate.sh:265`.
The trace runner only flagged deletions and redirects, so it never saw it.

## Operator step

The stray directory on the testhosts is not removed by this change. After T1 and
the test fixes it is harmless. To remove it, on each machine of
`bh-testhost-example-org`, check that it holds only `state/lane-gate` and `logs/`,
then remove it:
`flyctl ssh console -a bh-testhost-example-org --machine <id> -C 'sh -c "ls -la /nonexistent /nonexistent/*; rm -rf /nonexistent"'`

Tests: `tests/nonexistent-path.bh-2210-test.sh`.
