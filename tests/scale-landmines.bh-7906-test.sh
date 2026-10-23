#!/bin/bash
# tests/scale-landmines.bh-7906-test.sh — one skipped test per entry of
# docs/scale/LANDMINES.md (BH-7906). A skip names the shape the fix ticket
# must turn into a real test, so that ticket starts red. The scale-audit
# suite checks that each `SKIPPED TEST:` line of LANDMINES.md is a skip here.
. "$(dirname "$0")/lib/scratch.sh" || exit 1

PASS=0; FAIL=0; SKIP=0
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1"; }

# The shared GitHub App bucket (6,600 calls/h) at 1.16x the 2026-09-22 load.
skip "landmine BH-7906: github-rest-shared-bucket"
# The jobs worker D1 answered "overloaded" 875 times in 5 h on 2026-10-14.
skip "landmine BH-7906: d1-jobs-worker-overload"

echo "scale-landmines.bh-7906: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
