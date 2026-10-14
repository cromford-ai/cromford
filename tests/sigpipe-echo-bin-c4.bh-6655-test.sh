#!/bin/bash
# tests/sigpipe-echo-bin-c4.bh-6655-test.sh — the C4 batch of bin/ files is
# clean of race-sigpipe-echo, and two of its swept reads stay correct on an
# input bigger than one pipe buffer (BH-6655, slice C4 of BH-6109).
#
# The rule does not scan bin/ until slice C6 adds its scope line, so this suite
# runs the lint with a scratch copy of the shipped conf plus that line:
#   A  the 17 C4 files report zero race-sigpipe-echo lines;
#   B  a scratch copy of bin/lib/train-shape.sh with its old pipe put back
#      reports exactly one (the check in A is live, not a lint that scans
#      nothing);
#   C  _rt_classify under pipefail, with `tests/../bin/x.sh` on line 1 and
#      ~1 MB of paths after it, answers `unresolvable path(s)` (the pipe read
#      took SIGPIPE and answered `diff-unavailable`);
#   D  train_is_train under pipefail, with a train title on line 1 and ~1 MB
#      after it, returns 0.
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

C4_FILES="bin/lib/rb/gates.sh bin/lib/rb/plan.sh bin/lib/restore-drill-steps.sh
bin/lib/review-tier.sh bin/lib/route-rules.sh bin/lib/rules-render-head.sh
bin/lib/runner-fastfail.sh bin/lib/session-profile.sh bin/lib/sfe/pr-state-rows.sh
bin/lib/slice-remainder.sh bin/lib/split-chain.sh bin/lib/split-watchdog-act.sh
bin/lib/ticket-ownership.sh bin/lib/tracker/board.sh bin/lib/train-shape.sh
bin/lib/triage-park.sh bin/lib/triage-signal.sh"

cp "$REPO/catalog/determinism-lint.conf" "$T/scope.conf"
printf '%s\n' 'scope race-sigpipe-echo (^|/)bin/.*\.sh$' >> "$T/scope.conf"

# hits <file>... -> the number of race-sigpipe-echo finding lines.
hits() {
  local out
  out=$(cd "$REPO" && DETERMINISM_LINT_CONF="$T/scope.conf" bin/test-determinism-lint.sh "$@" 2>&1)
  grep -cE '^[^ ].*: race-sigpipe-echo:' <<<"$out"
}

# --- A: the 17 C4 files are clean -------------------------------------------
set -f
# shellcheck disable=SC2086 # the list is split on purpose, globbing is off
n=$(hits $C4_FILES)
set +f
[ "$n" = 0 ] && ok || bad "A: $n race-sigpipe-echo line(s) left in the C4 files"

# --- B: the check is live ---------------------------------------------------
mkdir -p "$T/b/bin/lib"
OLD_LINE="  printf '%s' \"\${1:-}\" | grep -qiE '^[[:space:]]*(merge train|batch\\()' && return 0" # determinism: ok race-sigpipe-echo fixture: the pre-sweep line case B writes back, not a pipe this suite runs
OLD_LINE="$OLD_LINE" awk '/<<<"\$\{1:-\}" && return 0$/ { print ENVIRON["OLD_LINE"]; next } { print }' \
  "$REPO/bin/lib/train-shape.sh" > "$T/b/bin/lib/train-shape.sh"
if grep -qxF -- "$OLD_LINE" "$T/b/bin/lib/train-shape.sh"; then
  n=$(hits "$T/b/bin/lib/train-shape.sh")
  [ "$n" = 1 ] && ok || bad "B: the restored pipe gave $n hit(s), want 1"
else
  bad "B: could not restore the old pipe in the scratch copy"
fi

# A ~1 MB tail, far past one 64 KiB pipe buffer.
BIG=$(seq 1 40000 | sed 's#.*#docs/notes/file-&.md#')

# --- C: _rt_classify reads a big list correctly -----------------------------
LIST="tests/../bin/x.sh
$BIG"
# A subshell, not bash -c: one argv string is capped at 128 KiB.
# shellcheck source=bin/lib/review-tier.sh
got=$(set -o pipefail; . "$REPO/bin/lib/review-tier.sh" || exit 9; _rt_classify "$LIST" diff-unavailable)
[ "$got" = "T2 reason=unresolvable path(s)" ] && ok || bad "C: _rt_classify gave '$got'"

# --- D: train_is_train reads a big title correctly --------------------------
# shellcheck source=bin/lib/train-shape.sh
(set -o pipefail; . "$REPO/bin/lib/train-shape.sh" || exit 9; train_is_train "merge train (3 PRs)
$BIG" "feature/x")
rc=$?
[ "$rc" = 0 ] && ok || bad "D: train_is_train returned $rc, want 0"

echo "sigpipe-echo-bin-c4: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
