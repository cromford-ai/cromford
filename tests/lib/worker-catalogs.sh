# shellcheck shell=bash
# tests/lib/worker-catalogs.sh — SOURCED by shell suites, never executed.
#
# worker_catalogs <root> — write <root>/catalog/lanes.json with
# <root>/bin/lanes-build.sh, then compose <root>/catalog/llm-sites.json with
# <root>/bin/llm-sites-build.sh. Both files are git-ignored, and
# worker/jobs/src/index.js imports both through its modules, so a suite that
# loads the worker on a fresh checkout must run this first (BH-6452, BH-6540).
#
#   * both builders pass: no output, rc 0.
#   * lanes-build.sh fails: "FAIL: cannot write catalog/lanes.json", rc 1, and
#     llm-sites-build.sh does not run.
#   * llm-sites-build.sh fails: "FAIL: cannot compose catalog/llm-sites.json", rc 1.
# It returns and never exits, so the caller decides what a failure means.
#
# Use it on two lines after DIR=:
#   . "$DIR/tests/lib/worker-catalogs.sh" || exit 1
#   worker_catalogs "$DIR" || exit 1
# tests/worker-node-catalog-compose.bh-6452-test.sh and
# tests/worker-node-lanes-build.bh-6540-test.sh accept a suite that has both lines.
worker_catalogs() {
  local root=${1:?worker_catalogs: need the repo root}
  "$root/bin/lanes-build.sh" --root "$root" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; return 1; }
  "$root/bin/llm-sites-build.sh" --compose --repo "$root" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; return 1; }
}
