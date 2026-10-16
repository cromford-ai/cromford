# A conflict round gets a brief that can resolve it (BH-6964)

Doc: MERGE-CONDUCTOR

## What changed

When the round's own merge leaves conflicted paths, `br_fix_round` keeps the markers paragraph and
appends three parts:

- the rule file `prompts/fix-round.d/conflict.md` ("Resolve the conflict only. Make no other
  change."; if the file is not readable, that one line and a log line that names the file);
- the merged-in side's diff of the first 5 conflicted paths since the merge base;
- the plan this PR was built from (`.harness/specs/<KEY>/plan.md` on the branch, else the build
  record's `plan.md`, else a `not found` line).

`BR_CONFLICT_BRIEF_BYTES` (6000) bounds the diff and the plan excerpt each, and 0 omits both.

Each spent round on a conflicted merge appends ` · fix-round-conflict ok lines=<n>` (pushed) or
` · fix-round-conflict failed lines=<n>` (every other spent exit) to the detail of its
`fix-round` / `fix-round-noop` attempt row. `<n>` is the record's `conflict_lines`, or `unknown`
when it was never measured. A round that was not spent (`fix-round-held`) and a round whose merge
did not conflict carry no such text.

## Knobs

| knob | default | meaning |
|---|---|---|
| `BR_CONFLICT_FIX_ROUNDS` | 2 | fix rounds for a **small** conflict; wins over `BR_MAX_FIXROUNDS_SMALL` when set |
| `BR_CONFLICT_BRIEF_BYTES` | 6000 | byte bound on the diff and on the plan excerpt each; 0 omits both |

The shape table in MERGE-CONDUCTOR.md ("small" row, fix rounds column) reads
`BR_CONFLICT_FIX_ROUNDS` first, then `BR_MAX_FIXROUNDS_SMALL`.
