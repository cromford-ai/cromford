# The context kill is armed at the declared ceiling (BH-9124, slice C2 of BH-9064)

Doc: CONTEXT-COMPOSITION

## Why

The context meter in `bin/agent-call.sh` compared only the cumulative session
total (`input + cache_read`) with `context_kill_tokens` (53.6M on execute). A
lane with no `context_kill_tokens` was not metered at all. The declared
per-call ceilings (`ceiling_tokens` in `catalog/context-budgets.json`) were
never enforced: an execute session with one 500,001-token API call ran on.
This is the port of r3 (branch `ticket/bh-9064-r3`) for the meter only,
adapted to C1 (BH-9123) as merged.

## What changed

- `bin/transcript-cost.sh --peak` (opt-in) appends one last field: the
  largest context of one API response (`input + cache_read + cache_write` of
  that response). It is field 10, or field 11 after `--price-version`. Without
  the flag the line is byte-identical.
- `_ctx_declared_row <stage> [project] [runner]` prints the armed
  `ceiling_tokens` of a stage. Same specificity ladder as `_ctx_kill_ceiling`.
  A lane is armed when its stage is in `CONTEXT_KILL_DECLARED_LANES`, the list
  is `all`, or its row carries `declared_kill: true`. `CONTEXT_KILL=0` and the
  `context-kill-off` switch turn it off.
- `context_meter` has a second check after the cumulative one (which still
  wins on the same poll). Over the declared ceiling (strictly greater) it writes
  `$OUT.ctxkill` as `rule=declared ceiling=<C> peak=<P> total=<T> calls=<n>
  session=<sid> unit=<u>`. On execute and fix in a build dir it then writes the
  C1 brief `$BUILD/checkpoint-brief.md` (`ecb_write`, fail-open). Then it
  sends the TERM. A peak that cannot be read never kills.
- `run_attempt` starts the meter when the cumulative cap OR the declared
  ceiling is set. The UNENFORCEABLE alert names both numbers.
- `ctx_kill_alert` says `killed by rule=declared at a <P>-token API call
  against the declared ceiling <C>`. The cost row note is
  `context-kill:ceiling=<C>:...`, so `ctx_kill_repeats` (BH-2538) counts it.

## Knobs (`catalog/lanes.d/_lib.context-kill-declared.json`)

| knob | settings row | default |
|---|---|---|
| `CONTEXT_KILL_DECLARED` | `lib.context-kill-declared.context_kill_declared` | `1` (kill); `0` off; `observe` = one log line per session in `logs/claude-cost.log`, no kill; any other value is observe |
| `CONTEXT_KILL_DECLARED_UNIT` | `lib.context-kill-declared.context_kill_declared_unit` | `peak`; `cumulative` compares the session total |
| `CONTEXT_KILL_DECLARED_LANES` | `lib.context-kill-declared.context_kill_declared_lanes` | `plan execute review fix lead-review` (400K, 500K, 400K, 400K, 200K); `all` arms every lane with a ceiling |

## Rollout

1. To watch before a kill, set the row `lib.context-kill-declared.context_kill_declared` to `observe`.
2. Read the `CONTEXT KILL DECLARED (observe)` lines in `logs/claude-cost.log`.
3. To stop the declared kill, set the same row to `0`. No deploy is necessary.

## Evidence

A kill: `$OUT.ctxkill` with `rule=declared`, and the alert line
`CONTEXT KILL: <stage>/<project> ... killed by rule=declared`. Verified by
`tests/context-kill-declared.bh-9124-test.sh`.
