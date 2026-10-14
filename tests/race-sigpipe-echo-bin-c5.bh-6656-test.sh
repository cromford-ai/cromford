#!/bin/bash
# tests/race-sigpipe-echo-bin-c5.bh-6656-test.sh — BH-6656 (BH-6109 slice C5):
# the 17 bin/ files of batch 5 hold no race-sigpipe-echo line.
#
#   THE PROPERTY UNDER TEST: a short-circuiting consumer (grep -q/-m, head) on
#   a here-string gives the same answer for a big input as for a small one.
#   The printf/echo pipe it replaces read a TRUE match on line 1 of a ~1 MB
#   input as a miss under pipefail (printf took SIGPIPE, rc 141).
#
# The bin/ scope line for the rule is not in catalog/determinism-lint.conf yet
# (slice C6 adds it last), so C1 and C2 lint with a copy of the shipped conf
# plus that one scope line.
#
# determinism: ok-file race-sigpipe-echo C2 writes the printf pipe shape as lint fixture DATA; this suite reads here-strings
# Run from anywhere: tests/race-sigpipe-echo-bin-c5.bh-6656-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
HERE=$(cd "$(dirname "$0")/.." && pwd)
LINT="$HERE/bin/test-determinism-lint.sh"
mkdir -p "$T/h/flags"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

C5_FILES=(
  bin/lib/triage-skip-evidence.sh bin/lib/triage-state-pr.sh
  bin/lib/triage-state-unreadable.sh bin/lib/triage-state.sh
  bin/model-route-seed-lint.sh bin/nightly-strict-ratchets.sh
  bin/pipeline-health.sh bin/plan-overlap.sh bin/plan-sibling.sh
  bin/progress-push.sh bin/qa-session.sh bin/readiness-report.sh
  bin/rebase-train-ahead.sh bin/registry-seed.sh bin/registry.sh
  bin/restore-lab.sh bin/result-prefix-ok.sh
)

cp "$HERE/catalog/determinism-lint.conf" "$T/scope.conf"
printf '%s\n' 'scope race-sigpipe-echo (^|/)bin/.*\.sh$' >> "$T/scope.conf"

# C1: the scope-conf lint over the 17 files reports no race-sigpipe-echo line.
OUT=$(cd "$HERE" && HARNESS="$T/h" DETERMINISM_LINT_CONF="$T/scope.conf" bash "$LINT" "${C5_FILES[@]}" 2>&1)
HITS=$(grep -c ': race-sigpipe-echo:' <<<"$OUT")
if [ "$HITS" = 0 ] && grep -q '17 files scanned' <<<"$OUT"; then ok
else bad "C1: $HITS race-sigpipe-echo line(s) in the C5 files: $(grep ': race-sigpipe-echo:' <<<"$OUT" | cut -d: -f1,2 | tr '\n' ' ')"; fi

# C2: the same conf flags the shape in a bin/ file, so C1 is not green by vacuum.
mkdir -p "$T/c/bin"
printf '#!/bin/bash\nset -uo pipefail\n%s\n' "printf '%s\\n' \"\$X\" | grep -q y" > "$T/c/bin/x.sh"
OUT=$(cd "$T/c" && HARNESS="$T/h" DETERMINISM_LINT_CONF="$T/scope.conf" bash "$LINT" bin/x.sh 2>&1)
if grep -qE '(^|/)bin/x\.sh:3: race-sigpipe-echo:' <<<"$OUT"; then ok
else bad "C2: scope conf did not flag bin/x.sh:3: $OUT"; fi

# C3: tse_inprogress, through the shipped lib, on ~1 MB whose line 1 matches.
BIG=$(printf 'build in progress\n'; head -c 1048576 /dev/zero | tr '\0' 'x')
RC=$( set -o pipefail
      # shellcheck source=/dev/null
      . "$HERE/bin/lib/triage-skip-evidence.sh"
      tse_inprogress "$BIG"; echo $? )
[ "$RC" = 0 ] && ok || bad "C3: tse_inprogress on a 1 MB match-on-line-1 input rc=$RC, want 0"
RC=$( set -o pipefail
      # shellcheck source=/dev/null
      . "$HERE/bin/lib/triage-skip-evidence.sh"
      tse_inprogress "awaiting merge"; echo $? )
[ "$RC" = 1 ] && ok || bad "C3: tse_inprogress on 'awaiting merge' rc=$RC, want 1"

# C4: result-prefix-ok keeps its answer, including the empty-input edge (R2a).
RPO="$HERE/bin/result-prefix-ok.sh"
bash "$RPO" "" && bad "C4: empty input reads as a RESULT" || ok
bash "$RPO" " PR_CREATED x" && bad "C4: leading-space line reads as a RESULT" || ok
bash "$RPO" "PR_CREATED x" && ok || bad "C4: 'PR_CREATED x' reads as a miss"
LONG=$(printf 'PR_CREATED x\n'; head -c 102400 /dev/zero | tr '\0' 'y')
bash "$RPO" "$LONG" && ok || bad "C4: 100 KB input with 'PR_CREATED x' on line 1 reads as a miss"

# C5: every swept file still parses.
for f in "${C5_FILES[@]}"; do
  bash -n "$HERE/$f" 2>/dev/null && ok || bad "C5: bash -n $f"
done

echo "race-sigpipe-echo-bin-c5: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
