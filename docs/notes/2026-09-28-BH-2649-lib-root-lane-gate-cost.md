# lane-gate, jobs/req, endpoints and the cost libs: no literal /root/harness root (BH-2649)

Doc: LIB-ROOT-RESOLUTION

BH-2613.1 (#2649), part 2 of 5 of #2613. It applies rules 1-6 of
`docs/notes/2026-09-26-BH-2613-lib-root-resolution.md` to six libs and adds
rule 4 to the entry points that reach them without a root.

## What changed

The root is `${HARNESS:-${H:-}}` in each lib, and "" when neither is set:
`_lg_h` in `bin/lib/lane-gate.sh`, the new `_cost_row_root` in
`bin/lib/cost-row.sh`, the new `_cost_rows_root` in `bin/lib/cost-rows-read.sh`
and `_CB_H` in `bin/lib/cost-budget.sh` (still set at source time).
`bin/lib/endpoints.sh` builds its lane-gate path from that root only when it is
non-empty, and otherwise sources the lane-gate beside it.
`cost-rows-read.sh` run directly (rule 3) falls back to its own install root
(`_CRR_SELF`) after HARNESS and H.

With no root, these write nothing and read no file:

- **lane-gate.** No registry (`_lg_registry` prints "" and memoises nothing), no
  settings cache and no `GET /api/settings`, so knobs fall to env and then the
  caller's own default. No flag file is read. After `flag_sync` the answer is
  that file, so it reads as running, the same as an unreadable flags dir. Only a
  caller-loaded `flag_active` (no `flag_sync`) can pause a lane. A pause still
  exits 0. No `.paused`,
  `.post-miss`, `.seen-*`, `.logged-*`, `.harness-commit-sent` or
  `.settings-miss` stamp is written, and no `logs/lane-gate.log` or ALERTS line.
  The liveness and flag-seen POSTs still send when a client is loaded, so the
  next tick sends again.
- **`_lg_harness_commit`.** `HARNESS_CHECKOUT` wins. Otherwise it reads
  `$root/../harness-checkout`, which is `/root/harness-checkout` when the root is
  `/root/harness`. With no root there is no sha.
- **`bin/lib/jobs/req.sh`.** The new `_jobs_root_writable` requires a non-empty
  `JOBS_HARNESS` with a writable `logs/`. When it fails, `_jobs_log` and
  `_jobs_not_configured` return 0 and write no log, ALERTS line or daily flag.
  Their appends are wrapped as `{ … >> f; } 2>/dev/null`, so a refused `>>`
  prints nothing. This removes the "Permission denied" lines that a suite run as
  `nobody` printed from `lane-down-lib`. `_jobs_box_name` skips `state/box-name`
  when `JOBS_HARNESS` is empty. `bin/jobs-client.sh` keeps its entry-point
  default.
- **cost-row.** `cost_parity_alert` returns 1 (not alerted). `cost_transcript_enabled`
  and the fallback `lane_switch` stub read no flag file (enabled and off, as
  for an unreadable dir). `cost_row_box_id` reads no `state/box-id`, and
  `COST_ROWS_BOX`, `box_id_get` and `BOX_ID` still answer. `_cost_prices_table`
  drops the two root candidates and keeps the sibling catalog and
  `/root/harness-checkout`.
- **cost-rows-read and cost-budget.** `_cost_rows_log` returns 0. The root
  candidates for lane-switch, jobs-client, cost-caps and model-prices are
  dropped, and `conf_row_note_file` is not called.

Rule 4, `H="${HARNESS:-${H:-/root/harness}}"` before the first source line, is
now in `bin/ci-runners-status.sh`, `bin/transcript-cost.sh` (inside `_TC_KV`),
`bin/update-runners.sh`, `bin/test-impact-gate.sh` and `bin/pr-title-backfill.sh`.
The last one reaches lane-gate through gh-rest → gh-rest-ledger →
gh-app-default. The line keeps a caller's pre-set `H`, as `_lg_h` did before.

The five baselines under `tests/fixtures/root-fallback-baseline/` for these libs
are deleted. `tests/lane-gate-no-root.bh-2613-test.sh` pins all of the above.

## Not changed

Remainder libs that source lane-gate without passing a root, such as
`bin/lib/lane-switch.sh` (`"$(_lg_h)/flags/$name"`) and gh-app-default, now see
"no root" when their entry point set neither HARNESS nor H. Every H-less
`bin/*.sh` that reaches them has the rule-4 line above. Converting those libs
belongs to #2650-#2652 and the remainder follow-up.
