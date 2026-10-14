#!/bin/bash
# tests/mc-step-timeout-calls.bh-6603-test.sh — BH-6603: a step-timeout kill
# reports the killed worker's call trace, as the deadline kill does (BH-6462).
# mc_fanin_outcome in "$DIR/bin/lib/fanin.sh" puts ` | calls: <summary>` at the
# end of the STEP_TIMEOUT line and lane alert, and `calls` in the Sentry extra.
#
#   C1  the real path: mc_worker_bounded kills a stalled dep-gate step, then
#       mc_fanin_outcome reports the trace the worker wrote
#   C2  two steps in the trace: first-seen order, line and extra agree
#   C3  nothing left under worker-deadline/ after C1 and C2
#   C4  no .calls file: the segment is `calls: none`, extra.calls is none
#   C5  the dedupe arm: no line, no alert, no Sentry, the .calls file removed
#   C6  a deadline mark: WORKER_DEADLINE with the segment, no STEP_TIMEOUT
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-step-timeout-calls.bh-6603-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
hd() { printf '%02d%038d' "$1" 0; }
UL="$T/u"; mkdir -p "$UL/hh/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$UL" > "$UL/hh/bin/lane-alert.sh"; chmod +x "$UL/hh/bin/lane-alert.sh"
: > "$UL/alerts"
ROW() { printf '%s\tx\t%s\tb\tfalse\tCLEAN' "$1" "$(hd "$1")"; }

# env <case> <has-rc> — the stubs every case shares, in the caller's subshell.
env_stubs() {
  SLUG=example-org/demo MC_STATE_DIR="$UL/state" MC_TICK_ID=t6603 MC_LOG="$UL/$1/mclog" MC_FANIN_T0=0 HARNESS="$UL/hh"
  : > "$MC_LOG"
  mc_handoff_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
  eval "mc_log() { printf '%s\n' \"\$*\" >> '$UL/$1/log'; }"
  eval "mc_attempt_has() { return $2; }"
  mc_attempt_put() { :; }; mc_row_field() { echo READY; }
  eval "sentry_report() { printf '%s\n' \"\$@\" > '$UL/$1/sentry'; }"
}

# ============================================================================
# C1 — the real path: the bounded worker, the step watchdog, the outcome.
# ============================================================================
mkdir -p "$UL/c1"; S0=$SECONDS
( . "$DIR/bin/lib/fanin.sh"
  env_stubs c1 1
  MC_WORKER_DEADLINE_S=30 MC_STEP_TIMEOUT_S=2 MC_STEP_POLL_S=1
  pr_worker() { mc_step dep-gate; printf 'dep-gate\tgh\tGET repos/o/r/pulls/9\t1500\t200\n' >> "$HARNESS_CALL_TRACE_FILE"; sleep 30; }   # determinism: ok the stub worker IS the stall the step timeout kills
  mc_worker_bounded "$(ROW 81)"; echo "rc=$?"
  m=$(_mc_deadline_mark "example-org/demo#81")
  [ -e "$m.calls" ] && echo "calls-before=y" || echo "calls-before=n"
  echo "word=$(mc_fanin_outcome 0 "$(ROW 81)")"
  [ -e "$m.calls" ] && echo "calls-after=y" || echo "calls-after=n"
) > "$UL/c1/out" 2>&1
C1_S=$((SECONDS - S0))
SUM1='dep-gate gh=1/1.5s; slowest: gh GET repos/o/r/pulls/9 1.5s (dep-gate)'
[ "$C1_S" -lt 30 ] && ok || bad "C1 the run ends in under 30 s (took ${C1_S}s)"
grep -qx 'calls-before=y' "$UL/c1/out" && ok || bad "C1 <mark>.calls is on disk before the outcome ($(cat "$UL/c1/out"))"
grep -qx 'word=killed:step-timeout' "$UL/c1/out" && ok || bad "C1 the outcome is exactly killed:step-timeout ($(cat "$UL/c1/out"))"
STL=$(grep 'STEP_TIMEOUT' "$UL/c1/log" 2>/dev/null)
[ "$(grep -c 'example-org/demo#81 STEP_TIMEOUT' <<<"$STL")" = 1 ] && ok || bad "C1 one STEP_TIMEOUT line for #81 ($(cat "$UL/c1/log" 2>/dev/null))"
[[ "$STL" == *" | calls: $SUM1" ]] && ok || bad "C1 the STEP_TIMEOUT line ends with the calls segment ($STL)"
AL=$(grep -F 'STEP_TIMEOUT example-org/demo#81' "$UL/alerts")
[ "$(grep -c . <<<"$AL")" = 1 ] && [[ "$AL" == *" | calls: $SUM1" ]] && ok || bad "C1 one lane alert with the calls segment ($(cat "$UL/alerts"))"
[ "$(sed -n 1,3p "$UL/c1/sentry" 2>/dev/null | tr '\n' ' ')" = 'warning merge-conductor conductor-step-timeout ' ] && ok || bad "C1 the Sentry fingerprint args are unchanged ($(sed -n 1,3p "$UL/c1/sentry" 2>/dev/null))"
[ "$(sed -n 5p "$UL/c1/sentry" 2>/dev/null | jq -r '.calls' 2>/dev/null)" = "$SUM1" ] && ok || bad "C1 extra.calls is the summary ($(sed -n 5p "$UL/c1/sentry" 2>/dev/null))"
[ "$(sed -n 5p "$UL/c1/sentry" 2>/dev/null | jq -r '.tags.step' 2>/dev/null)" = dep-gate ] && ok || bad "C1 the step tag is unchanged ($(sed -n 5p "$UL/c1/sentry" 2>/dev/null))"

# hand <case> <pr> <kind> <calls content or -> <has-rc> — a hand-written
# 7-field mark (the shape mc_worker_bounded writes), then the outcome.
hand() { local c="$1" n="$2" kind="$3" cl="$4" h="$5"
  mkdir -p "$UL/$c" "$UL/state/worker-deadline"
  ( . "$DIR/bin/lib/fanin.sh"
    env_stubs "$c" "$h"
    m=$(_mc_deadline_mark "example-org/demo#$n")
    printf '30\tdep-gate\tdep-gate\t3\tstart=0s\t%s\t2\n' "$kind" > "$m"
    [ "$cl" = - ] || printf '%s' "$cl" > "$m.calls"
    echo "word=$(mc_fanin_outcome 0 "$(ROW "$n")")"
    [ -e "$m.calls" ] && echo "calls-after=y" || echo "calls-after=n"
  ) > "$UL/$c/out" 2>&1; }

# ============================================================================
# C2 — two steps.
# ============================================================================
hand c2 82 step-timeout $'start\tjobs\tGET /api/settings\t200\t200\ndep-gate\tgh\tGET repos/o/r/pulls/9\t2500\t200\n' 1
SUM2='start jobs=1/0.2s; dep-gate gh=1/2.5s; slowest: gh GET repos/o/r/pulls/9 2.5s (dep-gate)'
STL=$(grep 'example-org/demo#82 STEP_TIMEOUT' "$UL/c2/log" 2>/dev/null)
[[ "$STL" == *" | calls: $SUM2" ]] && ok || bad "C2 the line names both steps in first-seen order ($STL)"
[ "$(sed -n 5p "$UL/c2/sentry" 2>/dev/null | jq -r '.calls' 2>/dev/null)" = "$SUM2" ] && ok || bad "C2 extra.calls is the same summary ($(sed -n 5p "$UL/c2/sentry" 2>/dev/null))"

# ============================================================================
# C3 — the file lifetime after C1 and C2.
# ============================================================================
grep -qx 'calls-after=n' "$UL/c1/out" && grep -qx 'calls-after=n' "$UL/c2/out" && ok || bad "C3 the outcome removes <mark>.calls ($(cat "$UL/c1/out" "$UL/c2/out"))"
LEFT=$(ls -A "$UL/state/worker-deadline" 2>/dev/null)
[ -z "$LEFT" ] && ok || bad "C3 nothing left under worker-deadline/ ($LEFT)"

# ============================================================================
# C4 — no trace file.
# ============================================================================
hand c4 84 step-timeout - 1
STL=$(grep 'example-org/demo#84 STEP_TIMEOUT' "$UL/c4/log" 2>/dev/null)
[[ "$STL" == *" | calls: none" ]] && ok || bad "C4 no .calls: the line ends | calls: none ($STL)"
[ "$(sed -n 5p "$UL/c4/sentry" 2>/dev/null | jq -r '.calls' 2>/dev/null)" = none ] && ok || bad "C4 extra.calls is none ($(sed -n 5p "$UL/c4/sentry" 2>/dev/null))"

# ============================================================================
# C5 — the dedupe arm: the attempt is already recorded.
# ============================================================================
: > "$UL/alerts"
hand c5 85 step-timeout $'dep-gate\tgh\tGET repos/o/r/pulls/9\t1500\t200\n' 0
grep -qx 'word=killed:step-timeout' "$UL/c5/out" && ok || bad "C5 the outcome is killed:step-timeout ($(cat "$UL/c5/out"))"
[ ! -s "$UL/c5/log" ] && [ ! -s "$UL/alerts" ] && [ ! -e "$UL/c5/sentry" ] && ok || bad "C5 no line, no alert, no Sentry ($(cat "$UL/c5/log" "$UL/alerts" 2>/dev/null))"
grep -qx 'calls-after=n' "$UL/c5/out" && ok || bad "C5 the .calls file is still removed ($(cat "$UL/c5/out"))"

# ============================================================================
# C6 — the deadline arm is untouched.
# ============================================================================
hand c6 86 deadline $'dep-gate\tgh\tGET repos/o/r/pulls/9\t1500\t200\n' 1
grep -qx 'word=killed:deadline' "$UL/c6/out" && ok || bad "C6 the outcome is killed:deadline ($(cat "$UL/c6/out"))"
DL=$(grep 'example-org/demo#86 WORKER_DEADLINE' "$UL/c6/log" 2>/dev/null)
[[ "$DL" == *" | calls: $SUM1" ]] && ok || bad "C6 the WORKER_DEADLINE line ends with the calls segment ($DL)"
! grep -q STEP_TIMEOUT "$UL/c6/log" 2>/dev/null && ok || bad "C6 no STEP_TIMEOUT line ($(cat "$UL/c6/log"))"

echo "mc-step-timeout-calls.bh-6603: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
