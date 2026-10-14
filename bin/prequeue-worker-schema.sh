#!/bin/bash
# bin/prequeue-worker-schema.sh — the jobs-worker schema tests as one pre-queue
# invariant row (BH-5591, the worker-jobs-schema row of
# catalog/prequeue-invariants.tsv).
#
# Merge batch #5584 (2026-10-08) went red on three worker/jobs schema tests:
# #4744 and #5287 each added to worker/jobs/schema.sql, each passed alone, and
# the combination did not. A catalog cmd row is split on spaces and never goes
# through a shell, and its argv[0] must be a file in the tree, so `node --test`
# cannot be a row by itself. This is that row.
#
# Usage (from anywhere; it runs from the repo root):
#   bin/prequeue-worker-schema.sh worker/jobs/test/<name>.test.js ...
#
# The test files are the catalog's argv, never a list in here: the gate reads
# the catalog from main, so a PR cannot drop one.
#
# What it runs, in order:
#   1. catalog/lanes.json, rendered when absent or stale (the BH-5775 idiom of
#      bin/prequeue-invariants.sh): worker/jobs/src/lib/core.js imports it.
#      Then catalog/llm-sites.json, composed from catalog/llm-sites.d/ when
#      that directory exists (BH-4987): lib/llm-sites-catalog.js imports it.
#      Then catalog/context-budgets.json, composed from catalog/context-budgets.d/
#      when that directory exists (BH-6487): routes/llm-sites.js imports it.
#   2. `npm ci --no-audit --no-fund` in worker/jobs — the same install as the
#      CI job "Jobs worker — routes + schema" in .github/workflows/harness-ci.yml.
#   3. `node --test --test-reporter=tap <files>`. The reporter is pinned so the
#      output shape never depends on a TTY.
# Each top-level `not ok N - <name>` line becomes `FAIL: worker-schema: <name>`,
# which the runner copies into fail/<id>.txt. An indented subtest line is not
# one: its parent's top-level line already names the test.
#
# THE SKIP GUARD (the CI job's, after #1137): when node exits 0, the tap summary
# must show pass > 0 and skipped = 0. A node with no node:sqlite skips these
# tests, and a skip is never green.
#
# The last line is always `worker-schema: rc=<rc> pass=<n> skipped=<n>` once
# node ran. It writes nothing in the tree except catalog/lanes.json,
# catalog/llm-sites.json, catalog/context-budgets.json and
# worker/jobs/node_modules/, all git-ignored.
#
# Exit: 0 green | 1 red (a test failed, a skip, no pass, no summary, npm ci
# failed, a file missing, node or npm not on PATH) | 2 no argument, or an
# argument that is not one file name under worker/jobs/test/ ending .test.js
set -uo pipefail

fail() { echo "FAIL: worker-schema: $*"; }
ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
cd "$ROOT" || exit 1

[ $# -gt 0 ] || { fail "no test file named"; exit 2; }
for f in "$@"; do
  # One file name under worker/jobs/test/: no subdirectory, so no /../ either.
  if ! [[ $f =~ ^worker/jobs/test/[^/]+\.test\.js$ ]]; then
    fail "'$f' is not a worker/jobs/test/*.test.js path"; exit 2
  fi
done
for f in "$@"; do
  [ -f "$f" ] || { fail "$f is missing on this tree"; exit 1; }
done
for c in node npm; do
  command -v "$c" >/dev/null 2>&1 || { fail "$c is not on PATH"; exit 1; }
done

if [ -d catalog/lanes.d ]; then
  if ! ( unset LANE_REGISTRY
         # shellcheck source=lib/lanes-registry.sh
         . "$ROOT/bin/lib/lanes-registry.sh" && lanes_json_path "$ROOT" ) > /dev/null; then
    fail "could not render catalog/lanes.json"; exit 1
  fi
fi
if [ -d catalog/llm-sites.d ]; then
  "$ROOT/bin/llm-sites-build.sh" --repo "$ROOT" --compose > /dev/null \
    || { fail "could not compose catalog/llm-sites.json"; exit 1; }
fi
if [ -d catalog/context-budgets.d ]; then
  "$ROOT/bin/context-budgets-build.sh" --repo "$ROOT" --compose > /dev/null \
    || { fail "could not compose catalog/context-budgets.json"; exit 1; }
fi

LOG=$(mktemp) || exit 1
trap 'rm -f "$LOG"' EXIT

if ! ( cd worker/jobs && npm ci --no-audit --no-fund ) > "$LOG" 2>&1 < /dev/null; then
  fail "npm ci in worker/jobs failed"
  tail -n5 "$LOG"
  exit 1
fi

# The files are repo-relative; node runs from worker/jobs like the CI job.
REL=()
for f in "$@"; do REL+=("${f#worker/jobs/}"); done
: > "$LOG"
( cd worker/jobs && node --test --test-reporter=tap "${REL[@]}" ) > "$LOG" 2>&1 < /dev/null
rc=$?
cat "$LOG"

sed -n 's/^not ok [0-9][0-9]* - //p' "$LOG" | while IFS= read -r name; do fail "$name"; done

pass=$(sed -n 's/^# pass \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -n1)
skipped=$(sed -n 's/^# skipped \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -n1)
if [ "$rc" = 0 ]; then
  if [ -z "$pass" ] || [ -z "$skipped" ]; then fail "no tap summary (# pass / # skipped)"; rc=1
  elif [ "$pass" = 0 ]; then fail "no test passed"; rc=1
  elif [ "$skipped" != 0 ]; then fail "$skipped test(s) skipped; a skip is never green"; rc=1
  fi
fi
echo "worker-schema: rc=$rc pass=${pass:-none} skipped=${skipped:-none}"
exit "$rc"
