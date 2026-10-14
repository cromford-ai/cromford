# BH-1175 — the verification-map index is generated, not committed

**Ticket:** [#1175](https://github.com/example-org/cromford/issues/1175), the
first of the conflict-reduction epic [#1179](https://github.com/example-org/cromford/issues/1179).

**What it changes.** `docs/verification-map/README.md` is git-ignored.
`docs/verification-map/entries/<TICKET-KEY>.md` stays the committed source, one
file per ticket, conflict-free by construction. The generator still writes the
index; CI, the share mirror and every box build it where they need it.

**The number that decided it.** The file was touched by 105 of the last 200
merges to main, conflicted on every rebase of the 2026-09-20 drain, and turned
main red three times in one day (e71b2de1, dd2cee5a, 855c0b42) when the
`merge=union` driver duplicated a row on a squash merge and the drift check then
refused the result.

**What it touches.** `.gitignore`, `.gitattributes`,
`bin/verification-map-build.sh`, `bin/batch-resolve.sh`,
`bin/lib/merge-conductor-lib.sh`, `bin/verification-map-retrofit.sh`,
`bin/harness-sync.sh`, `bin/publish-share.sh`, `bin/readiness-report.sh`,
`bin/planned-files-cheap.sh`, `.github/workflows/harness-ci.yml`, `CLAUDE.md`,
`tests/verification-map-no-commit-test.sh` (new),
`tests/verification-map-build-test.sh`, `tests/generated-files-train-test.sh`,
`tests/verification-map-retrofit-test.sh`, `tests/guardrails-test.sh`,
`tests/state-restore.bh-449-test.sh`, and the lane docs.

**The two decisions worth remembering.**

1. **The `## Generated files` table had to move home.** Both parsers read it
   through `git show <ref>:<path>`, which answers nothing for a path that is not
   in the tree — so taking the README out of git would have read as an EMPTY
   table, and `bin/batch-resolve.sh`'s own rule is that a repo declaring nothing
   exits having done nothing. The batch merge train would have switched itself
   off, silently, on the repo its conflict tail was built for. Both parsers now
   read `docs/verification-map/index/tail.md`, the file the table was always
   generated from, and dedupe so a repo carrying both spellings declares each row
   once.

2. **`--check` split in two.** Plain `--check` grades the committed SOURCES (no
   duplicate row, every document link resolves, no tracked index). The old byte
   comparison lives on as `--check-committed`, because
   `mc_resolve_vmap_clean_merge` and `bin/verification-map-retrofit.sh` use "this
   README does not rebuild to itself" as their REPAIR TRIGGER, on target repos
   that still commit their index. Pointing them at the new `--check` would have
   had them answer "nothing to repair" for ever — a lane retired by a change to
   a neighbour, which is the failure this repo keeps meeting.

**What a build does differently now.** Write the feature document, write
`docs/verification-map/entries/<TICKET-KEY>.md`, run
`bin/verification-map-build.sh`, and commit the first two. Not the index.

**The third decision, found in review.** "The drain's rebase step resolves the
deletion" was not true of the harness's own resolvers. Taking a committed file
out of git makes a MODIFY/DELETE for every branch that still commits it, and git
leaves a modify/delete with no conflict markers — so the marker-based `*.md`
union arm fails on it and `mc_resolve_conflicts` returned it as a REAL conflict.
With 48 of 63 open PRs in that shape that is 48 Opus fix rounds on day one, and
in `build_union` the declared-path arm's `checkout --theirs` + `add` re-tracked
the file, so every batch went red against its own `--check` and split in half.
`mc_resolve_deleted_ignored` (and its twins in `bin/lib/mc/rebase.sh` and
`bin/batch-resolve.sh`) now take the deletion, and only where the merged tree's
own `.gitignore` says the path must not be in git.

**The fourth, also found in review.** The build primer is rendered with
`--repo "$WT"` — the build worktree, which `git worktree add --detach` creates
with no ignored files. `bin/harness-sync.sh` regenerates the harness checkout,
not that worktree, so every cromford build would have planned against "this
repo has not adopted the verification map" for a map with 113 entries.
`ensure_index` in `bin/verification-map.sh` builds it, and the "not adopted"
branch now keys on an entry count of zero rather than on the index file.

**Deploy coupling.** The CI workflow, the share mirror and `bin/harness-sync.sh`
land together in one merge, so no box or reader is ever between the two halves.
Every open PR carrying a README regeneration commit meets the deletion once, and
the rebase lanes resolve it mechanically.
