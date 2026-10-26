#!/bin/bash
# tests/share-drop-workflows.bh-8433-test.sh — every upstream workflow stays out
# of the mirror (BH-8433).
#
# BH-8327 added .github/workflows/prequeue-group-gate.yml with no DROP_FILES row
# in bin/share/sanitize.py, so the publisher copied it into the public tree.
# The nightly caught it in tests/public-ci-green.bh-4083 (needs gitleaks and a
# full publish, so the PR selection did not run it). This suite pins the rule
# on the PR path: each tracked .github/workflows/* file is dropped by
# sanitize.dropped(), and the overlay still ships the mirror's one CI, ci.yml.
# It reads only this checkout: no network, no vendor, no shared state.
#
# Run from anywhere: tests/share-drop-workflows.bh-8433-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
SHARE="$DIR/bin/share"
export PYTHONDONTWRITEBYTECODE=1

if [ ! -f "$SHARE/sanitize.py" ]; then
  # The mirror does not carry bin/share: the publisher is upstream-only.
  echo "SKIP share-drop-workflows.bh-8433: no bin/share in this copy"
  exit 0
fi

WF=$(git -C "$DIR" ls-files .github/workflows)
if [ -z "$WF" ]; then
  bad "git ls-files .github/workflows returned nothing to check"
fi

# 1. every tracked upstream workflow is dropped
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import sanitize; sys.exit(0 if sanitize.dropped(sys.argv[2]) else 1)' "$SHARE" "$rel"; then
    ok
  else
    bad "$rel is not in DROP_FILES (bin/share/sanitize.py): the publisher ships it to the public tree"
  fi
done <<< "$WF"

# 2. the overlay still gives the public tree its one CI
if [ -f "$SHARE/overlay/.github/workflows/ci.yml" ]; then ok
else bad "bin/share/overlay/.github/workflows/ci.yml is missing: the public tree would have no CI"; fi

echo "share-drop-workflows.bh-8433: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
