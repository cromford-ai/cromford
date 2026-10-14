# BH-4641: the rebase lane union-resolves append-only conflicts

Doc: MERGE-CONDUCTOR

## Why

On 2026-10-05 the conductor parked about eight PRs `conflict-unresolvable`
(#4142 x3, #4232, #4424 x2, #4478 x3, #4422 x3, #4559). Most were on
`worker/jobs/schema.sql`, and a few on `catalog/llm-sites.json`,
`catalog/context-budgets.json` and `worker/jobs/src/index.js`. In every case
both branches had only APPENDED a block at the same place: a table at the end
of the schema, an import and a spread in index.js, an object at the end of a
JSON array. The fix was always the same: keep both blocks, main's first. A
session did each one by hand, and each PR sat parked for 1–3h until then.

## What changed

`mc_resolve_conflicts` (`bin/lib/mc/rebase.sh`) has a new arm, after the
generated, regenerated and vmap-README arms and before `package.json` / `*.md`.
For a conflicted path on the allowlist it calls `mc_resolve_append_union`:

- **Pure insertion or nothing.** The merge base's lines must be a subsequence
  of the branch's file AND of main's file. That means no base line removed or
  changed anywhere in the file, not only where git conflicted. A branch that
  appends a table and also edits an old column is parked.
- **Composition.** Each side's inserted lines sit between the same base lines
  they sat between on that side. Where both sides inserted at the same place,
  main's block goes first, then the branch's. Stage 3 is main and stage 2 is
  the branch, because `mc_rebase` merges origin/main INTO the ticket branch.
  The composer aligns on the base itself and does not use `git merge-file`'s
  diff3 hunks. For a multi-line JSON object, both sides add the same `},` / `{`
  lines, diff3 treats those as common, and the hunk left over is
  `"id": "main"` against `"id": "tick"` inside a single object.
- **JSON comma tolerance.** Appending to an array or object rewrites the old
  last element `{…}` -> `{…},` on both sides. So in `.json` files one trailing
  comma is ignored when lines are compared, and a comma is added between
  main's block and the branch's.
- **Validation, or park.** `.sql` must load through python's `sqlite3`
  (`executescript` on an in-memory DB). The `sqlite3` CLI the ticket names is
  not installed on the hub, and `bin/worker-schema-upgrade.sh` already checks
  this way. `.json` must pass `jq -e .` and a parse that refuses duplicate
  keys, because both sides adding the same key is a semantic conflict that jq
  would hide. `.js` must pass `node --check`; the worktree's nearest
  `package.json` makes it ESM, so a duplicate import binding fails. `.txt` has
  no syntax check. Any other extension, or a missing tool, is a decline. Every
  decline restores the conflict exactly as git left it and logs
  `<path> left as a REAL conflict by the append-union step: <reason> (BH-4641)`.
- **Route-table fragments.** Two families that each add a
  `route-table.d/NNN-*.txt` usually pick the same next number, and git does
  not conflict on two different file names. When a union happened in the
  merge, each `<dir>/*` glob on the list is checked. A branch fragment
  appended past the base's last number, but not above main's newest, is moved
  with `git mv` to the next free number above main's newest, keeping the
  branch's own order (`680-tick-fam.txt` -> `681-tick-fam.txt`). A collision
  below the base's last number is a mid-table insertion, and it is parked.
- **Audit trail.** Each resolution appends `Union-resolved: <path> (BH-4641)`
  to MERGE_MSG, and each renumber appends
  `Union-resolved: <old> -> <new> (BH-4641, renumbered)`. `git commit --no-edit`
  keeps both, so the merge commit records what was resolved mechanically.

## The approval is not rebound

A union-resolved merge is not a clean main merge, and the resolution wrote
code nobody reviewed. Iron guardrail 1 allows a rebind only for an identical
patch-id or a clean main merge. So when the new merge commit carries a
`Union-resolved:` trailer, `mc_rebase` pushes it, skips the `reviewed-sha`
write and `job_verdict_rebind`, logs `approval deliberately NOT rebound`, and
returns rc 5. Every caller already reads rc 5 as "pushed, approval still on
the old head": `rebase_result` arm 5 leaves the row `NEEDS_REBASE
rebind-failed` with head=new and reviewed=old, and the head-bound re-review
reads the new head on the next tick.

The pool twin does the same thing. `rebase_job_run` adds an optional
`UNION: <paths>` line after `GATE:` in its RESULT, and `mc_pool_rebase_apply`
reads that `REBASED` as rc 5 with no rebind.

## The knob

The settings row `lane.merge-conductor.mc_union_files` (env `MC_UNION_FILES`,
registered in `catalog/lanes.d/merge-conductor.json`) is a comma- or
space-separated glob list. It is fleet-wide, not per project. The value `off`
turns the step off, and the old behaviour then holds exactly. The compiled
fallback `MC_UNION_FILES_DEFAULT` is the five paths above.

## What it does not do

- Semantic conflicts. Two `CREATE TABLE IF NOT EXISTS same_name` blocks parse
  fine and are kept, and so are two llm-sites objects with the same `id`.
  Identical lines both sides added are kept twice. In `.js`, `node --check`
  catches a duplicated import binding; in `.sql`, nothing does.
- A route-table number collision in a merge with no textual conflict. The
  renumber only runs when a union happened in the same merge, and CI's worker
  suite catches the rest. A new route family nearly always conflicts in
  index.js, so it usually rides along.
- A file whose last line has no newline when both sides append to it: that is
  parked.
- The md-union, package.json and generated-path resolvers, and
  `bin/rebase-train.sh`, are unchanged.
