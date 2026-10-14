#!/bin/bash
# bin/lib/test-image-node.sh — which node the local test image
# (bin/run-tests-in-docker.sh) installs. Sourced, never run.
#
# WHY. The image installed Debian trixie's apt nodejs, a node 20 with no
# node:sqlite, while CI pins node-version '22' in .github/workflows/harness-ci.yml.
# So the worker/jobs node tests (and the tests/cloud-* suites, since removed
# by BH-6303) ended "suite did not run" on a Mac and passed in CI. fly/testhost/ had the same bug and fixed it
# with fly/testhost/node-install.sh (BH-1617); the local image now uses that
# same installer, and this file picks the version it is handed.
#
# NO VERSION LITERAL LIVES HERE (BH-1528). The exact version is, in order:
#   1. NODE_VERSION in the environment              (an operator's override)
#   2. the bake.node.version settings row           (the version fly/Dockerfile
#      and the test hosts bake; read only where this machine can reach the jobs
#      worker, which a Mac usually cannot)
#   3. the newest nodejs.org release of CI's major  (the major is read out of
#      .github/workflows/harness-ci.yml, never written here)
# Whichever answers, its major must equal CI's, or the build is refused: the
# local image and CI cannot drift apart again without somebody editing the
# workflow on purpose.
#
# Test seams: TEST_IMAGE_NODE_INDEX (the release index URL, default
# https://nodejs.org/dist/index.json) and TEST_IMAGE_NODE_NO_ROW=1 (skip step 2).

# ci_node_major <workflow> -> the one node major the workflow's setup-node steps
# pin, on stdout. rc 1 (and a reason on stderr) when it pins none, more than
# one, or something that is not a bare major.
ci_node_major() {
  local wf="${1:-}" vals n
  [ -r "$wf" ] || { echo "test-image-node: cannot read $wf" >&2; return 1; }
  vals=$(sed -n "s/^[[:space:]]*node-version:[[:space:]]*['\"]\{0,1\}\([^'\"[:space:]]*\)['\"]\{0,1\}[[:space:]]*$/\1/p" "$wf" | LC_ALL=C sort -u)
  n=$(printf '%s\n' "$vals" | grep -c .)
  [ "$n" = 1 ] || { echo "test-image-node: $wf pins $n distinct node-version values (${vals//$'\n'/ }), expected exactly one" >&2; return 1; }
  [[ "$vals" =~ ^[0-9]+$ ]] || { echo "test-image-node: $wf node-version '$vals' is not a bare major" >&2; return 1; }
  printf '%s' "$vals"
}

# _test_image_node_row <repo> -> the bake.node.version row, empty when this
# machine cannot read it. A subshell, so the jobs client's globals stay out of
# the runner.
_test_image_node_row() {
  [ "${TEST_IMAGE_NODE_NO_ROW:-}" = 1 ] && return 0
  (
    # shellcheck source=/dev/null
    . "$1/bin/jobs-client.sh" >/dev/null 2>&1 || exit 0
    # shellcheck source=/dev/null
    . "$1/bin/lib/cli-version.sh" >/dev/null 2>&1 || exit 0
    # shellcheck source=/dev/null
    . "$1/bin/lib/bake-deps.sh" >/dev/null 2>&1 || exit 0
    bake_row_version node 2>/dev/null
  ) || true
}

# test_image_node_version <repo> -> the exact x.y.z to install, on stdout; rc 1
# with the reason on stderr when nothing usable resolves.
test_image_node_version() {
  local repo="$1" major v src
  major=$(ci_node_major "$repo/.github/workflows/harness-ci.yml") || return 1
  v="${NODE_VERSION:-}"; src="NODE_VERSION"
  if [ -z "$v" ]; then
    v=$(_test_image_node_row "$repo"); src="the bake.node.version row"
  fi
  if [ -z "$v" ]; then
    src="the newest v$major.x on ${TEST_IMAGE_NODE_INDEX:-https://nodejs.org/dist/index.json}"
    v=$(curl -fsSL "${TEST_IMAGE_NODE_INDEX:-https://nodejs.org/dist/index.json}" 2>/dev/null \
      | jq -r --arg p "v$major." '[.[] | .version | select(startswith($p))][0] // empty' 2>/dev/null)
    [ -n "$v" ] || { echo "test-image-node: no NODE_VERSION, no readable bake.node.version row, and no v$major.x release found on the index" >&2; return 1; }
  fi
  v="${v#v}"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "test-image-node: $src gave '$v', not an exact x.y.z" >&2; return 1; }
  [ "${v%%.*}" = "$major" ] || { echo "test-image-node: $src gave node $v, but CI (.github/workflows/harness-ci.yml) runs node $major" >&2; return 1; }
  echo "run-in-docker: node $v from $src (CI runs node $major)" >&2
  printf '%s' "$v"
}
