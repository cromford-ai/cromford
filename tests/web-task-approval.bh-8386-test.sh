#!/bin/bash
# tests/web-task-approval.bh-8386-test.sh — BH-8386: bin/lib/web-task/approval.sh,
# the web-task write approval over wh_request_human (bin/lib/web-human.sh).
# Note: docs/notes/2026-10-26-BH-8386-web-task-approval.md.
#
#   S1     sourcing defines the two functions, prints nothing, loads no web-human
#   A1-A9  the outcome map of wh_request_human and the argv it gets
#   M1     no web-human.sh beside the lib: `not available`, rc 69
#   E1     the real web-human.sh, loaded lazily, fails closed with no worker env
#   U1-U7  usage: rc 2 and wh_request_human is never called
#   R1-R3  the record round-trip across a subshell
#   N1     two requests in one run get two ids
#   T1-T2  wt_approval_status refuses a path and says `unknown` for no record
#
# Each case copies the REAL lib into its own scratch tree, beside a stub
# web-human.sh that logs its argv and answers with the case's rc, stdout and
# stderr. No network, no wall clock.
# Run from anywhere: tests/web-task-approval.bh-8386-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/web-task/approval.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
[ -s "$LIB" ] && ok "source exists: bin/lib/web-task/approval.sh" || bad "missing bin/lib/web-task/approval.sh"

N=0
# mk [nostub] — a new case tree; sets C (the case dir). The stub reads its
# answer from $C/rc, $C/out (printed as is) and $C/err.
mk() {
  N=$((N+1)); C="$T/case$N"
  mkdir -p "$C/bin/lib/web-task" "$C/rec"
  # scratch-closure-allow: the lib is copied beside a stub web-human.sh on purpose; its real closure is E1
  cp "$LIB" "$C/bin/lib/web-task/approval.sh" 2>/dev/null
  : > "$C/calls"; echo 0 > "$C/rc"; printf 'done' > "$C/out"; : > "$C/err"
  [ "${1:-}" = nostub ] && return 0
  cat > "$C/bin/lib/web-human.sh" <<EOF
wh_request_human() {
  printf '%s\n' "\$@" > "$C/calls"
  cat "$C/err" >&2
  cat "$C/out"
  return "\$(cat "$C/rc")"
}
EOF
}
# run <args...> — in a child shell with the case env; sets RC, OUT, ERR.
run() {
  RC=0
  OUT=$(cd "$C" && LANE_RUN_ID="${RUN_ID-77}" WT_APPROVAL_DIR="$C/rec" bash -c \
    '. bin/lib/web-task/approval.sh || exit 99; "$@"' _ "$@" 2>"$C/stderr") || RC=$?
  ERR=$(cat "$C/stderr")
}
J='{"site":"example.com","action":"click Submit"}'
nrec() { find "$C/rec" -type f | wc -l | tr -d ' '; }

# --- S1 ------------------------------------------------------------------------
mk
s1=$(cd "$C" && bash -c '. bin/lib/web-task/approval.sh 2>&1; echo "rc=$?"
  declare -F wt_approval_request wt_approval_status >/dev/null && echo defs
  declare -F wh_request_human >/dev/null && echo loaded')
[ "$s1" = $'rc=0\ndefs' ] && ok "S1 source: silent, both functions, web-human not loaded" || bad "S1 got: $s1"

# --- A1-A9 ---------------------------------------------------------------------
mk; run wt_approval_request proj BH-1 "$J"
if [ "$RC" = 0 ] && [ "$OUT" = 77-1 ] && [ "$(cat "$C/rec/77-1" 2>/dev/null)" = approved ]; then
  run wt_approval_status 77-1
  [ "$RC" = 0 ] && [ "$OUT" = approved ] && ok "A1 done -> id 77-1, status approved" || bad "A1 status rc=$RC out=$OUT"
else bad "A1 rc=$RC out=$OUT err=$ERR"; fi

mk; printf 'web-human: telegram: sent 1\nweb-human: board: posted\n' > "$C/err"
run wt_approval_request proj BH-1 "$J"
[ "$RC" = 0 ] && [ "$(cat "$C/rec/$OUT" 2>/dev/null)" = approved ] && [[ $ERR == *"web-human: telegram: sent 1"* ]] \
  && ok "A2 done with stderr lines -> approved, stderr passes through" || bad "A2 rc=$RC out=$OUT err=$ERR"

mk; echo 3 > "$C/rc"; : > "$C/out"; echo 'web-human: cancelled' > "$C/err"
run wt_approval_request proj BH-1 "$J"; id=$OUT
run wt_approval_status "$id"
[ "$id" = 77-1 ] && [ "$RC" = 0 ] && [ "$OUT" = denied ] && ok "A3 cancelled -> denied" || bad "A3 id=$id rc=$RC out=$OUT"

mk; echo 4 > "$C/rc"; : > "$C/out"; echo 'web-human: waiting on human (step 42)' > "$C/err"
run wt_approval_request proj BH-1 "$J"; id=$OUT; rc1=$RC
rec=$(cat "$C/rec/$id" 2>/dev/null)
run wt_approval_status "$id"
[ "$rc1" = 0 ] && [ "$rec" = "pending 42" ] && [ "$RC" = 0 ] && [ "$OUT" = pending ] && [[ $ERR == *"wt-approval: step 42"* ]] \
  && ok "A4 waiting -> pending, record 'pending 42', step on stderr" || bad "A4 rc1=$rc1 rec=$rec rc=$RC out=$OUT err=$ERR"

for r in 1 2; do
  mk; echo "$r" > "$C/rc"; : > "$C/out"
  run wt_approval_request proj BH-1 "$J"
  [ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$(nrec)" = 0 ] && [[ $ERR == *"web-human rc $r"* ]] \
    && ok "A$((r+4)) web-human rc $r -> rc 1, no id, no record" || bad "A$((r+4)) rc=$RC out=$OUT recs=$(nrec) err=$ERR"
done

i=0
for o in 'Done' '' '123456' $'done\n'; do
  i=$((i+1)); mk; printf '%s' "$o" > "$C/out"
  run wt_approval_request proj BH-1 "$J"
  [ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$(nrec)" = 0 ] && ok "A7.$i rc 0 + stdout $(printf %q "$o") -> rc 1, no record" \
    || bad "A7.$i out=$(printf %q "$o") rc=$RC id=$OUT recs=$(nrec)"
done

mk; run wt_approval_request proj BH-1 "$(jq -nc '{site:"example.com", action:"click\nSub\tmit"}')"
want=$'proj\nexample.com\napprove\nApprove write on example.com for BH-1: click Sub mit'
[ "$RC" = 0 ] && [ "$(cat "$C/calls")" = "$want" ] && ok "A8 argv: kind approve, one-line prompt, no --shot/--issue" \
  || bad "A8 rc=$RC calls=$(cat "$C/calls")"

mk; run wt_approval_request proj BH-1 '{"site":"example.com","action":"x","issue":"example-org/x#7","shot":"/tmp/s.png"}'
want=$'proj\nexample.com\napprove\nApprove write on example.com for BH-1: x\n--shot\n/tmp/s.png\n--issue\nexample-org/x#7'
[ "$RC" = 0 ] && [ "$(cat "$C/calls")" = "$want" ] && ok "A9 --shot and --issue passed from the json" \
  || bad "A9 rc=$RC calls=$(cat "$C/calls")"

# --- M1 ------------------------------------------------------------------------
mk nostub; run wt_approval_request proj BH-1 "$J"
[ "$RC" = 69 ] && [ "$OUT" = "not available" ] && [ "$(nrec)" = 0 ] && ok "M1 no web-human.sh -> not available, rc 69" \
  || bad "M1 rc=$RC out=$OUT recs=$(nrec)"

# --- E1: the REAL bin/lib/web-human.sh, in place, with no worker env ------------
# The lazy source loads it and its rc 2 (no JOBS_URL ...) fails closed: rc 1.
mkdir -p "$T/e1"
e1=$(cd "$T" && env -u JOBS_URL -u HARNESS_SECRET -u WEB_VAULT_RUN_TOKEN LANE_RUN_ID=77 WT_APPROVAL_DIR="$T/e1" \
  bash -c '. "$1" || exit 99; wt_approval_request proj BH-1 "$2"; echo "rc=$?"
    declare -F wh_request_human >/dev/null && echo loaded' _ "$LIB" "$J" 2>&1)
[[ $e1 == *"web-human rc 2"*$'\nrc=1\nloaded' ]] && [ -z "$(ls -A "$T/e1")" ] \
  && ok "E1 real web-human.sh: loaded lazily, no worker env -> rc 1, no record" || bad "E1 got: $e1"

# --- U1-U7 ---------------------------------------------------------------------
u=0
uc() {
  u=$((u+1)); mk; run wt_approval_request "$@"
  [ "$RC" = 2 ] && [ ! -s "$C/calls" ] && [ "$(nrec)" = 0 ] && ok "U$u usage: $*" || bad "U$u rc=$RC calls=$(cat "$C/calls") ($*)"
}
uc proj BH-1
uc proj bh-1 "$J"
uc proj BH-1 'not json'
uc proj BH-1 '{"action":"x"}'
uc proj BH-1 '{"site":"example.com","action":""}'
uc proj BH-1 '{"site":"example.com","action":"x","issue":"x#7"}'
RUN_ID='' uc proj BH-1 "$J"

# --- R1-R3: round trip ----------------------------------------------------------
for w in approved:0 denied:3 pending:4; do
  mk; echo "${w#*:}" > "$C/rc"; [ "${w#*:}" = 0 ] || : > "$C/out"
  rt=$(cd "$C" && LANE_RUN_ID=77 WT_APPROVAL_DIR="$C/rec" bash -c '. bin/lib/web-task/approval.sh
    id=$(wt_approval_request proj BH-1 "$1" 2>/dev/null) || exit 1
    wt_approval_status "$id" 2>/dev/null' _ "$J")
  [ "$rt" = "${w%%:*}" ] && ok "R ${w%%:*}: written in a subshell, read in the parent" || bad "R ${w%%:*} got '$rt'"
done

# --- N1 --------------------------------------------------------------------------
mk; run wt_approval_request proj BH-1 "$J"; a=$OUT
run wt_approval_request proj BH-2 "$J"; b=$OUT
[ "$a" = 77-1 ] && [ "$b" = 77-2 ] && ok "N1 two requests -> 77-1, 77-2" || bad "N1 a=$a b=$b"

# --- T1-T2 -----------------------------------------------------------------------
mk; run wt_approval_status ../../etc/passwd
[ "$RC" = 2 ] && [ -z "$OUT" ] && ok "T1 status of a path -> rc 2" || bad "T1 rc=$RC out=$OUT"
run wt_approval_status 77-9
[ "$RC" = 1 ] && [ -z "$OUT" ] && [[ $ERR == *unknown* ]] && ok "T2 status of no record -> unknown, rc 1" || bad "T2 rc=$RC out=$OUT err=$ERR"

echo "web-task-approval: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
