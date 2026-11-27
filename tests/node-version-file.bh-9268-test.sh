#!/bin/bash
# tests/node-version-file.bh-9268-test.sh — .node-version is the node major the
# public copy, its CI and the Docker runner read (BH-9268).
#
# The public copy ships no .github/workflows/harness-ci.yml (sanitize drops it),
# so bin/lib/test-image-node.sh had no file to read the node major from there,
# and the public CI pinned no node at all. .node-version is one bare major;
# upstream it must equal the major harness-ci.yml pins.
#
# Sources under test: "$DIR/.node-version" "$DIR/bin/lib/test-image-node.sh" "$DIR/bin/share/overlay/.github/workflows/ci.yml"
#
# Run from anywhere: tests/node-version-file.bh-9268-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# shellcheck source=../bin/lib/test-image-node.sh
. "$DIR/bin/lib/test-image-node.sh" || { echo "FAIL: cannot source test-image-node.sh"; exit 1; }

# V1: .node-version is one line, a bare major
NV=$(cat "$DIR/.node-version" 2>/dev/null)
if [[ "$NV" =~ ^[0-9]+$ ]] && [ "$(wc -l < "$DIR/.node-version")" = 1 ]; then ok; else
  bad "V1 .node-version is not one bare major line: '$NV'"
fi

# V2: upstream, it equals the major harness-ci.yml pins (the mirror has no
# harness-ci.yml, so there the pin is .node-version alone)
CI="$DIR/.github/workflows/harness-ci.yml"
if [ -r "$CI" ]; then
  M=$(ci_node_major "$CI" 2>/dev/null)
  [ "$M" = "$NV" ] && ok || bad "V2 .node-version '$NV' != harness-ci.yml major '$M'"
else
  SKIP=$((SKIP+1))
fi

# V3: a repo with ONLY .node-version (the public copy) resolves that major
mkdir -p "$T/pub"
printf '%s\n' 21 > "$T/pub/.node-version"
v=$(NODE_VERSION=21.4.0 TEST_IMAGE_NODE_NO_ROW=1 test_image_node_version "$T/pub" 2>"$T/e3"); rc=$?
[ "$rc" = 0 ] && [ "$v" = 21.4.0 ] && ok || bad "V3 only .node-version: rc=$rc v='$v' $(cat "$T/e3")"
v=$(NODE_VERSION=22.4.0 TEST_IMAGE_NODE_NO_ROW=1 test_image_node_version "$T/pub" 2>/dev/null); rc=$?
[ "$rc" != 0 ] && [ -z "$v" ] && ok || bad "V3b a node 22 override passed against .node-version 21 ('$v')"
v=$(repo_node_major "$T/pub"); [ "$v" = 21 ] && ok || bad "V3c repo_node_major gave '$v'"

# V4: no .node-version -> harness-ci.yml still decides
mkdir -p "$T/up/.github/workflows"
printf 'jobs:\n  a:\n    steps:\n      - uses: actions/setup-node@v4\n        with:\n          node-version: %s\n' "'20'" \
  > "$T/up/.github/workflows/harness-ci.yml"
v=$(NODE_VERSION=20.1.2 TEST_IMAGE_NODE_NO_ROW=1 test_image_node_version "$T/up" 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ "$v" = 20.1.2 ] && ok || bad "V4 harness-ci.yml fallback: rc=$rc v='$v'"

# V5: .node-version wins over harness-ci.yml when both exist
cp -r "$T/up" "$T/both"; printf '23\n' > "$T/both/.node-version"
v=$(repo_node_major "$T/both"); [ "$v" = 23 ] && ok || bad "V5 .node-version did not win: '$v'"

# V6: a .node-version that is not a bare major is refused, not guessed
mkdir -p "$T/badnv"; printf 'lts/iron\n' > "$T/badnv/.node-version"
v=$(repo_node_major "$T/badnv" 2>/dev/null); rc=$?
[ "$rc" != 0 ] && [ -z "$v" ] && ok || bad "V6 a non-major .node-version passed: '$v'"

# V7: the repo's own resolution reads .node-version
v=$(repo_node_major "$DIR"); [ "$v" = "$NV" ] && ok || bad "V7 repo_node_major '$DIR' gave '$v'"

# O1-O2: the public CI reads .node-version and runs the three node suites.
# Upstream the overlay is under bin/share/; in the mirror it IS the ci.yml.
OV="$DIR/bin/share/overlay/.github/workflows/ci.yml"
[ -f "$OV" ] || OV="$DIR/.github/workflows/ci.yml"
grep -qE '^\s*node-version-file:\s*\.node-version\s*$' "$OV" && ok \
  || bad "O1 $OV has no setup-node with node-version-file: .node-version"
grep -qE '^\s*node-version:' "$OV" && bad "O1b $OV also pins a literal node-version" || ok
for d in console-ui worker/jobs worker/otp-inbox; do
  grep -q "for d in .*$d" "$OV" && ok || bad "O2 $OV does not run npm test in $d"
done
grep -q 'npm test' "$OV" && ok || bad "O2b $OV runs no npm test"

echo "node-version-file.bh-9268-test: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
