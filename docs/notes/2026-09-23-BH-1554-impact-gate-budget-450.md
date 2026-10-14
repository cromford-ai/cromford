# 2026-09-23 — BH-1554: the impact gate's budget is 450 s, and four smaller fixes from the #1541 round-2 review

Doc: test-impact, RUN-BUILD-GRAPH

## The measurement

The #1541 round-2 review timed the builder gate on an idle Fly test host,
against this repo's own diff, with the cap at its default 80:

| budget | wall clock | what it got through |
|---|---|---|
| 300 s | ~5 min | the `self` suites and about half the `reads` pins |
| 450 s | ~7.5 min | the `self` suites plus 28 of the 30 `reads` pins |
| 900 s | ~15 min | the same 30 `reads` pins, then `named` and weaker |

Everything past 450 s is suites the always-ratchets CI run covers anyway, and
the gate can run up to three times in one build (a build, a fix round, a
rebuild), so 900 s bought about seven and a half minutes per run for two pins.

## What changed

1. **The default budget is 450 s.** `catalog/lanes.d/fly-pool.json`'s
   `TEST_IMPACT_GATE_BUDGET_S` row (`default`, and the `note`, which now
   records the measurement above) and `bin/test-impact-gate.sh`'s last-resort
   fallback for a machine with no registry at all. The budget is still a
   settings row first: nothing here hardcodes it.
2. **The registry `max` is 1250, down from 1400.** The build stage wraps the
   whole gate in `timeout 1500` and the suite that is running when the budget
   expires still has to finish; the slowest suite here is about 190 s, so 1250
   leaves 250 s of headroom. An explicit `--budget` flag is still unclamped,
   as it was before — the registry bounds govern rows and env through
   `lane_knob`.
3. **A suite the budget never STARTED is marked in the `--table` run table**
   (`(not started: budget) ` in front of its `why` cell). It used to sit in
   that table looking exactly like a suite that had run. The header's
   `ran R of N` and the `Left to CI` list are unchanged.
4. **Within a rank tier, the shortest suite runs first**, by the wall time this
   box last measured for it. The gate records those times after every `local`
   or `isolated` run, one row per suite, in
   `${HARNESS_STATE_DIR:-${HARNESS:-/root/harness}/state}/test-impact-durations.tsv`
   (`TEST_IMPACT_DURATIONS_FILE` overrides it; the `RUN_LOOP` progress file
   grew a third `seconds` field, and every reader of the first two is
   unaffected). It is a sort hint only: a suite with no recorded time sorts
   after the ones that have one (alphabetically among themselves, today's
   order), and a file this box cannot write is one stderr warning and no change
   to the rc, to what is selected, or to the verdict. `plan` and `remote`
   record nothing — remote runs in parallel, so its times are not serial
   durations.
5. **`named` no longer matches on comment lines.** `ti_named_rows` in
   `bin/test-impact.sh` skips full-line comments (`^[ \t]*#`) when matching the
   function names a changed script defines. The review counted three of six
   `named` picks as comment-only mentions, which cannot go red when the
   function changes. A trailing comment on a line that runs still counts, which
   is the conservative answer.

   It is ONE awk pass over the whole corpus, not `sed | grep` per suite: at
   700+ suites a fork pair each is 1400 processes on the gate's critical path
   (round-3 review, advisory 3). Matching is by token — every non-word byte
   becomes a separator and each token is looked up in the names set — which is
   `grep -owF`'s whole-word semantics for names that are themselves
   `[A-Za-z0-9_]+`, and `ti_named_rows` truncates every name it collects at its
   first non-word byte, so they always are. Suites are passed as `./<path>`
   because awk has no `--` and a bare operand containing `=` would be read as a
   variable assignment (the suite would then be skipped in silence); the prefix
   is stripped off `FILENAME` again on output.

Not in this change, deliberately: the cap (still 80), and the other half of the
review's S1 — restricting `named` to the functions the diff actually changed,
rather than every function the changed file defines — which needs hunk-level
parsing of function bodies and is a follow-up ticket.

## The human step after merge

The registry default only governs a box with no settings row. The live row is
what the fleet reads, and the lead flips it:

```bash
bin/harness-ctl.sh set fly-pool TEST_IMPACT_GATE_BUDGET_S 450
```

## Tests

`tests/test-impact-gate.bh-1554-test.sh` (D1, D2, B1, O1-O4) and
`tests/test-impact-why.bh-1554-test.sh` (S1a, S1b), both against the real gate
and the real selector in scratch git repos.

## What the numbers behind the 1250 max are

The 250 s of headroom under the stage's `timeout 1500` has to cover the suite
that is still running when the budget expires. Measured, not estimated: two
isolated gate runs over this repo's own diff recorded
`tests/registry-no-commit-test.sh` at 205-208 s and
`tests/share-publish-clean.bh-795-test.sh` at 224 s in the durations file. 224
is under 250, so the max holds. A suite that grows past 250 s is the thing to
re-check before raising it.
