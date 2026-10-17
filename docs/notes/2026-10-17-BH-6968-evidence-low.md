# The risk tier can call a head low by evidence, not only by path (BH-6968)

Doc: MERGE-CONDUCTOR

Part of #6544, wave 2 of 4.

## What changed

`bin/lib/risk-tier.sh` has one more way into `low`: rule 2c, "evidence". Before
this change, only a diff made of docs, screens or new tests (rule 2) or rules
text (rule 2b) was low. Now a diff with other paths, such as `bin/foo.sh`, is
low when ALL of these hold:

1. No path matches a high, sensitive or lead-protected glob. Rule 1 runs first
   and makes such a head `high`, so rule 2c never goes around the globs.
2. No path is an existing test, test helper or fixture, and the diff is not
   rules-text shaped (rule 2b owns those diffs).
3. The changed lines are under the low line limit (`risk_tier.low_lines`,
   capped at 300).
4. The queue-risk score (`qr_score`, `bin/lib/queue-risk.sh`) is under
   `risk_tier.low_score_max`.
5. The builder gate ran at least `risk_tier.low_min_suites` suites green on
   this head.
6. The `prequeue-verdict` status on this head is `success` with a description
   that starts `green on main `.

The reasons string of an evidence low starts `evidence:`, for example
`evidence: score 0 under 25, 12 suites green on head, prequeue-verdict green,
40 lines`. A head that misses one input stays medium (or high under rules 3
and 4), and its reasons end with `no evidence low: <the first input that
failed>`.

The path ceiling constants (`RT_LOW_CEILING`, `RT_LOW_NEW_TESTS`,
`RT_LOW_LINES_MAX`) did not change. What low does (the BH-5022 sign-off) did
not change.

## The two settings rows

| row | fallback | what it does |
|---|---|---|
| `risk_tier.low_score_max` | 0 | The score must be under this. 0 turns rule 2c off. |
| `risk_tier.low_min_suites` | 12 | The builder gate must run at least this many suites green on the head. Read only while the lane is on. |

The lane is OFF until an operator sets the first row. With the lane off, the
rules signature (`RT_RULES_SIG`) is the same as before this change, so no
cached head is classified again. To turn the lane on:

```bash
bin/jobs-client.sh setting-set risk_tier.low_score_max 25
```

Setting either row changes the signature, so the next tick classifies every
open head again once (the same cost as any `risk_tier.*` row edit).

An unreadable `risk_tier.low_score_max` or `risk_tier.low_min_suites` row
makes the rules unreadable, and an unreadable rule set is never low.

## Where the evidence comes from

`rt_evidence_load` reads the three inputs for one head, in this order, and
stops at the first that fails. The two lanes call it only while the lane is on
and only for a head with no cached `risk.tsv` line.

1. Builder gate count: the PR body. `bin/evidence-summary.sh` adds one line
   to the evidence block: `<!-- builder-gate: head=<sha> green=<n> -->`. It
   reads the newest suite file (`harness-suite-head.txt`, else
   `harness-suite-fix.txt`, else `harness-suite.txt`), and writes the line only
   when that file has `HARNESS_EXIT: 0`, a 40-hex `HARNESS_HEAD:` line and the
   gate's `impact-gate: ran <X> of <N> selected suites via <runner>: passed`
   line. `<n>` is X: suites reused from the suite ledger do not count.
   `HARNESS_IMPACT_GATE_RUN` (`bin/lib/rb/gates.sh`) writes the
   `HARNESS_HEAD:` line; a work tree with changes writes `HARNESS_HEAD: dirty`.
   The body must have exactly one distinct marker, and its head must be the
   head under review. A marker for an older head is refused.
2. Prequeue verdict: one `GET repos/<slug>/commits/<head>/status`. The success
   answers that ran no green suite (`gate off`, `no-selection`, `conflict`,
   `could-not-run ...`, `no pre-queue workflow`, `proceed on main`, `no red
   pre-queue verdict ...`) are not green here.
3. Queue-risk score: `qr_score` over the compare's files, lines and file
   count. The culprit and prequeue-red history comes from `pr_attempt_count`
   (the conductor's `pr_attempts` rows). An outage there, an unreadable
   `queue_risk.*` row, or no score is "score unreadable", never 0. The
   `queue_risk.*` rows are read once per rules load.

## risk.tsv

`state/lead-review-enqueue/risk.tsv` has an 8th column on the tier and
withheld lines: `evidence` (rule 2c), `path` (rules 2 and 2b), or `-` (not low).
Lines written before this change have 7 columns. The readers match on columns
2, 3, 4 and 7, so both shapes read the same.

## Note on the prequeue order

The conductor runs the pre-queue gate only on a READY head, so a first head
often has no `prequeue-verdict` yet when its lead review is requested. Such a
head is medium under rule 2c. The #6544 owner decides if that order changes.

## Tests

`tests/risk-tier-evidence.bh-6968-test.sh`.
