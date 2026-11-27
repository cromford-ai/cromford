# 2026-11-26 BH-10233: the Navigation Registry iron law

What changed:

- `rules/topics/20-navigation-registry.md` is a new fleet-rules topic. `bin/render-rules.sh --write` renders it into `rules/CLAUDE.md`, so every box's `~/.claude/CLAUDE.md` carries it.
- `prompts/iron-laws.d/20261126-navigation-registry.md` carries the same law body for the stages `plan execute review lead-review`. `bin/agent-call.sh` appends it to each of those stages' system prompt through `sil_text`. `preplan` and `fix` do not carry it: with them, the law text of the counted stages is about 3,124 tokens, over the 3,000-token cap (5% of the smallest target) in `tests/stage-iron-laws.bh-6557-test.sh` A7. With these four stages it is 2,981 tokens. A fix round acts on BLOCKs, and the law's review flags are NOTEs.
- `prompts/lead-review-checklist.md` has item 18 and is `Checklist-Version: 12`. Item 18 makes a new hard-coded page address, a page move by search-and-replace and a menu label that differs from its page heading a `[NOTE]`. A moved page with no redirect or a dead menu link stays `[BLOCK core-flow-broken]`.

Why: project-3 OS held its navigation facts in 3 lists and 1,877 literal page addresses in 685 files. One page move touched 48 to 110 files. project-3 PR #1728 fixed it with one page registry. This law makes that the fleet default for every project with an app menu.

No new ALWAYS-BLOCK class. No script under `bin/` or `worker/` changed. No project repo changed.

Tests: `tests/iron-law-nav-registry.bh-10233-test.sh` (N1 to N6). `tests/stage-iron-laws.bh-6557-test.sh` re-pins the plan-stage law sha. `tests/coverage-review.bh-9499-test.sh` pins checklist v12.
