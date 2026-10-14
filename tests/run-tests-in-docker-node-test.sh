#!/bin/bash
# tests/run-tests-in-docker-node-test.sh — the local test image runs the node
# CI runs, not Debian's apt nodejs.
#
# WHY. bin/run-tests-in-docker.sh built its image with trixie's apt `nodejs`, a
# node 20.19 with no `node:sqlite`. CI pins node-version '22'
# (.github/workflows/harness-ci.yml). So on a Mac the worker/jobs node tests
# (and the tests/cloud-* suites, since removed by BH-6303) ended "suite did
# not run" while CI passed them: a local run that could not reproduce CI for
# a whole family of suites.
# fly/testhost/ fixed the same bug with fly/testhost/node-install.sh (BH-1617);
# the local image now installs node through that same script.
#
# WHAT THIS PINS, without a docker daemon:
#   1 the inline Dockerfile's apt block names no nodejs/npm and carries xz-utils
#     (node-install.sh unpacks a tar.xz) and python3-yaml (the YAML suites);
#   2 the Dockerfile takes ARG NODE_VERSION with no default, has no COPY and no
#     ADD (BH-1193: the build has no context), writes node-install.sh from the
#     NODE_INSTALL_B64 build arg and runs it with "$NODE_VERSION"; no x.y.z
#     literal in it;
#   3 the runner resolves NODE_VERSION through bin/lib/test-image-node.sh, passes
#     it and fly/testhost/node-install.sh (base64) as --build-arg, and builds
#     with `-` as the context;
#   4 the resolver: CI's workflow pins exactly one node major; the fallback picks
#     the newest release OF THAT MAJOR from the index (not the newest overall);
#     an override or row on another major is refused; a workflow that pins two
#     majors is refused.
#
# Run from anywhere: tests/run-tests-in-docker-node-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RUNNER="$DIR/bin/run-tests-in-docker.sh"
LIB="$DIR/bin/lib/test-image-node.sh"
CI="$DIR/.github/workflows/harness-ci.yml"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$RUNNER" ] || { echo "FAIL: $RUNNER is missing"; exit 1; }

# ── 1/2. the inline Dockerfile ──────────────────────────────────────────────
DF=$(sed -n "/<<'DOCKERFILE'/,/^DOCKERFILE$/p" "$RUNNER" | sed '1d;$d')
[ -n "$DF" ] && ok || bad "1 could not extract the DOCKERFILE heredoc from $RUNNER (every check below would be vacuous)"
APT=$(printf '%s\n' "$DF" | sed -n '/apt-get install/,/rm -rf/p')
[ -n "$APT" ] && ok || bad "1 no apt-get install block in the inline Dockerfile"
grep -qwE 'nodejs|npm' <<<"$APT" \
  && bad "1 the image still installs apt nodejs/npm (Debian's node 20, no node:sqlite): $APT" || ok
grep -qw 'xz-utils' <<<"$APT" && ok || bad "1 the apt block lacks xz-utils, which node-install.sh needs for tar -J"
grep -qw 'python3-yaml' <<<"$APT" && ok || bad "1 the apt block lacks python3-yaml, which the workflow and .mergify.yml suites import"

grep -qx 'ARG NODE_VERSION' <<<"$DF" && ok || bad "2 no bare 'ARG NODE_VERSION' in the inline Dockerfile"
grep -q '^ARG NODE_VERSION=' <<<"$DF" && bad "2 ARG NODE_VERSION carries a default" || ok
# TEST-CHANGE (merge batch #5631): this used to require `COPY node-install.sh`,
# which needs a build context; tests/run-tests-in-docker.bh-1193-test.sh C
# requires the context to be `-`. The script now arrives as a build arg.
grep -qE '^(COPY|ADD) ' <<<"$DF" && bad "2 the inline Dockerfile has a COPY/ADD, which needs a build context (BH-1193 wants none)" || ok
grep -qx 'ARG NODE_INSTALL_B64' <<<"$DF" && ok || bad "2 no 'ARG NODE_INSTALL_B64' in the inline Dockerfile"
grep -q 'NODE_INSTALL_B64" | base64 -d > /usr/local/bin/testhost-node-install.sh' <<<"$DF" && ok \
  || bad "2 the inline Dockerfile does not write node-install.sh from NODE_INSTALL_B64"
grep -q 'node-install.sh "\$NODE_VERSION"' <<<"$DF" && ok \
  || bad "2 the inline Dockerfile does not run node-install.sh \"\$NODE_VERSION\""
LIT=$(printf '%s\n' "$DF" | grep -nE '[0-9]+\.[0-9]+\.[0-9]+')
[ -z "$LIT" ] && ok || bad "2 version literal in the inline Dockerfile: $LIT"

# ── 3. the runner wires it ──────────────────────────────────────────────────
grep -q 'bin/lib/test-image-node.sh' "$RUNNER" && ok || bad "3 the runner does not source bin/lib/test-image-node.sh"
grep -q 'test_image_node_version' "$RUNNER" && ok || bad "3 the runner never calls test_image_node_version"
grep -q -- '--build-arg "NODE_VERSION=' "$RUNNER" && ok || bad "3 the docker build passes no --build-arg NODE_VERSION"
grep -q 'base64 < "$REPO/fly/testhost/node-install.sh"' "$RUNNER" && ok || bad "3 the runner does not encode fly/testhost/node-install.sh"
grep -q -- '--build-arg "NODE_INSTALL_B64=' "$RUNNER" && ok || bad "3 the docker build passes no --build-arg NODE_INSTALL_B64"

# ── 4. the resolver ─────────────────────────────────────────────────────────
if [ ! -f "$LIB" ]; then
  bad "4 $LIB does not exist"
else
  # shellcheck source=../bin/lib/test-image-node.sh
  . "$LIB"
  export TEST_IMAGE_NODE_NO_ROW=1
  M=$(ci_node_major "$CI" 2>"$T/m.err")
  [[ "$M" =~ ^[0-9]+$ ]] && ok || bad "4 harness-ci.yml does not pin one bare node major: '$M' $(cat "$T/m.err")"
  M=${M:-0}

  # The index lists a NEWER major first, the way nodejs.org does: the fallback
  # must skip it and land on CI's major, not on the newest node.
  cat > "$T/index.json" <<JSON
[{"version":"v$((M+2)).1.0"},{"version":"v$((M+1)).4.0"},{"version":"v$M.30.1"},{"version":"v$M.30.0"},{"version":"v$((M-2)).19.2"}]
JSON
  export TEST_IMAGE_NODE_INDEX="file://$T/index.json"
  v=$(unset NODE_VERSION; test_image_node_version "$DIR" 2>"$T/e1"); rc=$?
  [ "$rc" = 0 ] && [ "$v" = "$M.30.1" ] && ok || bad "4 fallback picked '$v' (rc=$rc), want the newest v$M.x, $M.30.1: $(cat "$T/e1")"
  [ "${v%%.*}" = "$M" ] && ok || bad "4 the resolved node major (${v%%.*}) is not CI's ($M)"

  v=$(NODE_VERSION="v$M.7.3" test_image_node_version "$DIR" 2>/dev/null); rc=$?
  [ "$rc" = 0 ] && [ "$v" = "$M.7.3" ] && ok || bad "4 NODE_VERSION=v$M.7.3 override not taken: '$v' rc=$rc"

  v=$(NODE_VERSION="$((M-2)).19.2" test_image_node_version "$DIR" 2>"$T/e2"); rc=$?
  [ "$rc" != 0 ] && [ -z "$v" ] && ok || bad "4 a node $((M-2)) override was accepted ('$v') though CI runs $M"
  grep -q "node $M" "$T/e2" && ok || bad "4 the refusal does not name CI's node $M: $(cat "$T/e2")"

  v=$(NODE_VERSION=latest test_image_node_version "$DIR" 2>/dev/null); rc=$?
  [ "$rc" != 0 ] && ok || bad "4 NODE_VERSION=latest accepted ('$v')"

  printf '[]\n' > "$T/empty.json"
  v=$(unset NODE_VERSION; TEST_IMAGE_NODE_INDEX="file://$T/empty.json" test_image_node_version "$DIR" 2>/dev/null); rc=$?
  [ "$rc" != 0 ] && ok || bad "4 an index with no v$M.x resolved to '$v'"

  printf "      - uses: actions/setup-node@v4\n        with:\n          node-version: '22'\n      - uses: actions/setup-node@v4\n        with:\n          node-version: '20'\n" > "$T/two.yml"
  ci_node_major "$T/two.yml" >/dev/null 2>&1 && bad "4 a workflow pinning two majors was accepted" || ok
fi

echo "run-tests-in-docker-node: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
