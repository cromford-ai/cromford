#!/bin/bash
# tests/lane-scoped-knob-lint.bh-8581-test.sh — bin/lane-scoped-knob-lint.sh
# (BH-8581): the source fragments of bin/<lane>.sh (config/<lane>.d/NNNN-<name>.sh,
# rendered by bin/fly-pool-build.sh) are the lane's own script, so they are allowed.
#
#   C0     this checkout: rc 0, no output.
#   F1-F3  green: a fragment that sets or exports the knob.
#   N1-N7  red: near misses (subdirectory, no NNNN, wrong suffix, other lane,
#          prefix-only dir, file outside the dir, NNNN-named subdirectory),
#          one finding each.
# Each case builds its own fresh repo.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lane-scoped-knob-lint.bh-8581-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -n "${T:-}" ] && [ -d "$T" ] || { echo "FAIL: no scratch dir"; exit 1; }
LINT_REL=bin/lane-scoped-knob-lint.sh
K=POOL_GH_READ_TIMEOUT_S

# run <cmd...> — sets RC, OUT
run() { "$@" >"$T/out" 2>"$T/err"; RC=$?; OUT=$(cat "$T/out"); }

# mkrepo <name> <path> <text> — a fresh git repo with the lint and one planted file.
mkrepo() {
  local r="$T/$1"
  mkdir -p "$r" && git -C "$r" init -q && git -C "$r" config user.email t@example.invalid \
    && git -C "$r" config user.name fixture || return 1
  scratch_install_closure "$LINT_REL" "$r" >/dev/null || return 1
  mkdir -p "$r/$(dirname "$2")" && printf '%s\n' "$3" > "$r/$2" || return 1
  git -C "$r" add -A && git -C "$r" commit -qm base || return 1
  printf '%s\n' "$r"
}

lint() { run bash "$1/$LINT_REL" "$1"; }

# green <id> <path> <text> — rc 0, no output.
green() {
  local r; r=$(mkrepo "$1" "$2" "$3") || { bad "$1: fixture"; return; }
  lint "$r"
  if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok; else bad "$1: $2: rc $RC: $OUT"; fi
}

# red <id> <path> — rc 1, exactly one finding on that path.
red() {
  local r n; r=$(mkrepo "$1" "$2" "export $K=20") || { bad "$1: fixture"; return; }
  lint "$r"
  n=$(printf '%s\n' "$OUT" | grep -c .)
  if [ "$RC" = 1 ] && [ "$n" = 1 ] \
    && grep -qE "^$2:1: names $K, a fly-pool lane-only knob" <<<"$OUT"; then
    ok
  else
    bad "$1: $2: rc $RC, $n line(s): $OUT"
  fi
}

# C0: this checkout.
run bash "$REPO/$LINT_REL" "$REPO"
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok; else bad "C0: this checkout: rc $RC: $OUT"; fi

green F1 config/fly-pool.d/0100-head.sh "$(printf '%s=20\nexport %s' "$K" "$K")"
green F2 config/fly-pool.d/2000-tail.sh "f() { local $K=45; }"
green F3 config/fly-pool.d/1950-bh-9001-alpha.sh "export $K=20"

red N1 config/fly-pool.d/sub/0100-x.sh
red N2 config/fly-pool.d/head.sh
red N3 config/fly-pool.d/0100-x.env
red N4 config/merge-conductor.d/0100-x.sh
red N5 config/fly-pool.d.bak/0100-x.sh
red N6 config/fly-pool.sh
red N7 config/fly-pool.d/0100-sub/x.sh

echo "lane-scoped-knob-lint.bh-8581: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
