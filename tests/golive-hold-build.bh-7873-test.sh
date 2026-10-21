#!/bin/bash
# tests/golive-hold-build.bh-7873-test.sh — a go-live hold never defers a build
# (BH-7873). bin/lib/hold.sh classifies a `NEEDS-HUMAN: go-live:` marker as
# `clear<TAB>hold:go-live <at> <step>` (BH-7123 wave B). hold_is_pause matched
# any `<TAB>hold:` text, so to_hold_verdict said held, HOLD_STAGE_CHECK wrote
# BUILD_DEFERRED and exited 3, and bin/fly-pool.sh (which reads the first word)
# spawned a Fly machine for every re-offer: TK-1296 deferred 10 times, TK-1292
# 12 times.
#   §P  hold_is_pause / hold_is_abandon on the exact verdicts
#   §V  to_hold_verdict: go-live is clear (rc 1), a real pause is held (rc 0)
#   §S  HOLD_STAGE_CHECK: go-live exits 0 with no BUILD_DEFERRED; a pause exits 3
#   §A  bin/fly-pool.sh pool_hold_check and HOLD_STAGE_CHECK agree on both
#   §W  the stranded watch (orphan-reconcile's hold_classify rc) reads a go-live
#       thread as clear, so the marker is never a reason to park
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/golive-hold-build.bh-7873-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS_TEST_SANDBOX=1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

GOLIVE=$'clear\thold:go-live 2026-10-18T04:50:44Z Go-live for Stripe: add the live key on Vercel'
PAUSE=$'held\thold:operator 2026-10-18T04:50:44Z HOLD: wait for the operator'
COMMENT=$'held\thold:comment 2026-10-18T04:50:44Z HOLD: wait'
WAITING=$'held\thold:waiting-on-human 2026-10-18T04:50:44Z run the probe'
ABANDON=$'held\tabandon:comment 2026-10-18T04:50:44Z ABANDON this one'

# ── §P ─────────────────────────────────────────────────────────────────────
(
  PASS=0; FAIL=0
  . "$DIR/bin/lib/hold.sh" || { echo "FAIL: cannot source hold.sh"; exit 1; }
  hold_is_pause "$GOLIVE"  && bad "P1: clear<TAB>hold:go-live must not be a pause" || ok
  hold_is_abandon "$GOLIVE" && bad "P1: go-live is not an abandon" || ok
  hold_is_pause "$PAUSE"   && ok || bad "P2: held<TAB>hold:operator must stay a pause"
  hold_is_pause "$COMMENT" && ok || bad "P3: held<TAB>hold:comment must stay a pause"
  hold_is_pause "$WAITING" && ok || bad "P4: held<TAB>hold:waiting-on-human must stay a pause"
  hold_is_pause $'hold\thold:label hold' && ok || bad "P5: a first field 'hold' is a pause"
  hold_is_pause "$ABANDON" && bad "P6: an ABANDON is not a pause" || ok
  hold_is_abandon "$ABANDON" && ok || bad "P6: an ABANDON is an abandon"
  hold_is_pause $'clear\tlifted-by-comment 2026-10-18T04:50:44Z' && bad "P7: a lift is not a pause" || ok
  hold_is_pause $'clear\thold:comment x' && bad "P8: any clear verdict is not a pause" || ok
  hold_is_pause $'held\tclosed' && bad "P9: held<TAB>closed is a fact, not a pause" || ok
  echo "P: $PASS $FAIL" > "$T/p.count"
)
read -r _ a b < "$T/p.count" 2>/dev/null || { a=0; b=1; echo "FAIL: §P did not run"; }
PASS=$((PASS+a)); FAIL=$((FAIL+b))

# ── §V + §S + §A: one verdict at a time through all three readers ──────────
awk '/^HOLD_STAGE_CHECK\(\) \{/ {p=1} p{print} p&&/^}$/{exit}' "$DIR/bin/lib/rb/gates.sh" > "$T/stage.sh"
awk '/^pool_hold_check\(\) \{/ {p=1} p{print} p&&/^}$/{exit}' "$DIR/bin/fly-pool.sh" > "$T/pool.sh"
[ -s "$T/stage.sh" ] && ok || bad "S0: HOLD_STAGE_CHECK not found in bin/lib/rb/gates.sh"
[ -s "$T/pool.sh" ] && ok || bad "A0: pool_hold_check not found in bin/fly-pool.sh"

# run_one <verdict> — prints "verdict=<rc> stage=<exit> deferred=<0|1> pool=<rc>"
run_one() {
  local v="$1" vr sr pr d
  vr=$( export HARNESS="$T/h"; mkdir -p "$T/h/logs"
        . "$DIR/bin/lib/hold.sh" >/dev/null 2>&1; . "$DIR/bin/lib/ticket-ownership.sh" >/dev/null 2>&1
        hold_check() { printf '%s\n' "$HV"; return 0; }
        HV="$v" to_hold_verdict o/r 7 >/dev/null; echo $? )
  rm -f "$T/result.txt"; mkdir -p "$T/build"
  sr=$( export HARNESS="$T/h"; HV="$v"
        . "$DIR/bin/lib/hold.sh" >/dev/null 2>&1; . "$DIR/bin/lib/ticket-ownership.sh" >/dev/null 2>&1
        hold_check() { printf '%s\n' "$HV"; return 0; }
        to_issue_repo() { printf 'o/r'; }
        FACTORY_STOP_CHECK() { return 0; }
        STAMP() { echo 2026-10-21T00:00:00Z; }
        RESULT() { printf '%s\n' "$*" >> "$T/result.txt"; }
        PROJECT=project-6 TICKET=1296 KEY=TK-1296 BUILD="$T/build"
        . "$T/stage.sh"
        ( HOLD_STAGE_CHECK queue ); echo $? )
  d=0; grep -q BUILD_DEFERRED "$T/result.txt" 2>/dev/null && d=1
  pr=$( declare -A _POOL_HOLD_CACHE=(); POOL_SLUG=o/r; HV="$v"
        hold_check() { printf '%s\n' "$HV"; return 0; }
        . "$T/pool.sh"
        pool_hold_check 1296 >/dev/null; echo $? )
  printf 'verdict=%s stage=%s deferred=%s pool=%s' "$vr" "$sr" "$d" "$pr"
}

R=$(run_one "$GOLIVE")
[ "$R" = 'verdict=1 stage=0 deferred=0 pool=0' ] && ok \
  || bad "V1/S1/A1: a go-live hold must be clear everywhere (to_hold_verdict rc 1, HOLD_STAGE_CHECK exit 0, no BUILD_DEFERRED, pool proceeds); got '$R'"
R=$(run_one "$PAUSE")
[ "$R" = 'verdict=0 stage=3 deferred=1 pool=1' ] && ok \
  || bad "V2/S2/A2: a real pause must hold everywhere (to_hold_verdict rc 0, HOLD_STAGE_CHECK exit 3 + BUILD_DEFERRED, no machine); got '$R'"
R=$(run_one "$WAITING")
[ "$R" = 'verdict=0 stage=3 deferred=1 pool=1' ] && ok \
  || bad "V3/S3/A3: an ordinary NEEDS-HUMAN must hold everywhere; got '$R'"

# ── §W: the stranded watch reads hold_classify's rc, and go-live is rc 0 ───
(
  PASS=0; FAIL=0
  . "$DIR/bin/lib/hold.sh" || exit 1
  OPEN=$(jq -nc '{state:"open", labels:[{name:"ai-build"}], title:"TK-1296: a thing", body:"## Scope"}')
  CM=$(jq -nc --arg b 'NEEDS-HUMAN: go-live: add the live Stripe key on Vercel' \
        '[{body:$b, created_at:"2026-10-18T04:50:44Z", user:{type:"User"}}]')
  v=$(hold_classify "$OPEN" "$CM"); rc=$?
  case "$rc:$v" in
    0:*) ok ;;
    *) bad "W1: hold_classify must answer rc 0 on a go-live-only thread (the stranded watch parks only rc 1): rc $rc '$v'" ;;
  esac
  hold_is_pause "$v" && bad "W1: that verdict must not read as a pause: '$v'" || ok
  echo "W: $PASS $FAIL" > "$T/w.count"
)
read -r _ a b < "$T/w.count" 2>/dev/null || { a=0; b=1; echo "FAIL: §W did not run"; }
PASS=$((PASS+a)); FAIL=$((FAIL+b))

echo "golive-hold-build.bh-7873: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
