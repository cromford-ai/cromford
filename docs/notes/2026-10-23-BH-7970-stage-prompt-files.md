# Stage prompts are files in prompts/stages/ (BH-7970, BH-7940.2)

Doc: PROMPTS

## What changed

- The plan, execute, review, fix-round and qa stage prompts moved, byte for
  byte, from inline strings in `bin/lib/rb/{plan,execute,review,pr}.sh` to
  `prompts/stages/<kind>.md`.
- `bin/lib/stage-prompt.sh` renders a template with `sp_render <kind> [<outvar>]`.
  It reads `$HARNESS/state/prompts/$PROJECT/<kind>.md` when that file is not
  empty, else the repo file. It replaces `${NAME}` only for a name in the
  whitelist `SP_VARS`, in one pass, with no eval.
- A missing template stops the stage with `BUILD_REFUSED prompt template
  missing (<kind>)` and no runner call. For qa, the build goes on with
  `QA: FAIL`, screens=0 and tier 2.
- Each rb stage sources the lib inside its `rb_*` function, not at module top
  level. `tests/rb-modules-source-test.sh` requires that sourcing a module
  defines only `rb_*` entries.
- `tests/stage-prompt.bh-7970-test.sh` compares each render with the old
  string, kept in `tests/fixtures/stage-prompt.bh-7970/` (captured at c73cc1b2).

## Found during the move

The old plan string held `` `bin/size-scope.sh --rules` `` inside double
quotes. Bash ran it as a command substitution, so the plan prompt carried the
command's output (in a repo without that script: nothing, plus a stderr line),
not the literal command name. The move keeps those bytes:
`SP_PLAN_SIZE_SCOPE=$(bin/size-scope.sh --rules)` is computed before the render.
A later ticket decides whether the prompt should name the command instead.

## Rules and commands it touches

- `sp_render`, `SP_VARS`, `SP_SOURCE_<kind>`, `SP_STAGES_DIR` (a path override
  for tests, not a knob).
- `bin/prompt-resolve.sh <project> <kind>` now finds the repo file for the five
  stage kinds (it exited 4 before).
