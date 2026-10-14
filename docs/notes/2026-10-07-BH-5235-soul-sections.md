# How to add an Archie soul section (BH-5235.1)

Doc: OPERATOR-SETUP

The split of `prompts/archie-soul.md` into section files is in
[2026-10-07-BH-5244-archie-soul-sections.md](2026-10-07-BH-5244-archie-soul-sections.md).
This note tells you how to add a section.

## Add a section

1. Pick a two-digit prefix that no file in `prompts/archie-soul.d/` uses.
2. Create `prompts/archie-soul.d/NN-<slug>.md`. The name must match
   `^[0-9][0-9]-[a-z0-9-]+\.md$`.
3. End the file with a newline.
4. Do not edit a sibling's section to add yours.
5. Change the count in P2 (`exactly 8 fragments`) of
   `tests/prompt-sections.bh-5235-test.sh` in the same PR. P2 pins the count.

The readers concat the files in glob order, so the prefix sets the place of
the section in the prompt. `tests/prompt-sections.bh-5235-test.sh` checks the
name rule (P2) and the final newline (P3).

## The stale `archie-soul.md` on the hub

`bin/harness-sync.sh` copies `prompts/` with `rsync -a` and no `--delete`.
The hub keeps the old `/root/harness/prompts/archie-soul.md` after the sync.
No reader uses it. It is harmless. Do not edit it: a change there has no
effect on any prompt.
