#!/bin/bash
# bin/lib/test-image-node.sh — which node the local test image
# (bin/run-tests-in-docker.sh) installs. Sourced, never run.
#
# WHY. The image installed Debian trixie's apt nodejs, a node 20 with no
# node:sqlite, while CI and this resolver now share the shipped .node-version.
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
#   3. the exact version in .node-version         (also used by setup-node)
# Whichever answers, its major must equal CI's, or the build is refused: the
# local image and CI cannot drift apart again without somebody editing the
# shared version file on purpose.
#
# Test seam: TEST_IMAGE_NODE_NO_ROW=1 skips the optional settings lookup.

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
  local repo="$1" major v src pin
  [ -r "$repo/.node-version" ] || { echo "test-image-node: cannot read $repo/.node-version" >&2; return 1; }
  pin=$(tr -d '\r\n' < "$repo/.node-version")
  [[ "$pin" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "test-image-node: .node-version must pin exact x.y.z" >&2; return 1; }
  major="${pin%%.*}"
  v="${NODE_VERSION:-}"; src="NODE_VERSION"
  if [ -z "$v" ]; then
    v=$(_test_image_node_row "$repo"); src="the bake.node.version row"
  fi
  if [ -z "$v" ]; then
    v="$pin"; src=".node-version"
  fi
  v="${v#v}"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "test-image-node: $src gave '$v', not an exact x.y.z" >&2; return 1; }
  [ "${v%%.*}" = "$major" ] || { echo "test-image-node: $src gave node $v, but CI (.node-version) runs node $major" >&2; return 1; }
  echo "run-in-docker: node $v from $src (CI runs node $major)" >&2
  printf '%s' "$v"
}
