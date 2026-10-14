# Foreign-red attribution follow-ups: hub checkout, a later batch must have run the suite, cached reads, strict parse (BH-3857)

Doc: MERGE-CONDUCTOR, FLAKY-TESTS

Follow-ups to BH-3776 (`bin/lib/mc-foreign-red.sh`, `bin/lib/flaky.sh`), from
the final #3798 review and the ticket thread.

## What changed

1. **The harness repo's test-impact map is built in a real checkout.** On the
   hub `MC_H=/root/harness` has no `tests/`, so every cromford attribution
   came back `nomap`. `fr_attribute` now runs the select in the first checkout
   that is on `main` and has an executable `bin/test-impact.sh` and a `tests/`
   dir: `MC_TI_ROOT` (a seam), then harness-sync's own checkout beside the
   harness (`<harness>/../harness-checkout`, i.e. `/root/harness-checkout`).
   The checkout's own script runs with `--root <checkout>`. "Fresh" means on
   `main` only: `bin/harness-sync.sh` pulls it ff-only on every sync, and the
   conductor adds no fetch. With no such checkout it falls back to `MC_H`,
   which answers `nomap` exactly as before (BH-636 rule, one
   `FOREIGN_RED_NOMAP` line per head).
   **Cost:** 0 extra fetches per tick. The extra local cost is one map build
   per uncached attribution. Measured on a Fly builder against this branch:
   `time bin/test-impact.sh select --why --map-only --changed <(echo bin/lib/flaky.sh) --root .`
   took 6.6 s wall (two runs: 6.58 s, 6.66 s). The answer is cached per
   (PR, head), so a head pays it once.
2. **A later batch counts only if it ran the suite** (harness repo only).
   Batches are tiered (`bin/ci-plan.sh`, `bin/test-tiers.sh`), so a green
   later batch may have quarantined the suite, skipped its guard or left it to
   the nightly run. `_fr_batch_ran` reads the later run's
   `CI plan (what this run tests)` job log (raw, capped at `FLAKY_LOG_MAX`).
   It needs the `impact: … — K shard(s), mode=full` summary. A line-start
   `ci-plan: the tier step failed, so this batch runs every suite` warning
   means every suite ran. Otherwise a suite did not run when the log has
   `tiers: quarantine S — out of the batch` or `tiers: guard S skipped — …`,
   or when the checkout's `catalog/test-tiers.tsv` puts S in the nightly tier.
   A missing tier file, a failed read or no plan job means "not ran", never a
   pass. The parse is cached per run id in
   `state/merge-conductor/foreign-red/plan_<id>`. At most
   `MC_FR_LATER_PROBES` same-base batches are probed per failing run. A
   later batch that skipped the suite writes no `ci_flakes` row. A cached
   `unknown` now records each run's suites (`S` rows). An `unknown` cached
   before this change has none, so for the harness repo it is a cache miss
   and is attributed again in full.
3. **Per-tick reads.** `fr_reentry_gate` reads the per-(PR, head) cache BEFORE
   the Mergify-only check-runs/status read. A cached `own` or `foreign` costs
   0 GitHub reads. `unreadable` is now cached with the dequeue comment key it
   was read under, and trusted for `MC_FR_UNREADABLE_TTL_MINS` (file mtime).
   Inside the TTL it also costs 0 reads. An `unreadable` that failed before
   the comment was read has no key and is not cached.
4. **Strict parse, harness marker and FAIL token.** In the strict path only
   (`_flaky_parse_tagged`), the harness marker is taken only in the exact shape
   `bin/test-trace-safety.sh` prints it, `--- tests/<x>.sh rc=N Ns`, at line
   start after the gh prefix and timestamp. A `FAIL <file>` token is P only
   when it is a vitest/jest test file (`.test.`/`.spec.`, or under
   `__tests__/`). Anything else is T: unattributable, never lifted, never
   ledgered. `_flaky_parse_harness` and `flaky_parse_tests` are unchanged for
   flaky-detect, classify and rerun.
5. **Strict parse, ANSI.** `_flaky_strip_gh_prefix` also strips ANSI CSI
   escapes, so coloured vitest/jest `FAIL` lines name their file again.

## Knobs

| Knob | Default | Meaning |
|---|---|---|
| `MC_FR_UNREADABLE_TTL_MINS` | 15 | minutes a cached `unreadable` is trusted; 0 = never cached |
| `MC_FR_LATER_PROBES` | 3 | later same-base batches probed per failing run (harness repo) |

Both are merge-conductor lane knobs (`lane.merge-conductor[.<project>].…`).

## Owed

The hub probe that makes item 1 take effect was not run from the builder:
`ls -d /root/harness-checkout/tests && git -C /root/harness-checkout symbolic-ref --short HEAD`
must print the `tests` dir and `main`. Without it the change is a no-op on the
hub (`nomap`, exactly today's behaviour), never a regression.

Not done: Go `FAIL\tpkg` lines (comment note 3). The thread calls it
theoretical, and no fleet product repo is Go.

Verified by `tests/mc/foreign-red-followups.bh-3857-test.sh`.
