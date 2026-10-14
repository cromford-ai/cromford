#!/bin/bash
# tests/sigpipe-echo-bin-batch2.bh-6653-test.sh — BH-6653 (BH-6109 slice C2):
# the 17 C2 bin/ files carry no race-sigpipe-echo hit, and a swept helper finds
# a TRUE match on a big input under pipefail instead of reading it as rc 141.
#
# The shipped conf does not scan bin/ for this rule yet (slice C6 adds the
# scope line), so the lint cases run a scratch copy of the shipped conf with
# that scope line appended. A guard case proves the copy really scans bin/.
#
# determinism: ok-file race-sigpipe-echo the guard fixture below is the printf pipe shape as DATA
# Run from anywhere: tests/sigpipe-echo-bin-batch2.bh-6653-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
LINT="$REPO/bin/test-determinism-lint.sh"
mkdir -p "$T/h/flags"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

C2_FILES=(
  bin/lib/cost-row.sh bin/lib/dequeue-watch/act.sh bin/lib/dequeue-watch/classify.sh
  bin/lib/e2e-paths.sh bin/lib/egress.sh bin/lib/evidence.sh bin/lib/fc-board.sh
  bin/lib/fc-issues.sh bin/lib/fix-delta-review.sh bin/lib/flaky.sh
  bin/lib/gh-pr-create.sh bin/lib/gh-shim/pr-read.sh bin/lib/hotspot-context.sh
  bin/lib/ironlaw-carry.sh bin/lib/issue-state-lib.sh bin/lib/jobs/flags.sh
  bin/lib/jobs/req.sh
)

cp "$REPO/catalog/determinism-lint.conf" "$T/scope.conf"
printf '%s\n' 'scope race-sigpipe-echo (^|/)bin/.*\.sh$' >> "$T/scope.conf"
run() { OUT=$(HARNESS="$T/h" DETERMINISM_LINT_CONF="$T/scope.conf" bash "$LINT" "$@" 2>&1); RC=$?; }

# ── 1. guard: the scoped conf flags the shape in a bin/ file ─────────────────
mkdir -p "$T/g/bin"
cat > "$T/g/bin/x.sh" <<'FIX'
#!/bin/bash
set -uo pipefail
printf '%s\n' "$X" | grep -q y
FIX
run "$T/g/bin/x.sh"
grep -qE 'x\.sh:3: race-sigpipe-echo:' <<<"$OUT" && ok \
  || bad "1: the scoped conf did not flag a bin/ printf pipe (rc=$RC): $OUT"

# ── 2. the 17 C2 files are clean under the scoped conf ───────────────────────
paths=(); for f in "${C2_FILES[@]}"; do paths+=("$REPO/$f"); done
run "${paths[@]}"
if grep -qE ': race-sigpipe-echo:' <<<"$OUT"; then
  bad "2: race-sigpipe-echo hits left in the C2 files: $(grep -oE '^[^ ]+: race-sigpipe-echo:' <<<"$OUT")"
else ok; fi

# ── 3/4. production helper: e2e_check_name under pipefail ────────────────────
# ~700 KB, the match on line 1: the old printf | grep -q pipe gave rc 141 here.
# A subshell, not `bash -c`: one 700 KB argv string is over the kernel's
# per-argument limit, and a shell function call has no such limit.
BIG=$(printf 'e2e tests\n'; for ((i = 0; i < 100000; i++)); do printf 'filler-line\n'; done)
call() ( set -o pipefail; . "$REPO/bin/lib/e2e-paths.sh"; e2e_check_name "$1" )
call "$BIG"; rc=$?
[ "$rc" = 0 ] && ok || bad "3: e2e_check_name on a big true match returned rc $rc (want 0)"
call ""; rc=$?
[ "$rc" = 1 ] && ok || bad "4: e2e_check_name '' returned rc $rc (want 1)"
call "Production QA"; rc=$?
[ "$rc" = 0 ] && ok || bad "4: e2e_check_name 'Production QA' returned rc $rc (want 0)"
call "Typecheck"; rc=$?
[ "$rc" = 1 ] && ok || bad "4: e2e_check_name 'Typecheck' returned rc $rc (want 1)"

echo "sigpipe-echo-bin-batch2: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
