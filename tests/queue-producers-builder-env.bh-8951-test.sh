#!/bin/bash
# tests/queue-producers-builder-env.bh-8951-test.sh — tests/queue-producers-test.sh
# is green in a pool builder's shell, not only in CI (BH-8951).
#
# THE CASE. A pool builder exports BUILDER_EXEC=1, POOL_MODE=1,
# BUILDER_NO_MERGE=1 and HOTFIX. queue-producers-test.sh drives the real
# bin/run-build.sh, and bin/lib/rb/gates.sh skips the Fly enqueue when
# BUILDER_EXEC is set. So on a builder every case landed BUILD_DEFERRED where
# the suite expects QUEUED_FLY (24 pass, 27 fail, exit 1), and CI was green.
# The fix: build() unsets the four names inside its subshell.
#
#   Q1  the in-tree suite exits 0 with the four names set (the case)
#   Q2  control: a repo copy with the in-tree suite exits 0 with them set
#   Q2m mutation: the same copy without the unset line exits != 0
#   Q3  the in-tree suite exits 0 with the four names removed (the CI env)
#
# 0 vendor calls: queue-producers-test.sh stubs curl and flock.
# Run from anywhere: tests/queue-producers-builder-env.bh-8951-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

UNSET_LINE='  ( unset BUILDER_EXEC POOL_MODE BUILDER_NO_MERGE HOTFIX'
POOL_ENV=(BUILDER_EXEC=1 POOL_MODE=1 BUILDER_NO_MERGE=1 HOTFIX=1 HARNESS_TEST_SANDBOX=1)

# pool_run <suite path> -> its rc; its output lands in $T/<name>.out
pool_run() {
  env "${POOL_ENV[@]}" bash "$1" >"$T/$2.out" 2>&1
  echo $?
}

# ── Q1: the in-tree suite in the pool env ──────────────────────────────────
rc=$(pool_run "$DIR/tests/queue-producers-test.sh" q1)
[ "$rc" = 0 ] && ok || { bad "Q1: queue-producers-test.sh exited $rc with BUILDER_EXEC set"; tail -3 "$T/q1.out"; }

# ── Q2 / Q2m: a repo copy, with and without the unset line ─────────────────
if command -v git >/dev/null 2>&1 && git -C "$DIR" rev-parse HEAD >/dev/null 2>&1; then
  mkdir -p "$T/drop"
  git -C "$DIR" archive HEAD | tar -x -C "$T/drop"
  cp "$DIR/tests/queue-producers-test.sh" "$T/drop/tests/queue-producers-test.sh"
  grep -qxF "$UNSET_LINE" "$T/drop/tests/queue-producers-test.sh" \
    && ok || bad "Q2: setup: the working-tree suite has no exact unset line"
  rc=$(pool_run "$T/drop/tests/queue-producers-test.sh" q2)
  [ "$rc" = 0 ] && ok || { bad "Q2: the repo copy exited $rc with the unset line"; tail -3 "$T/q2.out"; }

  sed -i "s/^  ( unset BUILDER_EXEC POOL_MODE BUILDER_NO_MERGE HOTFIX\$/  (/" \
    "$T/drop/tests/queue-producers-test.sh"
  grep -q 'unset BUILDER_EXEC' "$T/drop/tests/queue-producers-test.sh" \
    && bad "Q2m: setup: the mutant still unsets BUILDER_EXEC" || ok
  rc=$(pool_run "$T/drop/tests/queue-producers-test.sh" q2m)
  [ "$rc" != 0 ] && ok || bad "Q2m: the suite without the unset line still exited 0 with BUILDER_EXEC set"
else
  echo "SKIP: Q2 needs git and a git checkout"
fi

# ── Q3: the in-tree suite in the CI env ────────────────────────────────────
env -u BUILDER_EXEC -u POOL_MODE -u BUILDER_NO_MERGE -u HOTFIX HARNESS_TEST_SANDBOX=1 \
  bash "$DIR/tests/queue-producers-test.sh" >"$T/q3.out" 2>&1
rc=$?
[ "$rc" = 0 ] && ok || { bad "Q3: queue-producers-test.sh exited $rc with the four names removed"; tail -3 "$T/q3.out"; }

echo "queue-producers-builder-env: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
