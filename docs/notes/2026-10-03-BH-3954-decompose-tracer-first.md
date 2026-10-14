# Decompose tracer-first: child 1 is an end-to-end path, siblings slice by capability (BH-3954)

Doc: RUN-BUILD-GRAPH

## What changed

`bin/run-decompose.sh` no longer asks for a stub contract. Child 1 of a split is
the **tracer**: the thinnest path from a real trigger (user action, cron tick,
webhook) to a persisted result to an outcome someone can observe (a preview
screen, an API response, or a real row or log line for no-UI work). It keeps
everything the filing mechanics key on: the `<KEY>.0: contract — <slice>` title,
the `CONTRACT:` line (now the names and paths the tracer really lands, which the
siblings import as working code), `Blocked-by: #<.0> (hard)` on every sibling,
the `CONTRACT_MAX_LINES` (60) budget and the two-level chain cap.

- Both decomposer prompts (issues lane and board lane) say TRACER FIRST, tell
  siblings to add one capability end to end, and call a layer split ("UI child",
  "API child", "worker child", "schema child") a decomposition failure, the same
  as a chain.
- Every child body carries a `## Observable outcome` section: the one
  end-to-end acceptance test, or the real row/log line for infra/migration, plus
  QA screens when there is UI.
- On the issues lane the spec is checked deterministically after the chain cap
  and before anything is filed. A child whose body has no line starting with
  `Observable outcome` (heading, bold or bare, case-insensitive) with text after
  it is refused as `DECOMPOSE_FAILED`, naming every failing position. A spec
  whose filing already started (`children.txt` non-empty) is not re-checked, so
  a half-filed split from before this change can still finish.
- The board lane files its own children, so there the prompt is the only lever.
- The filed child-1 body (`fc_child_footer` in `bin/lib/file-children.sh`) now
  tells its builder it is the tracer, not "stubs that compile".

## Correction

`docs/RUN-BUILD-GRAPH.md` ("Interface first: one contract child") still says the
contract is "types, … stubs that compile and do nothing useful yet". That is no
longer true: the first child is the end-to-end tracer described above. The
wave, `Blocked-by` and chain-cap parts of that section are unchanged.

`prompts/plan-contract.md` §2 and the Rollout section of `skills/harness/SKILL.md`
say the same thing for hand-planned work: unit 0 / wave 1 is the tracer.

Rollouts (`bin/run-rollout.sh`) are unaffected: they never pass through the
decomposer's validator.

Suite: `tests/decompose-tracer-first.bh-3954-test.sh`.
