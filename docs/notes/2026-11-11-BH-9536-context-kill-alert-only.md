# 2026-11-11 — BH-9536: the context kill is alert only

## Decision

the operator, 2026-11-11: the context kill in `bin/agent-call.sh` (`context_meter`) is alert
only. This is the standing rule of 2026-10-14: a tripwire alerts and never stops a build.

## Cause

In the 7 days to 2026-11-11, 8 plan sessions ended
`RUNNER_ERROR class=real-failure(budget_stop)` from the meter. Example: BH-9454, plan on
claude-opus-5-5, killed at 725 s with 7,616,046 cache-read tokens against a 7,500,000
bound. It had written 48,752 output tokens. No plan was kept, and the ticket planned
again from zero.

## What changed

- A session over its bound gets one line and one job event. The bound is the
  cumulative `context_kill_tokens`, the cliff-lowered bound (`$OUT.cliffcap`) or the
  declared per-call `ceiling_tokens`.
- The line: `CONTEXT OVER BOUND (alert only): <stage>/<project> ticket=<tk> model=<m>
  session=<sid> rule=<cumulative|cliff|declared> bound=<b> total=<t> calls=<c>
  level=<1x|Nx> — the session continues; no kill`. It goes through `bin/alert-line.sh`
  (id `context-over:<stage>/<project>/<sid>/<rule>/<level>`, severity warn), which
  writes `logs/ALERTS.log`.
- The job event: verdict `CONTEXT_OVER`, detail `rule= bound= total= calls= session=
  level=`. It is not `BUDGET_STOP`.
- A second line at `CONTEXT_KILL_ALERT_X` times the bound. At most
  `CONTEXT_KILL_ALERT_MAX` lines per session (one meter process).
- No `$OUT.ctxkill`, no TERM, no checkpoint brief. `BUDGET_STOP`, `CTX_STOP` and the
  ladder class `budget_stop` stay unset. The session runs to its own end or to the
  stage time cap (`timeout "$TO"`).
- The prefix is not `CONTEXT KILL` or `CLIFF-AVOIDED:`, so the readers of a stopped
  session (watchdog-responder, review-autopilot, `ctx_kill_repeats`) do not read it.

## Knobs (`catalog/lanes.d/_lib.context-kill-mode.json`)

| Settings row | Env | Default | Meaning |
|---|---|---|---|
| `lib.context-kill-mode.context_kill_mode` | `CONTEXT_KILL_MODE` | `alert` | `kill` = the BH-653 stop for every stage. Any other value is alert. |
| `lib.context-kill-mode.context_kill_mode_kill_stages` | `CONTEXT_KILL_MODE_KILL_STAGES` | empty | Stages that use kill mode (space or comma list, or `all`). |
| `lib.context-kill-mode.context_kill_alert_x` | `CONTEXT_KILL_ALERT_X` | 2 | The multiple of the bound for the second line (2 to 100). |
| `lib.context-kill-mode.context_kill_alert_max` | `CONTEXT_KILL_ALERT_MAX` | 2 | Lines per session (1 to 10). |

## How to go back to kill

1. Set `lib.context-kill-mode.context_kill_mode` to `kill` (every stage), or
2. Set `lib.context-kill-mode.context_kill_mode_kill_stages` to the stages to stop
   (for example `alert-triage responder`).

`flags/context-kill-off` and `CONTEXT_KILL=0` still turn the meter off in both modes.

## Not changed

The BH-4488 budget cap (`BUILD_REFUSED BUDGET_STOP`), the no-progress stop
(`$OUT.noprogress`), the tripwire stop (`$OUT.tripwire`) and `ctx_kill_repeat_refuse`.
The repeat refuse counts only kill rows in `cost.csv`; alert mode writes none.

## Owed

The measured target: in the 7 days after the merge, 0 plan sessions end
`class=real-failure(budget_stop)` from the context meter, and each session over its
bound has 1 or 2 alert lines. That is not testable at PR time.

Verified by `tests/context-kill-alert-only.bh-9536-test.sh`.
