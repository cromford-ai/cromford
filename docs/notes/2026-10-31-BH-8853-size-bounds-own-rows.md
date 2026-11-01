# The BH-8050 size bounds cap the non-always rows (BH-8853)

Doc: TESTING

## What was red

The nightly run on main bd9f7537 failed `tests/test-impact-size.bh-8050-test.sh`:
Z2 selected 99 suites (bound 97) and Z3 selected 69 (bound 68). Z1 selected 276
(bound 284).

## Why

BH-8099 (e93faad1) set the bounds as totals. On that tree
`bin/test-impact.sh always` printed 51 suites. On bd9f7537 it prints 58. Eight
suites joined the always set and one left it:

- added: cross-tree-rows.bh-8573, fly-pool-sync-streak.bh-8780,
  mc-prequeue-fast-lints.bh-8473, onboard-github-vendor-budget.bh-7935,
  onboard-tracker-vendor-budget.bh-7936, prequeue-fast-lints-runner.bh-8473,
  vendor-budget.bh-7939, vendor-fake-switch.bh-8555
- removed: arch-audit-conflict.bh-5270

The non-always rows did not grow past their old share:

| Z | total then | own then | total now | own now |
|---|---|---|---|---|
| Z1 | 259 | 208 | 276 | 218 |
| Z2 | 89 | 38 | 99 | 41 |
| Z3 | 62 | 11 | 69 | 11 |

The always count already has an owner: R3 of
`tests/test-impact-always-cut.bh-8098-test.sh` (`ALWAYS_MAX=62`). BH-8473
raised that bound for the same growth. Each new whole-repo suite was thus
counted twice, and any two more would make this nightly red again.

## The new bound shape

Z1, Z2 and Z3 now cap the rows this suite owns: every selected suite whose kind
is not `always`. The bounds are the old totals minus the 51 always rows they
were measured with: `Z1_OWN_MAX=233`, `Z2_OWN_MAX=46`, `Z3_OWN_MAX=17`. A
growth of the directory, source or closure rows fails at the same count as
before. Each Z also checks that its always rows equal the
`bin/test-impact.sh always` count, so the subtraction cannot hide a wrong row.
Z4 is unchanged: it compares totals of two maps with the same always set.

TEST-CHANGE: the suite's premise "the always set stays at 51 suites" is gone.
The always count is bounded only by BH-8098 R3. The own-row strictness is
unchanged. `TI_DIR_ROWS=0` still fails Z1 (328 own rows against 233).

## Not done

Three of the eight new always suites look like detector false positives
(prequeue-fast-lints-runner.bh-8473, vendor-budget.bh-7939,
fly-pool-sync-streak.bh-8780). A narrower detector changes the map for every
diff, so it is out of scope here and can be its own ticket.
