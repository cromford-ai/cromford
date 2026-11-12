# Gates vs reports

BH-5292 (the operator, 2026-10-07). To be folded into `docs/OPERATING.md` by #5289.

**The rule.** A limit on something that is not itself harmful is **reported**:
a warning line, a PR note, a Mission Control metric. It never fails a check or
blocks a merge. Time, size, line counts and a missing timing row are in this
class. A limit that protects money, the machine or security **stays hard**.

The template already in the repo is `RULES_PACK_BUDGET_S`: over budget is a
note, never a red (`tests/rules-pack-budget.bh-4220-test.sh`).

## Reports (never a red)

| Limit | Where | What you see |
|---|---|---|
| An always-run suite with no row in the durations file (CI-composed since BH-5518) | `tests/fast-lints-data.bh-3860-test.sh` D1-D2 | `WARN` line naming the suite. `bin/fast-lints.sh --list` and the shard split weigh it at the file's median. |
| Fast-lints total over `FAST_LINTS_BUDGET_S` | `bin/fast-lints.sh --assert-budget`, the `fast always-lints` step | stderr note with the three slowest; rc 0; the step's verdict reads only the rules pack (`prc`) and the suites (`frc`) |
| A fast-lints suite over 2 x `FAST_LINTS_MAX_S` | same | stderr note naming the suite; rc 0 |
| A diff over 400 changed lines | `bin/lib/rb/pr.sh` `# >>> diff size note` | `large diff: N lines` on the PR note and the console's tier event; the tier is unchanged |
| A plan with no `## Size` section | `bin/size-gate.sh` | `SIZE_GATE_WARNING`, `SIZE_ESTIMATED` from the plan's file list, verdict `estimated`; it builds whole unless the estimate is past 2x the threshold |
| Wall-clock seconds inside a test | the five suites BH-5292 converted | tests prove the work is bounded and done (counted stub calls, the expected exit, a holder still alive) under a ~60 s hang guard |

## Stays hard

- Money caps, and attempt caps on metered work.
- Disk and `/tmp` floors.
- Process timeouts and CI job timeouts (a hang guard is a timeout).
- Security gates, the iron-law guard's verdicts, and RLS.
- The GitHub API budget.
- The context-budget manifest test.
- Prompt-eval regressions.
- The tier's **path** rule (auth, billing, schema, workflows, env, protected paths).
- The plan size **split** at the 700-line / 20-file threshold: a declared size over it still decomposes. It only decomposes, never refuses.
- A malformed durations row, or a malformed fast-lints timings file: a broken file is an error, not a missing measurement.
- A red suite and a red rules-pack row.

Source-file line limits are #5273.

## Human gates

A question to a person is a human gate (`docs/CUSTODY.md`). A gate is
`defaultable` or `irreversible`, from the settings row
`human_gate.class.<reason>`; an unknown reason is irreversible. An
irreversible gate never auto-applies its default. Two gates are not human
questions and stay hard: [pre-queue fresh main](gates/prequeue-fresh-main.md)
and [builder to-red](gates/builder-topred.md).
