# BH-9779: bounded verification

Doc: PROMPTS, FLAKY-TESTS, TESTING

## Cause (Scope item 1)

The cause of the 6,716 s BH-7921 execute call is confirmed from three facts.
No replay ran (the operator's comment of 2026-11-17 says one is needed only if a fact
is in doubt):

1. `.harness/specs/BH-7921/plan.md` line 122 is the loop:
   `grep -l 'rb-all.sh\|...' tests/*.sh | while read t; do HARNESS_TEST_SANDBOX=1 bash "$t" >/dev/null 2>&1 || echo "RED $t"; done`,
   "run on the head AND on main". the operator measured 279 matched suites, so 558
   runs, with the output sent to `/dev/null`. Line 113 says "The build must run
   both with no timeout" for `tests/docs-guide-pages.bh-6507-test.sh`, measured
   at 488 s.
2. Claude Code 2.1.325 does not end a Bash command at its 120 s timeout. It
   moves the command to the background and keeps it running. This build saw it
   again on 2026-11-18: a 365 MB `grep` went past 120 s and the CLI printed
   "Command did not complete within its 120s timeout and was moved to the
   background". The same message says a background command "will be stopped"
   after 10 min. This build did not wait to see that stop, and the BH-7921 calls
   ran on pool machines whose CLI version is not recorded here.
3. No file in the repo set `BASH_DEFAULT_TIMEOUT_MS`, `BASH_MAX_TIMEOUT_MS` or
   `CLAUDE_CODE_SHELL_PREFIX` before this change. No harness limit applied per
   command.

## What changed

- `bin/lib/plan-verify-budget.sh` (new): `pvb_plan_check` reads the plan's
  `## Verify` section. `bin/plan-gate.sh` runs it, and a list over its budget
  refuses the plan (rc 2, the existing one repair pass, then PLAN_MALFORMED).
  The rules are `suite-count`, `loop`, `main-runs`, `no-timeout` and
  `slow-suite`. `pvb_repair_note` adds one paragraph to the repair prompt. The
  only edit to `bin/lib/rb/plan.sh` is that call.
  New gate output lines: `PLAN_VERIFY_DURATIONS:`, `PLAN_VERIFY_SUITES:`,
  `PLAN_VERIFY_BUDGET:` and `  UNTRACED: verify budget — line <n>: <rule>: ...`.
- `bin/agent-cmd-limit.sh` (new): the per-command wrapper. `bin/agent-call.sh`
  arms it through `bin/lib/agent-cmd-limit.sh` (`acl_arm`) as
  `CLAUDE_CODE_SHELL_PREFIX` for the plan, execute, review and fix stages. At
  the limit the command ends, the agent gets the last lines of its output and
  one line that states the limit, and the session goes on (rc 124). A child that
  the command left holding its output is ended at the same limit.
- `bin/lib/selection-gate-retry.sh` (new): selection-gate step 7. A red only on
  suites outside the change's impact set runs those suites once more. A suite
  green on that run leaves `red:` and gets a `ci_flakes` row (workflow
  `selection-gate`, kind `flake`, the day set by the worker). gate.txt gets a
  `retry:` line before `fresh-main:`. `sg_block` adds one PR-body sentence that
  names the retried suites.
- `prompts/stages/execute.md`: one sentence. Run the suites the plan names, one
  command per suite, never send a suite's output to `/dev/null`, and leave the
  wide run to the gate.

## Limits chosen

| Row | Default | Why |
|---|---|---|
| `lib.plan-verify-budget.plan_verify_budget` | 1 | The ticket asks for a refusal. 0 turns the check off fleet-wide. |
| `lib.plan-verify-budget.plan_verify_max_suites` | 30 | The committed BH-7921 Verify section names 20 distinct suites, 18 after the loop, main and no-timeout lines are removed (V9). the operator counted 26 in the pool plan; it ran in about 12 min. 30 passes it with a margin and refuses the 279-suite loop. |
| `lib.plan-verify-budget.plan_verify_max_main_suites` | 3 | A main run is for a suite the plan thinks is red on main. BH-7921 had two such single-suite lines. A loop on main is always over the limit. |
| `lib.plan-verify-budget.plan_verify_slow_suite_s` | 300 | 488 s was the slowest BH-7921 suite; every other one was under 50 s. |
| `lib.agent-cmd-limit.agent_cmd_limit_s` | 1800 | Over 1500, because `bin/test-impact-gate.sh` runs under `timeout 1500` in a build and builders must run it (D38). 3.7 times under the 6,716 s call. 0 = not armed. |
| `lib.agent-cmd-limit.agent_cmd_tail_lines` | 40 | The same as `SELECTION_GATE_RUN_TAIL_LINES`. |
| `lib.agent-cmd-limit.agent_cmd_kill_grace_s` | 10 | The seconds between SIGTERM and SIGKILL at the limit (`timeout -k`). |
| `lane.fly-pool.selection_gate_retry_outside` | 1 | The ticket asks for the retry. `bin/selection-gate.sh` alone falls back to 0, like its other steps. |
| `lane.fly-pool.selection_gate_retry_timeout_s` | 600 | The slowest measured suite is about 488 s. |
| `lane.fly-pool.selection_gate_retry_max` | 3 | The same as `SELECTION_GATE_QUARANTINE_MAX_NEW`: many reds at once looks like a host problem, not flakes. |

### Measurement on the committed plans (2026-11-18)

The lint ran once on each of the 2,250 `.harness/specs/*/plan.md` files, with
no network and no durations file on the box (`PLAN_VERIFY_DURATIONS: unread`,
so the slow-suite rule did not run). For the first 1,261 files it ran through
`bin/plan-gate.sh`, and `pvb_plan_check` gave the same verdict on each one
(0 differences).

| Verdict | Plans |
|---|---|
| `n/a` (no Verify section) | 1,429 |
| `ok` | 698 |
| `over` | 123 (15% of the 821 plans with a Verify section) |

Hits by rule: `loop` 143, `main-runs` 5, `no-timeout` 1, `suite-count` 1.
I read the hits. The `main-runs`, `no-timeout` and `suite-count` hits are all
true: the BH-7921 lines, a 15-suite run on main, and one list of 31 suites.
Most `loop` hits are a glob or a loop over `tests/` that a build runs
(`tests/mc/*.sh`, `for t in tests/...`, `grep -l ... tests/*.sh`). A few
describe a glob in prose ("others found by `grep -l ... tests/*.sh`"). The
ticket asks to refuse any glob over `tests/`, so the rule stays as it is. The
one repair pass names the line, and the planner rewrites it. The row
`lib.plan-verify-budget.plan_verify_budget` = 0 turns the check off.

## Not verified here

One live agent call with the prefix armed was not run (it needs a model call).
The wrapper reads both forms the CLI can use (one command string, or a program
and its arguments). It runs a form it cannot read unwrapped.
