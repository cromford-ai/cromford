# BH-9912: hook exit-code audit and the knob-gated deny layer

## Why

Claude Code reads exit 2 from a PreToolUse hook as a block. Any other nonzero
exit is a non-blocking hook error, and the tool call runs. A guard whose deny
path exits 1 guards nothing. The ticket asked for an audit of every hook, plus
a deny layer for the iron guardrails that does not depend on a hook process.

## Hook audit

| Hook | Where wired | Event / matcher | Blocks? | Block exit before | After |
|---|---|---|---|---|---|
| `codegraph prompt-hook` | rules/settings.json | UserPromptSubmit | no (context only) | n/a | n/a |
| `/usr/local/bin/rtk hook claude` | rules/settings.json, fly/Dockerfile | PreToolUse Bash | no (rewrites input) | n/a | n/a |
| `bin/secret-read-guard.py` | rules/settings.json; `bin/secret-read-guard-install.sh` | PreToolUse Read\|Grep\|Bash | yes | 2. CRASH is 2 only when the payload names a secret path, else 0 by design. INERT is 0 by design. | 2 (unchanged) |
| `bin/iron-law-guard.sh` | bin/agent-call.sh (guarded lanes), bin/iron-law-arm.sh (+ box-chat.sh) | PreToolUse Bash | yes | 2 (deny; CRASH_BLOCK from the EXIT/TERM/INT/HUP traps). LOUD is 0 by design. | 2 (unchanged; family 8 uses the same exit) |
| `bin/lane-shims/_fence.sh` | PATH shim on codex lanes | not a CC hook | yes | 2; the real binary never runs | 2 (unchanged) |
| `bin/lane-fence.sh pre-push` | git core.hooksPath on codex lanes | git pre-push | yes | nonzero (git blocks on any nonzero) | unchanged |
| `bin/edit-feedback-hook.sh` | agent-call.sh (EDIT_FEEDBACK=1, execute) | PostToolUse Bash | no (feedback after the tool ran) | 2 = feedback, not a block | n/a |
| `bin/exec-proc-hook.sh` | agent-call.sh (execute) | PostToolUse / PostToolUseFailure | no | n/a | n/a |
| `bin/compact-recheck.sh` | agent-call.sh | SessionStart compact | no | n/a | n/a |

Finding: no blocking hook exits 1 on a block. There is no exit-code fix.
The real gap is the CLI's hook timeout: a hook the CLI abandons is fail-open.
The `permissions.deny` / `--disallowedTools` layer below needs no hook process,
so it closes that gap for the prefix shapes.

`tests/hook-exit-audit.bh-9912-test.sh` pins this. It fails when
`rules/settings.json` gains a hook that has no row here, and when a deny path
of secret-read-guard, iron-law-guard (crash path included) or `_fence.sh`
stops exiting 2.

## The deny layer

- Knob: `DENY_GUARDRAILS` (lib `deny-guardrails`,
  `catalog/lanes.d/_lib.deny-guardrails.json`). Rows
  `lib.deny-guardrails.deny_guardrails` (fleet) and
  `lib.deny-guardrails.<project>.deny_guardrails` (one project). Default 0.
  Only the literal `1` turns it on.
- `bin/deny-guardrails-settings.json`: `permissions.deny` prefix specs for
  `git push` to main/master (with `-f`/`--force` and `HEAD:` forms), `gh pr
  merge`, `prisma db push`, `prisma migrate deploy`, `vercel deploy --prod`,
  `vercel --prod` and `vercel promote`. Each spec has an `rtk` twin, because the
  rtk hook rewrites the command.
- `bin/agent-call.sh`: on the guarded lanes (`IRON_LAW_LANES`) with the knob on,
  the fragment goes into the merged `--settings` before the guard, and its specs
  go into the one `--disallowedTools` flag. A missing or empty fragment writes
  one `deny layer MISSING` ALERTS line and the call runs on the hook guard.
- `bin/iron-law-guard.sh` family 8, guarded lanes only, knob on:
  - `dg-api-merge`: `gh api` PUT `…/pulls/<n>/merge`, POST `…/merges` (fields
    with no `-X GET` imply POST), graphql `mergePullRequest` /
    `enablePullRequestAutoMerge`.
  - `dg-d1-remote`: `wrangler d1 execute … --remote` with a write keyword or a
    `--file`, and `wrangler d1 migrations apply … --remote`.
  - `pnpm|yarn|bun <prisma|vercel|vc|wrangler|gh|git> …` is judged one level
    down, so `pnpm prisma db push` meets family 3.
  - Each block is one `family=actguard-dg-*` row in `logs/findings.log`, exit 2.

`wrangler d1 execute` is not in the prefix list on purpose. A prefix cannot see
`--remote` at the end, and a prefix deny would also block local runs.

## What stays allowed

- `bin/archie-merge.sh`, the merge conductor, the merge queue and run-build's
  tier-1 step: no spec and no family matches them, and the merge lanes are plain
  bash with no hook.
- The harness's own push of a ticket branch (`HARNESS_LANE` unset) and pushes
  from non-guarded lanes (orchestrator, box-chat, greenfield). A guarded lane's
  own `git push` stays denied as `agent-push` (BH-2741), as before.

## Limits

`npm run <script>` aliases, wrangler on codex lanes (no wrangler shim), `gh api`
with the method or path in a variable, and `wrangler deploy` get through family
8. Prefix specs see only the start of the command.

## Roll-out (operator)

1. Set `lib.deny-guardrails.cromford.deny_guardrails=1`.
2. Watch `grep 'family=actguard-dg-' logs/findings.log` for one day.
3. Confirm one gated merge through the merge conductor or `bin/archie-merge.sh`
   lands with the row on.
4. Then set the fleet row `lib.deny-guardrails.deny_guardrails=1`.
