# Tests assert the fields they own: a warn-mode lint and a prompt rule (BH-5792)

Doc: TESTING

## What changed

- `bin/test-payload-pin-lint.sh` is a new lint. It reports an added test-file
  line that compares a whole JSON payload: `jq -S .`, a deep-equal of a bare
  response against an object literal, or a shell assertion against a JSON
  literal with 3 or more keys. A contract test (`*.contract.test.*`, or a
  `# contract-test` / `// contract-test` header line) is skipped.
- `catalog/payload-pin-lint.conf` holds the mode, the rules and the thresholds.
  It ships `mode warn`: findings print and the exit code is 0.
- The PR `lint` job in `.github/workflows/harness-ci.yml` runs it as the step
  `whole-payload pin lint (BH-5792, warn only)`. A finding is a yellow
  annotation on the line. The job stays green.
- `prompts/build-discipline.md` has rule D56. `prompts/plan-contract.md` has
  §12. The planner sentence `th_plan_rule` in `bin/lib/test-home-lib.sh` now
  carries the same rule, so both planner prompts see it.
- `docs/TESTING.md` is new. It has the reasons, the rules, the blind spots and
  how to make the lint a gate.

## Why

#4126: `tests/utilization-tickets.bh-3988-test.sh` pinned whole payloads. When
main merged BH-4010, which added `pauses` and `prs` keys, T1, T5 and T6 went
red. Each break cost a fix round and a new review.

## Knobs

- `mode warn|error` in the conf. `--strict` forces error for one run.
- `opt min_keys` (3), `opt header_lines` (15), `opt warn_show` (50, the cap on
  annotation lines only).
- `PAYLOAD_PIN_LINT_CONF` or `$HARNESS/flags/payload-pin-lint.conf` override the conf.

## Not changed

Existing whole-payload pins are not rewritten. Diff mode ignores them;
`--all` lists them. The lint is not a rules-pack row yet.

Tests: `tests/test-payload-pin-lint.bh-5792-test.sh`.
