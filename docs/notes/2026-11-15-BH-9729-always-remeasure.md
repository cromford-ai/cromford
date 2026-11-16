# BH-9729: the always-cut bounds are re-measured (64 always, 106 Z2)

Doc: TESTING

## Why

The nightly corpus on main 80b68e66 was red on one case of
`tests/test-impact-always-cut.bh-8098-test.sh`:
`FAIL R3 always holds 64 suites (bound 62)`. R4 passed at its bound exactly
(`Z2 selects 106 suites (at most 106)`). The detector did not change. The
corpus grew by 7 suites that the detector keeps in the always set by its own
rules. That growth is past the 10% allowance the bound carries.

## Numbers

| measure | before | after |
|---|---|---|
| always suites | 57 (4461dacb, BH-8473) | 64 (80b68e66, and this build head) |
| Z2 selection (one prompt) | 97 | 106 |
| ALWAYS_MAX / Z2_MAX | 62 / 106 | 70 / 116 |
| hard ceilings (R3 / R4) | 84 / 118 | 84 / 118 (unchanged) |

Each new bound is the measured number plus at most 10% (64 x 1.1 = 70.4,
106 x 1.1 = 116.6), the same rule as BH-8098 and BH-8473.

## The 7 new always suites

| suite | detected line | class |
|---|---|---|
| tests/docker-base-digest.bh-9209-test.sh | `:112 mapfile -t DFS < <(git -C "$DIR" ls-files \| grep -E '...Dockerfile...')` | real whole-tree read (every tracked Dockerfile) |
| tests/fly-pool-sync-streak.bh-8780-test.sh | `:161 S1F=$(find "$DIR/config/fly-pool.d" -name '*-bh-8780-*')` | rooted `find` under a checkout subdirectory; FINDRE keeps it by design |
| tests/hosted-board-seams.bh-8918-test.sh | `:65 find "$REPO/worker/jobs/test/route-table.d" -name ...` | rooted `find` under a checkout subdirectory; same rule |
| tests/mc-state-paths-regen.bh-9426-test.sh | `:91 git -C "$R" ls-files -u` | `R` is also bound `local R="$1"` (line 42): positional, so the detector cannot prove it scratch (BH-8098 case K) |
| tests/prequeue-equals-batch.bh-9697-test.sh | `:98 bash "$SG" --tree "$tr"` | `local c="$1" tr="$2"` (line 92): positional, kept |
| tests/selection-gate-baseline.bh-8901-test.sh | `:96 bash "$SG" --tree "$tr"` | `local ... tr="$2"` (line 91): positional, kept |
| tests/suite-quarantine.bh-9697-test.sh | `:182 bash "$SG" --tree "$tr"` | `local ... tr="$2"` (line 175): positional, kept |

6 of the 7 are detector conservative-keeps: function-local positionals and
rooted `find`s under a checkout subdirectory. The BH-8098 K-cases pin
positional targets as always on purpose, because a positional can be the
checkout. A detector rule that drops these 6 is a possible later cut. It is
not in this ticket. Only `docker-base-digest.bh-9209` is a real whole-tree
read.

## How the numbers were produced

```bash
git worktree add /tmp/old4461 4461dacb
(cd /tmp/old4461 && bin/test-impact.sh always | sort) > /tmp/a.old
bin/test-impact.sh always | sort > /tmp/a.new
wc -l /tmp/a.old /tmp/a.new            # 57, 64
comm -3 /tmp/a.old /tmp/a.new          # the 7 suites above, 0 removed
bin/test-impact.sh always-why          # the detected line for each suite
HARNESS_TEST_SANDBOX=1 bash tests/test-impact-always-cut.bh-8098-test.sh   # R3 64, R4 106
```

A mutation check proved the new bounds still bite: `ALWAYS_MAX=63` gives
`FAIL R3 always holds 64 suites (bound 63)`, and `Z2_MAX=105` gives
`FAIL R4 ... selects 106 (bound 105)`.
