#!/bin/bash
# tests/fixround-verify-tail.bh-10245-test.sh — BH-10245: the
# fix round's last verify steps (the selection gate, the repro re-run) stay
# inside BR_FIX_VERIFY_TIMEOUT, and do not run when an earlier step already
# refuses the push.
#
# THE INCIDENT (2026-11-26, cromford on the Fly pool). 24 rounds ended
# FIX_ROUND_FINISHED verify-timeout. Two rows used up FIX_ROUND_TIMEOUT_RETRIES
# with "killed at the round bound 6600s; last verify line: CI_LOCAL_EXIT: 1":
# ci-local was red, so the push was refused already, and then the selection
# gate ran with its own --timeout (lane.fly-pool.cromford.
# selection_gate_timeout_s = 7200, more than the whole 6600 s round) until the
# round bound killed it. The verify-only retries re-verified the same red
# commit and were killed the same way.
#
#   S1  CI_LOCAL_EXIT: 1 in the verify output: the gate does not run,
#       SELECTION_GATE_EXIT: skipped (...), and that line is not a timeout
#   S2  CLOSURE_LINT_EXIT: 1: the same
#   S3  a green verify so far with budget left: the gate runs, its --timeout is
#       the seconds left, not the 7200 knob
#   S4  the capped gate answers could-not-run and the budget is spent:
#       VERIFY_TIMEOUT: selection-gate (brvb_is_timeout says yes)
#   S5  the budget spent before the gate: the gate does not run,
#       VERIFY_TIMEOUT: selection-gate
#   S6  no verify output argument (another caller): the knob timeout as before
#   R1  repro owed after CI_LOCAL_EXIT: 1: frr_confirm not called, rc 0,
#       REPRO_EXIT: skipped (...)
#   R2  repro owed, the budget spent: frr_confirm not called, rc 0,
#       VERIFY_TIMEOUT: repro
#   R3  repro owed, green so far, budget left: frr_confirm runs as before
#   D1  the real driver passes "$out" to both calls inside br_fix_round
# Run: HARNESS_TEST_SANDBOX=1 bash tests/fixround-verify-tail.bh-10245-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset SELECTION_GATE SELECTION_GATE_P FIX_VERIFY_TIMEOUT BR_FIX_VERIFY_TIMEOUT BRVB_T0 BRVB_BUDGET

FB="$DIR/bin/blocked-resolver.d/bh-9906-verify-budget.sh"
FG="$DIR/bin/blocked-resolver.d/bh-8062-selection-gate.sh"
FR="$DIR/bin/blocked-resolver.d/bh-9472-fixround-repro.sh"
DRIVER="$DIR/bin/blocked-resolver.sh"
for f in "$FB" "$FG" "$FR"; do [ -r "$f" ] || { echo "FAIL: setup: $f does not exist"; exit 1; }; done
mkdir -p "$T/h/logs"
for f in bin/lib/selection-gate.sh bin/lib/fixround-repro.sh; do
  scratch_install_closure "$f" "$T/h" >/dev/null || { echo "FAIL: setup: scratch_install_closure $f"; exit 1; }
done

# A worktree with a stub bin/selection-gate.sh: it records its --timeout,
# sleeps STUB_SLEEP seconds and exits STUB_RC with a gate.txt.
WT="$T/wt"; mkdir -p "$WT/bin"
cat > "$WT/bin/selection-gate.sh" <<'SH'
#!/bin/bash
out=""; to=""
while [ $# -gt 0 ]; do case "$1" in --out) out="$2" ;; --timeout) to="$2" ;; esac; shift; done
echo "ran timeout=$to" >> "$STUB_LOG"
sleep "${STUB_SLEEP:-0}"
mkdir -p "$out"
printf 'head: -\nbase: -\nsuites: 7\nrc: %s\nred: -\nnoted: -\nmode: batch\nwhy: %s\nquarantine: env\n' \
  "${STUB_WORD:-0}" "${STUB_WHY:--}" > "$out/gate.txt"
exit "${STUB_RC:-0}"
SH
chmod +x "$WT/bin/selection-gate.sh"

# sg <case> <verify-out-so-far|-> <budget-s> [pre-sleep] — the gate call as the
# driver makes it, its block appended to $T/<case>.out (the verify output).
sg() {
  local c="$1" so="$2" b="$3" pre="${4:-0}"
  : > "$T/$c.stub"; : > "$T/$c.out"
  [ "$so" = - ] || printf '%s\n' "$so" > "$T/$c.out"
  ( export H="$T/h" STUB_LOG="$T/$c.stub" SELECTION_GATE_TIMEOUT_S=7200
    say() { :; }
    . "$FB" || exit 9; . "$FG" || exit 9
    FIX_VERIFY_TIMEOUT="$b"; brvb_budget
    sleep "$pre"
    if [ "$so" = - ]; then br_sg_verify "$WT" origin/main "$T/$c.sg" demo
    else br_sg_verify "$WT" origin/main "$T/$c.sg" demo "$T/$c.out"; fi ) >> "$T/$c.out" 2>&1
}
isto() { ( say() { :; }; . "$FB"; brvb_is_timeout "$1" ); }

sg s1 $'== ci-local ==\nCI_LOCAL_EXIT: 1' 2700
[ ! -s "$T/s1.stub" ] && grep -q '^SELECTION_GATE_EXIT: skipped (an earlier verify step is red' "$T/s1.out" && ! isto "$T/s1.out" && ok \
  || bad "S1 red ci-local: the gate ran or no skip line: stub [$(cat "$T/s1.stub")] out [$(cat "$T/s1.out")]"
sg s2 $'== scratch-closure ==\nCLOSURE_LINT_EXIT: 1\n== ci-local ==\nCI_LOCAL_EXIT: 0' 2700
[ ! -s "$T/s2.stub" ] && grep -q '^SELECTION_GATE_EXIT: skipped (an earlier verify step is red' "$T/s2.out" && ok \
  || bad "S2 red closure lint: stub [$(cat "$T/s2.stub")] out [$(cat "$T/s2.out")]"
sg s3 $'CLOSURE_LINT_EXIT: 0\nCI_LOCAL_EXIT: 0' 100
t3=$(sed -n 's/^ran timeout=//p' "$T/s3.stub")
[ -n "$t3" ] && [ "$t3" -le 100 ] 2>/dev/null && [ "$t3" -ge 90 ] && grep -qx 'SELECTION_GATE_EXIT: 0' "$T/s3.out" && ok \
  || bad "S3 the gate's --timeout is not the seconds left (want 90..100, got '$t3'): out [$(cat "$T/s3.out")]"
STUB_SLEEP=3 STUB_RC=3 STUB_WORD=could-not-run STUB_WHY=timeout sg s4 $'CI_LOCAL_EXIT: 0' 2
grep -q '^SELECTION_GATE_EXIT: could-not-run' "$T/s4.out" && grep -qx 'VERIFY_TIMEOUT: selection-gate' "$T/s4.out" && isto "$T/s4.out" && ok \
  || bad "S4 a capped gate cut by the budget is not a verify timeout: out [$(cat "$T/s4.out")]"
sg s5 $'CI_LOCAL_EXIT: 0' 1 2
[ ! -s "$T/s5.stub" ] && grep -qx 'VERIFY_TIMEOUT: selection-gate' "$T/s5.out" && ok \
  || bad "S5 a spent budget still ran the gate: stub [$(cat "$T/s5.stub")] out [$(cat "$T/s5.out")]"
sg s6 - 100
[ "$(sed -n 's/^ran timeout=//p' "$T/s6.stub")" = 7200 ] && ! grep -q VERIFY_TIMEOUT "$T/s6.out" && ok \
  || bad "S6 no verify output arg: the knob timeout changed: stub [$(cat "$T/s6.stub")]"

# rp <case> <verify-out-so-far> <budget-s> [pre-sleep] — brfr_verify with a repro owed.
rp() {
  local c="$1" so="$2" b="$3" pre="${4:-0}"
  : > "$T/$c.confirm"
  printf '%s\n' "$so" > "$T/$c.out"
  printf 'file tests/x-test.sh\n' > "$T/$c.pre.repro.txt"
  ( export H="$T/h"
    say() { :; }
    . "$FB" || exit 9; . "$FR" || exit 9
    frr_confirm() { echo called >> "$T/$c.confirm"; return 0; }
    p=demo; rkey=x; reason=ci-red
    FIX_VERIFY_TIMEOUT="$b"; brvb_budget
    sleep "$pre"
    brfr_verify "$WT" "$T/$c.pre" "$T/$c.out"; echo "RC=$?" > "$T/$c.rc" ) >> "$T/$c.out" 2>&1
}
rp r1 'CI_LOCAL_EXIT: 1' 2700
[ ! -s "$T/r1.confirm" ] && grep -qx 'RC=0' "$T/r1.rc" && grep -q '^REPRO_EXIT: skipped (an earlier verify step is red' "$T/r1.out" && ok \
  || bad "R1 repro after a red ci-local: confirm [$(cat "$T/r1.confirm")] $(cat "$T/r1.rc") out [$(cat "$T/r1.out")]"
rp r2 'CI_LOCAL_EXIT: 0' 1 2
[ ! -s "$T/r2.confirm" ] && grep -qx 'RC=0' "$T/r2.rc" && grep -qx 'VERIFY_TIMEOUT: repro' "$T/r2.out" && isto "$T/r2.out" && ok \
  || bad "R2 repro with the budget spent: confirm [$(cat "$T/r2.confirm")] $(cat "$T/r2.rc") out [$(cat "$T/r2.out")]"
rp r3 'CI_LOCAL_EXIT: 0' 2700
[ -s "$T/r3.confirm" ] && grep -qx 'RC=0' "$T/r3.rc" && grep -qx 'REPRO_EXIT: passes' "$T/r3.out" && ok \
  || bad "R3 repro green so far: confirm [$(cat "$T/r3.confirm")] out [$(cat "$T/r3.out")]"

# D1: both calls in br_fix_round pass the verify output "$out".
awk '/^br_fix_round\(\) \{/ {f=1} f && /^}/ {f=0}
     f && /br_sg_verify "\$wt" "origin\/\$\{mref:-main\}" "\$ST\/\$p\/\$ck\.selection-gate" "\$p" "\$out"/ {a=1}
     f && /! brfr_verify "\$wt" "\$ST\/\$p\/\$ck" "\$out"/ {b=1}
     END {exit !(a && b)}' "$DRIVER" && ok || bad "D1 the driver does not pass \"\$out\" to br_sg_verify and brfr_verify in br_fix_round"

echo "fixround-verify-tail.bh-10245: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
