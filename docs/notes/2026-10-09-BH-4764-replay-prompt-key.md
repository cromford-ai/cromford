# Replay a lane prompt: the `prompt:` key (BH-4764, slice 1 of #4760)

Doc: OPERATOR-SETUP

## What changed

- `bin/archie-skill-replay.sh` reads an optional `prompt: <path> [<path> ...]`
  line in a SKILL.md frontmatter. The paths are repo-relative and resolve
  against the runner's own repo, not against `--root`. When the key is set, the
  prompt head is those paths in order, and the SKILL.md body is not used. A
  file adds its bytes and one newline. A directory adds its `*.md` files in glob
  order and one newline.
- A path that is absolute, contains `..`, resolves outside the repo, is missing
  or unreadable, or is a directory with no `*.md` gives one line
  `FAIL <skill> prompt <path> <reason>` and rc 1. No case of that skill runs.
- With no `prompt:` key the runner does what it did before. The default root
  `orchestrator/skills` and `bin/archie-learn.sh` do not change.
- New replay root `catalog/prompts/replays/` (README there). Its first entry,
  `archie-check`, replays the soul plus `catalog/prompts/archie-check.md`
  against 2 recorded checks. Run: `bin/archie-skill-replay.sh --root catalog/prompts/replays`.
- `catalog/prompts/archie-check.md` has a new section,
  `## When the metric is unreadable`. When `check.metric_unreadable` is true,
  the answer names the metric by its `metric_query` and recommends
  `ticket-file` or `watch-cadence`. Line 2 is never blank in that case.

## Why the directory form

The ticket names `prompts/archie-soul.md`. BH-5244 replaced that file with
`prompts/archie-soul.d/*.md`, and `bin/archie.sh` reads it as
`cat prompts/archie-soul.d/*.md; printf '\n'`. The directory form gives the
replay head the same bytes as the live prompt, and a new soul section reaches
the replay with no SKILL.md edit.

## Not done here

`bin/archie.sh` does not write `metric_unreadable` yet. A sibling slice of
#4760 adds it. Until then the new section has no live trigger, and only the
replay case 01 exercises it.
