#!/bin/bash
# tests/flaky-quarantine-gate.bh-2632-test.sh — BH-2632 (BH-2517.1): a test the
# operator quarantined is forgiven by the merge conductor's red gate, and
# nothing else is.
#
# Drives the REAL consumer, mc_flake_rerun in bin/lib/mc/classify.sh, over the
# real bin/lib/flaky.sh. Only the transports are stubbed: the ledger read
# (metric_flakes_list), the quarantine read (metric_flake_quarantine_list), the
# run reads (flaky_failed_runs / flaky_run_tests), the attempt store and gh.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=bin/lib/flaky.sh
. "$DIR/bin/lib/flaky.sh" || { echo "FAIL: cannot source bin/lib/flaky.sh"; exit 1; }
# shellcheck source=bin/lib/mc/classify.sh
. "$DIR/bin/lib/mc/classify.sh" || { echo "FAIL: cannot source bin/lib/mc/classify.sh"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

TODAY=$(date -u +%F)
LEDGER=""          # TSV rows metric_flakes_list answers
QUAR_REPO=""       # the repo the quarantine fixture belongs to
QUAR_NAMES=""      # its active test names
QUAR_FAIL=0        # 1 = the quarantine read fails with no output
FAILING=""         # the failing test names flaky_run_tests reports
ATTEMPTED=1        # mc_attempt_has rc (1 = no attempt yet)

metric_flakes_list() { printf '%s' "$LEDGER"; }
metric_flake_quarantine_list() {
  printf '%s\n' "$1" >>"$T/quar.args"
  [ "$QUAR_FAIL" = 1 ] && return 1
  [ "$1" = "$QUAR_REPO" ] && printf '%s\n' "$QUAR_NAMES"
  return 0
}
flaky_failed_runs() { echo "1|.github/workflows/ci.yml|CI"; }
flaky_run_tests() { printf '%s\n' "$FAILING"; }
mc_attempt_has() { return "$ATTEMPTED"; }
mc_attempt_put() { :; }
mc_rerun_mark() { :; }
mc_rerun_record() { :; }
mc_log() { :; }
# TEST-CHANGE (BH-3804): the rerun re-reads the PR head first (mc_head_still).
# This suite loads no REST client, so the live read is stubbed like the other
# transports: the PR is still at the head every case passes.
mc_pr_live_head() { echo deadbeefcafe; }
gh() { echo "gh $*" >>"$T/gh.calls"; return 0; }

# one flake row per head for test $1 on heads h1..h$2
ledger_for() {
  local t="$1" n="$2" i
  for i in $(seq 1 "$n"); do printf '%s\to/r\tci.yml\t%s\th%s\tflake\n' "$TODAY" "$t" "$i"; done
}

reset() {
  _FLAKY_KNOWN_SLUG=""; _FLAKY_KNOWN_SET=""
  _FLAKY_QUAR_SLUG=""; _FLAKY_QUAR_SET=""
  LEDGER=""; QUAR_REPO="o/r"; QUAR_NAMES=""; QUAR_FAIL=0; FAILING="t1"; ATTEMPTED=1
  : >"$T/gh.calls"; : >"$T/quar.args"
}
run_gate() { mc_flake_rerun o/r "o/r#7" deadbeefcafe; echo $?; }
reruns() { grep -c 'run rerun' "$T/gh.calls" || true; }

# 1 flaked on one head, nothing quarantined: counts as a red
reset; LEDGER=$(ledger_for t1 1)
check "1 one-head flake, no quarantine -> rc 1" "$(run_gate)" 1
check "1 no rerun dispatched" "$(reruns)" 0

# 2 quarantined: forgiven, exactly one rerun
reset; LEDGER=$(ledger_for t1 1); QUAR_NAMES="t1"
check "2 quarantined t1 -> rc 0" "$(run_gate)" 0
check "2 exactly one rerun" "$(reruns)" 1
check "2 the rerun is the failed run of o/r" "$(cat "$T/gh.calls")" "gh run rerun 1 --failed -R o/r"

# 2b retry-not-ignore: this head already had its rerun -> the second red counts
reset; QUAR_NAMES="t1"; ATTEMPTED=0
check "2b quarantined but already re-run on this head -> rc 1" "$(run_gate)" 1
check "2b no second rerun" "$(reruns)" 0

# 3 the quarantine row is off (the active=1 list omits t1)
reset; LEDGER=$(ledger_for t1 1); QUAR_NAMES="other"
check "3 quarantine off -> rc 1" "$(run_gate)" 1
# 3b off only withdraws the manual entry; the ledger threshold still holds
reset; LEDGER=$(ledger_for t1 3); QUAR_NAMES=""
check "3b t1 on 3 heads, no quarantine -> rc 0" "$(run_gate)" 0

# 4 quarantined t1 alongside an unknown t2
reset; QUAR_NAMES="t1"; FAILING=$'t1\nt2'
check "4 quarantined + unknown failing -> rc 1" "$(run_gate)" 1
check "4 no rerun" "$(reruns)" 0

# 5 the quarantine belongs to another repo
reset; QUAR_REPO="o/other"; QUAR_NAMES="t1"
check "5 quarantine for o/other -> rc 1" "$(run_gate)" 1
check "5 the read was scoped to o/r" "$(sort -u "$T/quar.args")" "o/r"

# 6 the quarantine read fails -> empty set, never "all quarantined"
reset; QUAR_FAIL=1
check "6 quarantine read fails -> rc 1" "$(run_gate)" 1
# 6b no quarantine client at all
reset; QUAR_NAMES="t1"
(
  unset -f metric_flake_quarantine_list
  rc=$(run_gate)
  [ "$rc" = 1 ] && echo "ok   6b no quarantine client -> rc 1" || echo "FAIL 6b no quarantine client (got $rc, want 1)"
) >"$T/6b.out"
cat "$T/6b.out"; if grep -q '^ok' "$T/6b.out"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi

# 6c the quarantine read is memoised per slug
reset; QUAR_NAMES="t1"
flaky_quarantined_set o/r >/dev/null; flaky_quarantined_set o/r >/dev/null
check "6c one quarantine read across two calls for the same slug" "$(wc -l <"$T/quar.args" | tr -d ' ')" 1

# 7 the quarantine never leaks into the ledger set (bin/flaky-quarantine.sh reads it)
reset; LEDGER=$(ledger_for t9 3); QUAR_NAMES=$'t1\nt9'
check "7 flaky_known_set carries only the ledger's flake" "$(flaky_known_set o/r)" "t9"
check "7 flaky_gate_set is the deduped union" "$(flaky_gate_set o/r)" $'t1\nt9'

# 8 exact match: case and whitespace variants are not the quarantined name
reset; QUAR_NAMES="t1"; FAILING="T1"
check "8 failing T1 vs quarantined t1 -> rc 1" "$(run_gate)" 1
reset; QUAR_NAMES="t1"
check "8b flaky_all_known: ' t1' is not t1" "$(flaky_all_known o/r <<<' t1'; echo $?)" 1
check "8b flaky_all_known: t1 is t1" "$(flaky_all_known o/r <<<'t1'; echo $?)" 0
reset; QUAR_NAMES="T1"; FAILING="t1"
check "8c failing t1 vs quarantined T1 -> rc 1" "$(run_gate)" 1

# the header usage block names both functions
hdr=$(awk '/^[a-z_]+\(\) *\{/{exit} {print}' "$DIR/bin/lib/flaky.sh")
for fn in flaky_quarantined_set flaky_gate_set; do
  if grep -q "#   $fn" <<<"$hdr"; then ok "header names $fn"; else bad "header names $fn"; fi
done

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
