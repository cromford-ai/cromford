# Stage iron laws: one law-set directory, added by agent-call.sh (BH-6557)

Doc: CONTEXT-COMPOSITION

## What changed

- New directory `prompts/iron-laws.d/`. One file per law set. Line 1 is
  `stages: <stage> <stage> ...` (the stage names `bin/agent-call.sh` gets as its
  first argument). Line 2 is empty. Line 3 to the end is the law text.
- New file `prompts/iron-laws.d/20261013-performance-prototype.md`. It holds the
  two blocks of the ticket verbatim: PERFORMANCE BY DEFAULT and BUILDING FROM A
  DESIGNER'S PROTOTYPE (both 2026-10-13). Its stage line is
  `preplan plan execute fix review qa prodqa`.
- New lib `bin/lib/stage-iron-laws.sh`, function `sil_text <stage> <dir>`. It
  prints the body of every file in `<dir>` whose stage line names `<stage>` as
  a whole word, in file-name order, with one empty line between bodies. A file
  with no `stages:` line 1 is skipped. No match prints nothing.
- `bin/agent-call.sh` calls `sil_text "$STAGE" "$HARNESS/prompts/iron-laws.d"`
  once, right after it sets `HARNESS`. If the text is not empty, it goes into
  `AGENT_SYSTEM_APPEND` after any caller value (one empty line between), and
  `AGENT_SYSTEM_APPEND` is un-exported for that process.

## Why

The ticket asks for the two blocks in every stage prompt that lists iron laws.
Earlier plans edited the prompt text in 13 stage scripts. Six of those builds
stopped as OVERLAP_DEFER, because a live build always held one of the 13 files.
Every one of those stages already calls the model through `bin/agent-call.sh`
with a stage name, and that script already has one system-prompt channel,
`AGENT_SYSTEM_APPEND`. So the laws live in one shared file and the one call
seam adds them. The ticket allows this shape ("put the blocks in one shared
file the prompts include").

## How it reaches each runner

- claude: the one `--append-system-prompt`. The advisor consult line joins the
  same value, as before.
- codex, gemini, grok, openrouter, fireworks: `rules_append` puts
  `AGENT_SYSTEM_APPEND` in front of the prompt text, as before.
- The prompt text is not changed, so `PROMPT_SHA` (the call-guard fingerprint)
  does not change.

## Stages

In: `preplan`, `plan`, `execute`, `fix`, `review` (tier review, re-reviews, the
PR-review lane and the other reviewers that call stage `review`), `qa` (preview
QA) and `prodqa` (post-merge QA).

Out: `lead-review`. Its prompt files are on the lead-protected path list. A
human lead verdict must approve a change to that stage's instructions, so this
seam does not go around it. To add it, put `lead-review` on the stage line in a
PR that a lead approves. Every other stage (`triage`, `preplan-files`, `chat`,
`orchestrator` and the rest) is not a build stage and is out.

## How to change it

- Add a stage: add its name to the `stages:` line of the law set.
- Add a law set: add a new file in `prompts/iron-laws.d/`. Do not append to an
  existing one.
- Deploy: `bin/harness-sync.sh` rsyncs `prompts/` and deploys `bin/` to
  `$HARNESS`; the Fly pool tarball carries `bin` and `prompts`. A box with no
  `prompts/iron-laws.d/` adds no text, and the call runs as before.

## Size

The law set is about 2.6 KB, about 660 tokens. The smallest token target of a
member stage is `preplan` at 60000 tokens, so the text is about 1.1% of it.
`tests/stage-iron-laws.bh-6557-test.sh` (A7) checks that it stays under 5%.

## Tests

`tests/stage-iron-laws.bh-6557-test.sh` drives `bin/agent-call.sh` with fake
CLIs for each member stage and for `triage` and `lead-review`.
