#!/bin/bash
# tests/lane-run-heartbeat-clock.bh-9005-test.sh — BH-9005: the pre-run cap of
# bin/lib/lane-run-heartbeat.sh measured elapsed time in whole `date +%s`
# seconds. A start read late in a second (X.999) and a check after one 1 s
# sleep (X+2.001) read elapsed=2, so with heartbeat_s=1 and max_s=2 the loop
# stopped before its first beat (the nightly B4 red of the BH-8745 suite).
# Sources the real library; _jobs_req, setting_get and lw_log are local stubs,
# so the suite makes 0 network calls. Each case has its own run id.
#
#   C1  a `date` shim that reads 1000 at the start and 1002 after: >= 1 beat
#       before the 2 s cap, one stop line
#   C2  real clock, max 2: 1..2 beats, one stop line, no beat after the stop
#   C3  run-time form (max empty): beats go on, no stop line
#   C4  invalid max (0, abc) is treated as empty: beats go on, no stop line
#   C5  _lrh_now_us with EPOCHREALTIME unset falls back to `date +%s`
#
# Run from anywhere: tests/lane-run-heartbeat-clock.bh-9005-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# shellcheck source=tests/lib/wait-for.sh
. "$(dirname "$0")/lib/wait-for.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }

export HARNESS="$T/h"
mkdir -p "$HARNESS" "$T/shim"
MACHINE=fixture-m
: > "$T/calls"; : > "$T/log"
_jobs_req() { echo "$1 $2" >> "$T/calls"; echo '{"ok":true}'; return 0; }
setting_get() { [ "$1" = lane_run.heartbeat_s ] && echo 1; }
lw_log() { echo "$*" >> "$T/log"; }
# shellcheck source=bin/lib/lane-run-heartbeat.sh
. "$DIR/bin/lib/lane-run-heartbeat.sh" || exit 1
trap 'lrh_stop' EXIT

beats() { grep -c "^POST /api/lane-runs/$1/heartbeat\$" "$T/calls"; }
stops() { grep -c "^run $1: pre-run heartbeat stopped after" "$T/log"; }
# Readiness facts for wait_for: no fixed sleep decides a case (BH-6049).
has_stop()  { [ "$(stops "$1")" -ge 1 ]; }
has_beats() { [ "$(beats "$1")" -ge "$2" ]; }
loop_gone() { [ -z "$LRH_PID" ] || ! kill -0 "$LRH_PID" 2>/dev/null; }

# C1: the `date` shim pins the late start. The first `date +%s` prints 1000,
# every later one 1002; any other call runs the real date.
REAL_DATE=$(command -v date)
cat > "$T/shim/date" <<EOF
#!/bin/bash
if [ "\$*" = "+%s" ]; then
  if [ -e "$T/date.first" ]; then echo 1002; else : > "$T/date.first"; echo 1000; fi
  exit 0
fi
exec "$REAL_DATE" "\$@"
EOF
chmod +x "$T/shim/date"
OLDPATH=$PATH
PATH="$T/shim:$PATH"
lrh_start 901 "" 2
wait_for 10 has_stop 901
lrh_stop
PATH=$OLDPATH
n=$(beats 901); s=$(stops 901)
[ "$n" -ge 1 ] && ok "C1 late start: $n beat(s) before the 2 s cap" || bad "C1 late start: beats before the cap: '$n'"
[ "$(grep -c '^run 901: pre-run heartbeat stopped after 2s$' "$T/log")" = 1 ] \
  && ok "C1 one 'stopped after 2s' line" || bad "C1 stop lines: '$s'"

# C2: the cap still stops the beat on the real clock.
lrh_start 902 "" 2
wait_for 10 has_stop 902
n=$(beats 902)
# The loop exits right after its stop line: once it is gone no beat can follow.
wait_for 10 loop_gone
s=$(stops 902)
[ "$n" -ge 1 ] && [ "$n" -le 2 ] && ok "C2 cap: $n beat(s)" || bad "C2 cap: beats '$n' (want 1..2)"
[ "$s" = 1 ] && ok "C2 one stop line" || bad "C2 stop lines: '$s'"
[ "$(beats 902)" = "$n" ] && ok "C2 no beat after the stop" || bad "C2 beat after the stop: '$(beats 902)' vs '$n'"
lrh_stop

# C3: the run-time form (no max) never stops on the clock.
# 3 beats is past the 2 s a capped loop would allow.
lrh_start 903 "" ""
wait_for 15 has_beats 903 3
lrh_stop
n=$(beats 903); s=$(stops 903)
[ "$n" -ge 3 ] && [ "$s" = 0 ] && ok "C3 no cap: $n beats, no stop line" || bad "C3 no cap: beats '$n', stop lines '$s'"

# C4: an invalid max is treated as empty.
for c in "904 0" "905 abc"; do
  set -- $c
  lrh_start "$1" "" "$2"
  wait_for 15 has_beats "$1" 3
  lrh_stop
  n=$(beats "$1"); s=$(stops "$1")
  [ "$n" -ge 3 ] && [ "$s" = 0 ] && ok "C4 max '$2': $n beats, no stop line" || bad "C4 max '$2': beats '$n', stop lines '$s'"
done

# C5: the fallback when EPOCHREALTIME is not there (bash < 5).
if declare -F _lrh_now_us >/dev/null; then
  r=$( unset EPOCHREALTIME; _lrh_now_us; echo "$_LRH_NOW_US" )
  now=$(date +%s)
  if [[ $r =~ ^[0-9]{16,}$ ]] && [ $(( now * 1000000 - r )) -le 1000000 ] && [ $(( r - now * 1000000 )) -le 1000000 ]; then
    ok "C5 fallback: $r"
  else
    bad "C5 fallback: '$r' vs date $now"
  fi
  _lrh_now_us
  [[ $_LRH_NOW_US =~ ^[0-9]{16,}$ ]] && ok "C5 EPOCHREALTIME: $_LRH_NOW_US" || bad "C5 EPOCHREALTIME: '$_LRH_NOW_US'"
else
  bad "C5 _lrh_now_us is not defined"
fi

echo "lane-run-heartbeat-clock: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
