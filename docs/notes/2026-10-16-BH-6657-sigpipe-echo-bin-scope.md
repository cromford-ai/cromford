# 2026-10-16 — BH-6657: race-sigpipe-echo scans bin/

BH-6109 slice C6. The rule note is
[2026-10-12-BH-6109-sigpipe-echo-rule.md](2026-10-12-BH-6109-sigpipe-echo-rule.md).
This note records what C6 armed. It does not change that note.

## What changed

`catalog/determinism-lint.conf` has a new line under the `race-sigpipe` scope:

```
scope race-sigpipe-echo (^|/)bin/.*\.sh$
```

The rule now scans test files and every `bin/**/*.sh`. Before this line, a
`printf`/`echo` pipe into `grep -q`/`-m` or `head` in bin/ was not a finding.

## The sweep

On main 0b13879b, a full-tree lint with the scope line gave rc 1 with 48
`race-sigpipe-echo` hits in 27 bin/ files. The same diff rewrites all 48, so
main is rc 0 when the line lands. bin/ has no waiver: every hit there is a
pipe that the shell runs.

| file | lines |
|---|---|
| bin/ci-plan-split-replay.sh | 174 |
| bin/ci-plan.sh | 571, 729, 730 |
| bin/context-budgets-build.sh | 101 |
| bin/decompose-lint.sh | 74, 75 |
| bin/lane-run-worker.sh | 310 |
| bin/lib/lead-diff-parts.sh | 80 |
| bin/lib/needs-human/step-done.sh | 82 |
| bin/llm-sites-build.sh | 116 |
| bin/review-autopilot.sh | 321, 322, 325, 340, 342, 344, 891 |
| bin/routing-flip-preflight.sh | 82 |
| bin/scope-gate.sh | 242 |
| bin/spend-ceiling-seed.sh | 64, 65, 68 |
| bin/spend-lane-push.sh | 45, 63, 64 |
| bin/split-watchdog.sh | 235, 406 |
| bin/standby-verify.sh | 136, 144 |
| bin/state-paths-guard.sh | 67 |
| bin/switch-migrate.sh | 69 |
| bin/test-impact.sh | 1385 |
| bin/test-payload-pin-lint.sh | 161 |
| bin/test-suite-run.sh | 172, 173 |
| bin/test-tamper-scan.sh | 233, 556 |
| bin/testhost-tick.sh | 195 |
| bin/trap-eval.sh | 206 |
| bin/triage-gate.sh | 729 |
| bin/verify-claims.sh | 49, 72 |
| bin/wake-loop.sh | 832 |
| bin/watchdog-responder.sh | 532, 720, 837, 874 |

Most lines take the R1 here-string: `grep -q X <<<"$VAR"`. A `printf '%s'`
with no newline gives the same `grep` answer as the here-string, because no
pattern on these lines matches an empty line.

## R2 picks (process substitution)

These lines keep the exact bytes with `< <(printf '%s' …)`:

- bin/lane-run-worker.sh:310, bin/routing-flip-preflight.sh:82,
  bin/review-autopilot.sh:891, bin/watchdog-responder.sh:720 and :874:
  `head -c N` must count the bytes of the value, not the value plus a newline.
- bin/test-tamper-scan.sh:233 (`in_set`): `grep -qxF -- "$1"` with an empty
  `$1` matches the empty line that a here-string adds. The process
  substitution adds no line.
- bin/test-tamper-scan.sh:556: `head -40` is not inside `$(…)`, so a
  here-string would print a trailing newline that the old pipe did not.

## The one waiver

`tests/test-determinism-lint.bh-1248-test.sh` case D plants a `bin/quiet.sh`
fixture with `echo git-ish | grep -q 'the commit'`. With the scope armed, that
fixture line is a finding and case D goes red (`11 passed, 1 failed`). The line
has the waiver `# determinism: ok race-sigpipe-echo seven bytes, written before
grep reads`.

## Lever

If the rule must stop blocking bin/, set the settings row
`conf.determinism-lint.rule.race-sigpipe-echo` to the conf's rule value with
`warn` in place of `error` (the row replaces the whole `rule` line, see
bin/test-determinism-lint.sh "THE SETTINGS ROWS"). Do not
delete the scope line: a new bin/ hit then lands with no signal at all.

Verified by `tests/test-determinism-lint.bh-6657-test.sh`.
