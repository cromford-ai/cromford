# BH-1336: the committed rules render gets a direct CI check and a regenerate row

**What changed.** Two guards that main's other renders already had, now on
`rules/CLAUDE.md`:

1. `.github/workflows/harness-ci.yml`'s `lane renders generate and their
   sources validate` step runs `bin/render-rules.sh --check` beside the three
   sibling `--check` lines. A CHECK and never a `--write`: this is the one
   render in that step which IS committed, and writing it first would erase the
   drift the line exists to catch. Under the step's `set -euo pipefail` an rc 1
   (drift), rc 2 (cannot render) or rc 3 (a refused topic) fails the job.
2. `docs/verification-map/index/tail.md`'s `## Generated files` table gains
   `rules/CLAUDE.md` → `bin/render-rules.sh --write`, so `regen_table`
   (`bin/batch-resolve.sh`) and `mc_regen_table` / `mc_regen_generated`
   (`bin/lib/mc/rebase.sh`, the conductor and pool rebases) regenerate it over a
   merged tree instead of hand merging two siblings' renders. The repo's
   Verification Contract in `CLAUDE.md` runs the same `--check` over a union, so
   a regenerate that did not work stops the train rather than landing.

**Why it was needed.** BH-561 made `rules/CLAUDE.md` a render of
`rules/topics/*.md` and left it COMMITTED, because five scripts copy it verbatim
onto every box (`bin/update-runners.sh`, `bin/sync-agent-rules.sh`,
`fly/builder-runner.sh`, `bin/rules-drift-check.sh`, `bin/context-signature.sh`).
That is the pre-BH-1247 shape: the only reader of the drift was
`tests/render-rules-test.sh` B6, which runs when test-impact SELECTS it, and the
file had no regenerate row at all — #853 needed a hand commit for exactly that
drift. Two siblings that each add a topic collide in the generated
`## Contents` list, and a hand merge of a table of contents is a file nobody
wrote.

**What did NOT change.** None of the five consumers. Item 3 of the ticket
(render at install time, so `rules/CLAUDE.md` can join the
generated-not-committed set under the BH-1247 doctrine) is a separate
ticket-sized change in the ticket's own words, blocked on this one; the file
stays committed and stays in git here. No `.gitattributes` line either: a union
driver concatenates both sides of a hunk, which is what the regenerate row
replaces.

**Verification.** `tests/render-rules-guards.bh-1336-test.sh` (new): both
production parsers print exactly one row for the path and none for its inputs or
the renderer (extracted by function name, so a rename is red, not green); two
sibling branches on real git that each add a topic and re-render conflict in
`rules/CLAUDE.md` and nowhere else, the union resolution (take one side, then
`--write`) is drift-free and keeps both edits, and the real
`mc_regen_generated` produces exactly one `regenerate rules/CLAUDE.md …` commit
that leaves `--check` green; the workflow step located by its `name:` carries
the check and no write, with a mutated-workflow negative so the reader cannot
pass on nothing; the drift and refused-topic exit codes the CI line turns red
on; and the shipped banner clause. `tests/generated-files-train-test.sh` (GT-2)
and `tests/verification-map-no-commit-test.sh` (NC-4) pin the new row in both
row lists.

Doc: render-rules, generated-files-train
