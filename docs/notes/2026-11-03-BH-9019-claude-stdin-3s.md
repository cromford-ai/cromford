# BH-9019: the fresh orchestrator turn composes its prompt before claude starts

Doc: OPERATING

## What failed

Claude Code 2.1.317 waits 3 s for stdin when `-p` has no prompt argument. If no
byte arrives in that time, it prints `Warning: no stdin data received in 3s,
proceeding without it.` and `Error: Input must be provided either through stdin
or as a prompt argument when using --print`, and exits 1.

`bin/orchestrate.sh` `run_turn` (fresh path) ran
`compose_v2_prompt | ... "$ORC_CLAUDE" -p ...`. Claude started at once, but the
compose took 34.9 s on the hub when `archie_repo_activity_block` was slow. The
timer fired, both model rungs exited 1, and the turn fell to the survival lanes.

## What changed

The fresh path now runs `prompt=$(compose_v2_prompt)` to completion first, then
starts claude with `<<<"$prompt"`. Bash writes the whole here-string before it
executes the command, so the first byte is there when claude reads stdin.

- The prompt stays on stdin, not argv. Linux caps one argv string at 128 KiB
  (MAX_ARG_STRLEN), and STATE.md, history and the soul can pass that.
- The argv that claude and `bin/claude-cost.sh` receive is byte-identical.
- The `-c` continuation path and the "no conversation" retry pass the prompt as
  argv already. They do not change.
- `timeout 3600` now covers claude only, not the compose.

## Rule for the next reader

A caller of `claude -p` must not depend on a fast pipe. Write the whole prompt
before claude starts, or pass it as argv when it is small.

## Test

`tests/orchestrate-stdin-delay.bh-9019-test.sh` lifts the real `run_turn` and
drives it with a fake claude that imitates the 3 s stdin rule and a compose that
takes 4 s. A control case runs the old pipe shape and proves the fake fails the
way the CLI does.
