# The disprove pass on a conductor re-review BLOCK (BH-9047, C1)

Doc: OPERATING, MERGE-CONDUCTOR

Slice C1 of #9047. It follows C0 (`docs/notes/2026-11-04-BH-9047-review-disprove.md`,
the lead review). C2 (the 7-day report line and the stop rule) is a later slice.

## C1: conductor re-review

`mc_rereview` (`bin/lib/mc/rebase.sh`) runs the same disprove pass as the lead
review after its parsed verdict is `BLOCK`. It uses the same lib
(`bin/lib/review-disprove.sh`), the same route `review-disprove`, the same
prompt (`prompts/lead-review.d/disprove.md`), the same knobs and the same D1
table `review_disprove_runs`, with `lane = conductor` and
`actor = merge-conductor`.

- The gate. `dpc_gate_on <project>` is on when `dp_gate` reads shadow or
  enforce (`review.disprove.<project>.enabled` = 1). Today only cromford
  is on. For every other project the re-review prompt is byte-identical to
  the prompt before C1, and no disprove call is made.
- The grammar sentence. When the gate is on, the re-review prompt asks for
  each blocking finding as one column-0 line
  `- [BLOCK <class>] <path>:<line> <text>`, and each other finding as
  `- [NOTE] <text>`. `dp_extract` reads only that shape. An answer with no
  such line is `skipped:no-finding`, and no call is made.
- The pass. `dpc_run` runs in a subshell, so the review body never sees the
  jobs client. It gets the checkout from `mc_patch_wt` (the hub clone of the
  project), fetches `origin main <head>`, and calls `mc_git_auth_clear` on
  every path after `mc_patch_wt`. The hunk base is `main`. It then calls
  `dp_review` with `DP_LANE=conductor` and `DP_DIR=<out>.dp`, and removes
  `<out>.dp` at the end. The review id is `rr`, or `rr~<MC_RR_REASON>`.
- Shadow (the seeded mode). The re-review text and the verdict do not change.
  One D1 row is posted and the conductor log gets one line
  `<slug>#<num> disprove (conductor): <result> (mode <mode>)`.
- Enforce. A droppable DISPROVED finding becomes `- [NOTE] disproved: ...`.
  When no BLOCK line and no `NEEDS_HUMAN:` line is left, the last verdict line
  becomes `VERDICT: APPROVE`. That is the conductor's clearing word, because
  `verdict_parse` reads only `APPROVE|BLOCK` (the lead lane keeps
  `MERGE-WITH-NOTES`). The report lines go above the last verdict line, and
  `mc_rereview` reads its verdict again. All of this happens before the
  `rrverdict` row is put, so that row records the final word.
- Protected lines, both lanes. A finding line that holds `GUARD_SILENCED` or
  `FRAUD:` is never dropped. In enforce it keeps its BLOCK and gains
  `| disprove-said: ... (kept: a GUARD_SILENCED or FRAUD: finding is never auto-dropped)`.
- The knob. `review.disprove.conductor_left_s` (seed 900, 60..3600, code
  fallback 900) is the time the pass may use after a re-review BLOCK. Each call
  still needs `review.disprove.min_left_s`. The day cap
  `review.disprove.usd_cap_day` is shared with the lead lane.
- A BLOCK outside the grammar, conductor lane only (refute review). The
  conductor prompt has no template and no `lr_block_no_finding` check. So in
  the conductor lane `_dp_stray_block` also holds the verdict when any line
  outside a fence has the word BLOCK, BLOCKING or BLOCKER (any case): a heading
  `### 1. [BLOCK data-loss]`, a table row `| 2 | BLOCK (money) |`, or prose.
  The last VERDICT line and the `- [NOTE] disproved:` lines do not count. Then
  every DISPROVED grammar line stays a BLOCK with `| disprove-said:`, and
  `mc_rereview` prints BLOCK. A false hold keeps BLOCK (fail closed). Tests D7, M8.

The `mc_rereview` return contract does not change: rc 0 prints APPROVE or
BLOCK. A failed pass, a failed call or a failed post leaves the BLOCK.

Tests: `tests/review-disprove-conductor.bh-9047-test.sh` (parts L, D, M, S, V).
