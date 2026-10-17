# The pre-push gate runs every deterministic ratchet before the push (BH-7187)

Doc: MERGE-CONDUCTOR

On 2026-10-16, 9 of 10 merge-queue rounds were lost to deterministic lints that ran only in CI.
Each lost round cost about 35 minutes. `bin/prepush-gate.sh` runs all of them on the committed
head before the push, so the fix round happens on the box and not in the queue.

**The components.** Run `bin/prepush-gate.sh --list` for the table. The gate runs these:

| id | command |
|---|---|
| rules-pack | `bin/rules-pack.sh --runner local --base <fork>` (all components except the two below) |
| fast-lints | `bin/fast-lints.sh --run` |
| checks-run | `bin/checks-run.sh --tree .` |
| orphans | `bin/test-impact.sh orphans --check` |
| determinism | `bin/test-determinism-lint.sh --changed <fork>` |
| llm-sites, context-budgets, config-inventory, render-rules, render-cron, render-env, render-doc-sections, schema-build | the derived-docs gates, each with `--check` |

The gate runs `determinism` and `checks-run` as their own rows. It skips their rules-pack copies,
so a red names them and they run once.

**The output.** One line per component: `prepush-gate: <id> green|red|could-not-run rc=<n> <s>s`.
A red row lists up to 15 findings. The last line is the verdict: `GREEN`, `RED` or `COULD-NOT-RUN`.
The rc is 0 for GREEN and 1 for anything else. The rc is 2 for bad arguments. `<out>/summary.tsv`
holds one row per component.

**Never silently green.** A missing script (rc 127), a runner that cannot start (125), a timeout
(124, cap `PREPUSH_GATE_TIMEOUT_S`, default 300) and any rc other than 0 or 1 are `could-not-run`.
A rules pack that exits 0 without a `summary.json` that says `clean` is `could-not-run` too.

**The stale schema stamp.** When `schema-fragment-name` is red, the gate prints the exact
`git mv` lines for the current UTC minute. Run `bin/prepush-gate.sh --restamp` to apply them as one
commit with no SQL change (`bin/lib/schema-restamp.sh`, `sr_apply`).

**The builder.** `bin/lib/rb/pr.sh`, span `prepush gate`, runs the gate right before the push.
1. If a stamp is stale, the span restamps once and runs the gate again.
2. If any component is red, the span refuses the push. It exits 6 with
   `REVIEW_BLOCKED prepush-gate: red in <component> [<ids>]`. The findings are in
   `prepush-gate-block.txt` in the build directory.
3. If a component is `could-not-run`, the push goes on. The PR body gets a section that names it.

**The off switch is a settings row.** `prepush.gate_mode.<project>`, then `prepush.gate_mode`.
`block` is the default. `warn` runs the gate, notes a red in the PR body and pushes. `off` does not
run the gate. A row that cannot be read, or any other value, is `block`.
The seed is `worker/jobs/schema.d/*-bh-7187-prepush-gate-mode.sql`.

**The operator path.** To run the gate on every `git push` in a checkout:

1. Write `.git/hooks/pre-push` with these two lines: `#!/bin/sh` and `exec bin/prepush-gate.sh`.
2. Run `chmod +x .git/hooks/pre-push`.

To run it once, use `bin/prepush-gate.sh --base origin/main`. On a Mac, use bash 4 or newer.
`bin/rules-pack.sh` does not run under the bash 3.2 that macOS ships, and the gate reports it as
`could-not-run`.

**The measure.** Over the next 20 harness PRs, count merge-queue batches lost to a rules-pack or
lint finding. The target is 0. Before this gate it was 9 of 10 rounds.
