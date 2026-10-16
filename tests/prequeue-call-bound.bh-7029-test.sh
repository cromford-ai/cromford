#!/bin/bash
# tests/prequeue-call-bound.bh-7029-test.sh — BH-7029: each call inside the
# merge conductor's prequeue step is named, timed and bounded. pq_call
# (bin/lib/mc-prequeue.d/call-bound.sh) logs one PREQUEUE_CALL line per call;
# pq_gate (bin/lib/mc-prequeue.sh) runs under MC_PREQUEUE_CALL_BUDGET_S and
# answers hold, with the call named, when a read runs past it; a step-timeout
# kill names the call in flight (mc_worker_bounded / mc_fanin_outcome in
# bin/lib/fanin.sh).
#
#   R1  the real path: mc_worker_bounded + pq_gate, a main-tip read that stalls:
#       hold, PREQUEUE_CALL_TIMEOUT call=main-tip, no step-timeout kill
#   B1  three calls, three PREQUEUE_CALL lines with name, seconds and rc
#   B2  a read's own child is killed when the budget passes
#   B3  a child of the shell started before the call survives the kill
#   B4  a setsid child started inside the call survives the kill
#   B5  no time left in the worker: hold at once, no call made
#   G1  a read that ends inside the budget: the verdict stands
#   G2  the hold path: no alert, no Sentry, no status; the next PR proceeds
#   G3  a write call past the budget is not killed; the gate then holds
#   G4  knob 0: no timer, a slow read is not touched
#   G5  every return path leaves no timer process and no .over file
#   D1  pq_resolve on a miss: resolve/wf-probe, resolve/adopt, resolve/dispatch
#   D2  a pending run read killed by the budget: entry stays pending, no alert
#   D3  the budget passes in resolve/veto: nothing dispatched, nothing recorded
#   M1  the step watchdog kill names the call: line, extra and tag
#   M2  a nested call is named by its path (resolve/merge-test)
#   M3  a 7-field mark (no call in flight, or an older writer): no call tag,
#       no call segment in the line, extra.call none
#   M4  <mark>.call is removed after the outcome and after a normal return
#   M5  a kill with no call in flight keeps the 7-field mark and line
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-call-bound.bh-7029-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
[ -f "$DIR/bin/lib/mc-prequeue.d/call-bound.sh" ] || { echo "FAIL: bin/lib/mc-prequeue.d/call-bound.sh does not exist"; exit 1; }
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping";    exit 0; }
command -v ps    >/dev/null || { echo "ps missing — skipping";    exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
[ -r /proc/uptime ] || { echo "no /proc/uptime — skipping"; exit 0; }
hd() { printf '%02d%038d' "$1" 0; }
MAIN=$(printf 'ab%038d' 0)
UL="$T/u"; mkdir -p "$UL/hh/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$UL" > "$UL/hh/bin/lane-alert.sh"; chmod +x "$UL/hh/bin/lane-alert.sh"
: > "$UL/alerts"
ROW() { printf '%s\tx\t%s\tb\tfalse\tCLEAN' "$1" "$(hd "$1")"; }

# load <case> — the real libs and the stubs every case shares, in the caller's
# subshell. GitHub is gh_rest; STALL_<what> makes one read sleep that long, and
# a read whose sleep is killed answers 75 as the real gh_rest does.
load() {
  MC_H="$UL/hh"
  . "$DIR/bin/lib/fanin.sh"; . "$DIR/bin/lib/mc/queue.sh"; . "$DIR/bin/lib/mc-prequeue.sh"
  C="$UL/$1"; mkdir -p "$C/tmp"
  SLUG=example-org/demo MC_STATE_DIR="$C/state" MC_TICK_ID=t7029 MC_TICK_DIR="$C/tick" MC_LOG="$C/mclog" MC_FANIN_T0=0
  MC_H="$UL/hh" HARNESS="$UL/hh" TMPDIR="$C/tmp" KEY="example-org/demo#1"
  : > "$MC_LOG"
  mc_handoff_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
  mc_safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
  mc_log() { printf '%s\n' "$*" >> "$C/log"; }
  mc_attempt_has() { return 1; }; mc_attempt_put() { :; }; mc_row_field() { echo READY; }
  mc_use_token() { :; }
  sentry_report() { printf '%s\n' "$@" > "$C/sentry"; }
  pq_status_gate() { printf '%s\n' "$*" >> "$C/status"; }
  pq_restamp() { :; }
  pq_impact_reuse() { _pq_ir=none; }
  gh() { printf '%s\n' "$*" >> "$C/gh"; }
  gh_rest() {
    printf '%s\n' "$2" >> "$C/reads"
    case "$2" in
      */commits/*) [ -n "${STALL_TIP:-}" ] && { sleep "$STALL_TIP" || return 75; }   # determinism: ok the stub read IS the stall under test
                   printf '{"sha":"%s"}' "$MAIN" ;;
      */actions/workflows/prequeue-gate.yml) printf '{}' ;;
      */runs\?*) [ -n "${STALL_RUNS:-}" ] && { sleep "$STALL_RUNS" || return 75; }   # determinism: ok the stub read IS the stall under test
                 printf '{"workflow_runs":[]}' ;;
      *) return 44 ;;
    esac
  }
}
# kids — the commands still running as children of this shell (ps excluded).
kids() { ps -o comm= --ppid "$BASHPID" > "$C/kids.$1" 2>/dev/null; grep -vx ps "$C/kids.$1" | tr '\n' ' '; }

# ============================================================================
# R1 — the real path (the reproduction).
# ============================================================================
mkdir -p "$UL/r1"
( load r1
  MC_WORKER_DEADLINE_S=30 MC_STEP_TIMEOUT_S=6 MC_STEP_POLL_S=1 MC_PREQUEUE_CALL_BUDGET_S=2 STALL_TIP=30
  pr_worker() { mc_step prequeue; pq_gate "$SLUG" 71 u "$(hd 71)" main >/dev/null; echo "verdict=$PQ_VERDICT why=$PQ_WHY" > "$C/verdict"; }
  mc_worker_bounded "$(ROW 71)"; echo "rc=$?"
  m=$(_mc_deadline_mark "example-org/demo#71")
  [ -e "$m" ] && echo "mark=y" || echo "mark=n"
  echo "word=$(mc_fanin_outcome 0 "$(ROW 71)")"
) > "$UL/r1/out" 2>&1
grep -q '^verdict=hold ' "$UL/r1/verdict" 2>/dev/null && ok || bad "R1 pq_gate answers hold ($(cat "$UL/r1/verdict" 2>/dev/null) / $(cat "$UL/r1/out"))"
grep -q 'why=prequeue call main-tip ran past 2s' "$UL/r1/verdict" 2>/dev/null && ok || bad "R1 PQ_WHY names the call and the budget ($(cat "$UL/r1/verdict" 2>/dev/null))"
grep -q "^example-org/demo#71 PREQUEUE_CALL_TIMEOUT call=main-tip budget=2s head=$(hd 71 | cut -c1-8)\$" "$UL/r1/log" 2>/dev/null && ok || bad "R1 one PREQUEUE_CALL_TIMEOUT line names main-tip ($(cat "$UL/r1/log" 2>/dev/null))"
grep -qx 'rc=0' "$UL/r1/out" && grep -qx 'mark=n' "$UL/r1/out" && ok || bad "R1 the worker returns rc 0 and leaves no mark ($(cat "$UL/r1/out"))"
! grep -q 'word=killed:' "$UL/r1/out" && ! grep -q STEP_TIMEOUT "$UL/r1/log" 2>/dev/null && ok || bad "R1 the outcome is not a kill and no STEP_TIMEOUT line ($(cat "$UL/r1/out"))"

# ============================================================================
# B1 — the timing lines.
# ============================================================================
mkdir -p "$UL/b1"
( load b1
  pq_call one sleep 0.2; echo "rc1=$?"     # determinism: ok a measured call needs a known floor
  pq_call two true; echo "rc2=$?"
  pq_call -w three bash -c 'exit 3'; echo "rc3=$?"
) > "$UL/b1/out" 2>&1
L1=$(grep 'PREQUEUE_CALL call=one ' "$UL/b1/log" 2>/dev/null)
[[ "$L1" =~ ^example-org/demo#1\ PREQUEUE_CALL\ call=one\ took=([0-9]+\.[0-9])s\ rc=0$ ]] && awk -v t="${BASH_REMATCH[1]}" 'BEGIN { exit !(t >= 0.2) }' \
  && ok || bad "B1 call one: took >= 0.2 s, rc 0 ($(cat "$UL/b1/log" 2>/dev/null))"
grep -Eq '^example-org/demo#1 PREQUEUE_CALL call=two took=[0-9]+\.[0-9]s rc=0$' "$UL/b1/log" 2>/dev/null && ok || bad "B1 call two line ($(cat "$UL/b1/log" 2>/dev/null))"
grep -Eq '^example-org/demo#1 PREQUEUE_CALL call=three took=[0-9]+\.[0-9]s rc=3$' "$UL/b1/log" 2>/dev/null && grep -qx 'rc3=3' "$UL/b1/out" \
  && ok || bad "B1 call three: rc 3 logged and returned ($(cat "$UL/b1/log" "$UL/b1/out" 2>/dev/null))"
[ "$(grep -c PREQUEUE_CALL "$UL/b1/log" 2>/dev/null)" = 3 ] && ok || bad "B1 exactly three lines ($(cat "$UL/b1/log" 2>/dev/null))"

# ============================================================================
# B2, B3, B4 — the kill filter, one budget each.
# ============================================================================
mkdir -p "$UL/b2"
( load b2
  sleep 30 & pre=$!                       # determinism: ok B3 a child that predates the call
  sleep 0.3                               # determinism: ok B3 the pre-existing child must be older than the call
  in_call() { setsid sleep 30 & echo $! > "$C/setsid.pid"; sleep 30 || return 75; touch "$C/ran-to-end"; }   # determinism: ok B4 the stalled read the budget kills
  _pq_budget_start 2
  pq_call slow in_call; echo "rc=$?"
  pq_over && echo "over=y" || echo "over=n"
  _pq_budget_stop
  kill -0 "$pre" 2>/dev/null && echo "pre=alive" || echo "pre=dead"
  sp=$(cat "$C/setsid.pid" 2>/dev/null)
  [ -n "$sp" ] && kill -0 "$sp" 2>/dev/null && echo "setsid=alive" || echo "setsid=dead"
  kill "$pre" "$sp" 2>/dev/null; wait "$pre" 2>/dev/null
) > "$UL/b2/out" 2>&1
grep -Eq '^rc=[1-9][0-9]*$' "$UL/b2/out" && [ ! -e "$UL/b2/ran-to-end" ] && ok || bad "B2 the read is killed and pq_call returns non-zero ($(cat "$UL/b2/out"))"
grep -qx 'over=y' "$UL/b2/out" && ok || bad "B2 pq_over is true after the budget ($(cat "$UL/b2/out"))"
grep -qx 'pre=alive' "$UL/b2/out" && ok || bad "B3 the child that predates the call survives ($(cat "$UL/b2/out"))"
grep -qx 'setsid=alive' "$UL/b2/out" && ok || bad "B4 the setsid child survives ($(cat "$UL/b2/out"))"

# ============================================================================
# B5 — no time left in the worker.
# ============================================================================
mkdir -p "$UL/b5"
( load b5
  MC_WORKER_DEADLINE_AT=$(( $(date +%s) + 10 ))
  echo "word=$(pq_gate "$SLUG" 75 u "$(hd 75)" main)"
  pq_gate "$SLUG" 75 u "$(hd 75)" main >/dev/null; echo "why=$PQ_WHY"
) > "$UL/b5/out" 2>&1
grep -qx 'word=hold' "$UL/b5/out" && grep -q '^why=no prequeue time left in this worker' "$UL/b5/out" && ok || bad "B5 hold at once ($(cat "$UL/b5/out"))"
[ ! -s "$UL/b5/reads" ] && [ ! -s "$UL/b5/status" ] && ok || bad "B5 no read, no status ($(cat "$UL/b5/reads" "$UL/b5/status" 2>/dev/null))"

# ============================================================================
# G1 — a read inside the budget; G4 — knob 0.
# ============================================================================
for c in g1 g4; do mkdir -p "$UL/$c"; done
seed_green() { mkdir -p "$MC_STATE_DIR/prequeue"; printf 'green 1 9 -\n' > "$(pq_key "$SLUG" "$1" "$(hd "$1")" "$MAIN")"; }
( load g1; MC_PREQUEUE_CALL_BUDGET_S=3 STALL_TIP=1; seed_green 76
  pq_gate "$SLUG" 76 u "$(hd 76)" main >/dev/null; echo "verdict=$PQ_VERDICT"
) > "$UL/g1/out" 2>&1
grep -qx 'verdict=proceed' "$UL/g1/out" && grep -q "$(hd 76)" "$UL/g1/status" 2>/dev/null \
  && ! grep -q PREQUEUE_CALL_TIMEOUT "$UL/g1/log" 2>/dev/null && ok || bad "G1 the verdict stands ($(cat "$UL/g1/out" "$UL/g1/log" 2>/dev/null))"
( load g4; MC_PREQUEUE_CALL_BUDGET_S=0 STALL_TIP=2; seed_green 79
  pq_gate "$SLUG" 79 u "$(hd 79)" main >/dev/null; echo "verdict=$PQ_VERDICT"
) > "$UL/g4/out" 2>&1
grep -qx 'verdict=proceed' "$UL/g4/out" && ! grep -q PREQUEUE_CALL_TIMEOUT "$UL/g4/log" 2>/dev/null \
  && grep -Eq 'PREQUEUE_CALL call=main-tip took=[2-9]\.[0-9]s rc=0$' "$UL/g4/log" 2>/dev/null && ok || bad "G4 knob 0: the read runs to its end ($(cat "$UL/g4/out" "$UL/g4/log" 2>/dev/null))"

# ============================================================================
# G2 — the hold path, then the next PR in the same shell.
# ============================================================================
mkdir -p "$UL/g2"; : > "$UL/alerts"
( load g2; MC_PREQUEUE_CALL_BUDGET_S=1 STALL_TIP=30; seed_green 78
  pq_gate "$SLUG" 77 u "$(hd 77)" main >/dev/null; echo "first=$PQ_VERDICT"
  STALL_TIP=""
  pq_gate "$SLUG" 78 u "$(hd 78)" main >/dev/null; echo "second=$PQ_VERDICT"
) > "$UL/g2/out" 2>&1
grep -qx 'first=hold' "$UL/g2/out" && grep -qx 'second=proceed' "$UL/g2/out" && ok || bad "G2 hold, then the next PR proceeds ($(cat "$UL/g2/out"))"
[ ! -s "$UL/alerts" ] && [ ! -e "$UL/g2/sentry" ] && ok || bad "G2 no alert and no Sentry event ($(cat "$UL/alerts" "$UL/g2/sentry" 2>/dev/null))"
[ "$(grep -c . "$UL/g2/status" 2>/dev/null)" = 1 ] && grep -q "$(hd 78)" "$UL/g2/status" && ok || bad "G2 only the second PR publishes a status ($(cat "$UL/g2/status" 2>/dev/null))"

# ============================================================================
# G3 — a write call past the budget runs to its end.
# ============================================================================
mkdir -p "$UL/g3"
( load g3; MC_PREQUEUE_CALL_BUDGET_S=1
  pq_restamp() { sleep 3; touch "$C/restamp-done"; }   # determinism: ok the write runs past the budget on purpose
  pq_gate "$SLUG" 80 u "$(hd 80)" main >/dev/null; echo "verdict=$PQ_VERDICT"
) > "$UL/g3/out" 2>&1
[ -e "$UL/g3/restamp-done" ] && ok || bad "G3 the write call was not killed"
grep -qx 'verdict=hold' "$UL/g3/out" && grep -q 'PREQUEUE_CALL_TIMEOUT call=restamp budget=1s' "$UL/g3/log" 2>/dev/null && ok || bad "G3 the gate holds and names restamp ($(cat "$UL/g3/out" "$UL/g3/log" 2>/dev/null))"

# ============================================================================
# G5 — every return path stops the timer and removes its files.
# ============================================================================
mkdir -p "$UL/g5"
( load g5; MC_PREQUEUE_CALL_BUDGET_S=2
  mkdir -p "$MC_STATE_DIR/prequeue"
  seed_green 81; printf 'red 1 9 - suite-a\n' > "$(pq_key "$SLUG" 82 "$(hd 82)" "$MAIN")"
  pq_resolve() { echo "${RESOLVE_WORD:-proceed}"; }
  try() { pq_gate "$SLUG" "$1" u "$(hd "$1")" main >/dev/null; echo "$2 verdict=$PQ_VERDICT kids=[$(kids "$2")] files=[$(ls -A "$TMPDIR")]"; }
  try 81 proceed
  try 82 red
  RESOLVE_WORD=rebase try 83 rebase
  RESOLVE_WORD=defer try 84 defer
  RESOLVE_WORD=hold try 85 resolve-hold
  gh_rest() { return 75; }; try 86 tip-unreadable
  MC_PREQUEUE_GATE=0 try 87 gate-off
  gh_rest() { sleep 30 || return 75; }; try 88 over-budget   # determinism: ok the stalled read the budget kills
) > "$UL/g5/out" 2>&1
for w in proceed:proceed red:red rebase:rebase defer:defer resolve-hold:hold tip-unreadable:hold gate-off:proceed over-budget:hold; do
  grep -qx "${w%%:*} verdict=${w#*:} kids=\[\] files=\[\]" "$UL/g5/out" && ok || bad "G5 path ${w%%:*}: answer ${w#*:}, no timer left, no file left ($(grep "^${w%%:*} " "$UL/g5/out"))"
done

# ============================================================================
# D1, D2, D3 — the resolver's calls.
# ============================================================================
mkdir -p "$UL/d1" "$UL/d2" "$UL/d3"
( load d1
  pq_gate "$SLUG" 91 u "$(hd 91)" main >/dev/null; echo "verdict=$PQ_VERDICT"
) > "$UL/d1/out" 2>&1
for n in main-tip resolve/wf-probe resolve/adopt resolve/veto resolve/dispatch resolve status; do
  grep -Eq "^example-org/demo#91 PREQUEUE_CALL call=$n took=[0-9]+\.[0-9]s rc=[0-9]+\$" "$UL/d1/log" 2>/dev/null && ok || bad "D1 a timing line for $n ($(grep PREQUEUE_CALL "$UL/d1/log" 2>/dev/null))"
done
grep -qx 'verdict=hold' "$UL/d1/out" && grep -q 'workflow run prequeue-gate.yml' "$UL/d1/gh" 2>/dev/null && ok || bad "D1 a miss dispatches and holds ($(cat "$UL/d1/out"))"

: > "$UL/alerts"
( load d2; MC_PREQUEUE_CALL_BUDGET_S=2 STALL_RUNS=30
  mkdir -p "$MC_STATE_DIR/prequeue"; p=$(pq_key "$SLUG" 92 "$(hd 92)" "$MAIN")
  printf 'pending %s - \n' "$(( $(date +%s) - 3000 ))" > "$p"
  pq_gate "$SLUG" 92 u "$(hd 92)" main >/dev/null; echo "verdict=$PQ_VERDICT"
  echo "entry=$(cut -d' ' -f1 "$p")"
) > "$UL/d2/out" 2>&1
grep -qx 'verdict=hold' "$UL/d2/out" && grep -qx 'entry=pending' "$UL/d2/out" && ok || bad "D2 the killed run read holds and the entry stays pending ($(cat "$UL/d2/out"))"
[ ! -s "$UL/alerts" ] && ! grep -q could-not-run "$UL/d2/log" 2>/dev/null && ok || bad "D2 no could-not-run, no alert ($(cat "$UL/alerts" "$UL/d2/log" 2>/dev/null))"
grep -q 'PREQUEUE_CALL_TIMEOUT call=resolve/settle budget=2s' "$UL/d2/log" 2>/dev/null && ok || bad "D2 the timeout names resolve/settle ($(cat "$UL/d2/log" 2>/dev/null))"

( load d3; MC_PREQUEUE_CALL_BUDGET_S=1
  pq_dispatch_veto() { sleep 30; return 1; }   # determinism: ok the stalled veto read the budget kills
  pq_gate "$SLUG" 93 u "$(hd 93)" main >/dev/null; echo "verdict=$PQ_VERDICT"
  ls "$MC_STATE_DIR/prequeue" 2>/dev/null | sed 's/^/entry=/'
) > "$UL/d3/out" 2>&1
grep -qx 'verdict=hold' "$UL/d3/out" && [ ! -s "$UL/d3/gh" ] && ok || bad "D3 nothing dispatched ($(cat "$UL/d3/out" "$UL/d3/gh" 2>/dev/null))"
! grep -q '^entry=' "$UL/d3/out" && ! grep -q 'cache-unwritable\|could-not-run' "$UL/d3/log" "$UL/alerts" 2>/dev/null && ok || bad "D3 no cache entry, no could-not-run ($(cat "$UL/d3/out" "$UL/d3/log"))"
grep -q 'PREQUEUE_CALL_TIMEOUT call=resolve/veto budget=1s' "$UL/d3/log" 2>/dev/null && ok || bad "D3 the timeout names resolve/veto ($(cat "$UL/d3/log" 2>/dev/null))"

# ============================================================================
# M1, M2, M4 — the step watchdog names the call.
# ============================================================================
worker_case() { local c="$1" n="$2"; shift 2
  mkdir -p "$UL/$c"
  ( load "$c"
    MC_WORKER_DEADLINE_S=30 MC_STEP_TIMEOUT_S=3 MC_STEP_POLL_S=1 MC_PREQUEUE_CALL_BUDGET_S=0
    eval "pr_worker() { mc_step prequeue; $*; }"
    mc_worker_bounded "$(ROW "$n")"; echo "rc=$?"
    m=$(_mc_deadline_mark "example-org/demo#$n")
    [ -e "$m.call" ] && echo "call-before=y" || echo "call-before=n"
    [ -e "$m" ] && echo "fields=$(awk -F '\t' '{ print NF; exit }' "$m")"
    echo "word=$(mc_fanin_outcome 0 "$(ROW "$n")")"
    [ -e "$m.call" ] && echo "call-after=y" || echo "call-after=n"
  ) > "$UL/$c/out" 2>&1; }
worker_case m1 101 'pq_call -w dispatch sleep 30'   # determinism: ok the stalled write the step watchdog kills
grep -qx 'word=killed:step-timeout' "$UL/m1/out" && ok || bad "M1 the outcome is killed:step-timeout ($(cat "$UL/m1/out"))"
[ "$(sed -n 6p "$UL/m1/sentry" 2>/dev/null | jq -r '.call' 2>/dev/null)" = dispatch ] && ok || bad "M1 the Sentry tags carry call=dispatch ($(cat "$UL/m1/sentry" 2>/dev/null))"
sed -n 5p "$UL/m1/sentry" 2>/dev/null | jq -e '.call == "dispatch" and (.call_s | test("^[0-9]+$"))' >/dev/null 2>&1 && ok || bad "M1 extra has call and call_s ($(sed -n 5p "$UL/m1/sentry" 2>/dev/null))"
STL=$(grep 'example-org/demo#101 STEP_TIMEOUT' "$UL/m1/log" 2>/dev/null)
[[ "$STL" == *"| call: dispatch ("*"s) | calls: "* ]] && ok || bad "M1 the STEP_TIMEOUT line names the call before the calls segment ($STL)"
[ "$(sed -n 6p "$UL/m1/sentry" 2>/dev/null | jq -r '.step' 2>/dev/null)" = prequeue ] && ok || bad "M1 the step tag is unchanged ($(sed -n 6p "$UL/m1/sentry" 2>/dev/null))"

worker_case m2 102 'pq_call resolve pq_call merge-test sleep 30'   # determinism: ok the stalled nested read the step watchdog kills
[ "$(sed -n 6p "$UL/m2/sentry" 2>/dev/null | jq -r '.call' 2>/dev/null)" = resolve/merge-test ] && ok || bad "M2 the tag is the call path ($(cat "$UL/m2/sentry" 2>/dev/null))"

worker_case m4 104 'pq_call wf-probe true'
worker_case m5 105 'sleep 30'   # determinism: ok a stalled step with no prequeue call, the step watchdog kills it
grep -qx 'fields=9' "$UL/m1/out" && grep -qx 'fields=7' "$UL/m5/out" && ok || bad "M5 fields 8-9 only when a call runs ($(cat "$UL/m1/out" "$UL/m5/out"))"
[ "$(sed -n 6p "$UL/m5/sentry" 2>/dev/null | jq -r 'has("call")' 2>/dev/null)" = false ] && ! grep -q '| call:' "$UL/m5/log" && ok || bad "M5 no call tag, no call segment ($(cat "$UL/m5/sentry" "$UL/m5/log" 2>/dev/null))"
grep -qx 'call-before=y' "$UL/m1/out" && grep -qx 'call-after=n' "$UL/m1/out" && ok || bad "M4 <mark>.call stays for the outcome and goes with it ($(cat "$UL/m1/out"))"
grep -qx 'rc=0' "$UL/m4/out" && grep -qx 'call-before=n' "$UL/m4/out" && ok || bad "M4 a normal return removes <mark>.call ($(cat "$UL/m4/out"))"
LEFT=$(ls -A "$UL/m1/state/worker-deadline" "$UL/m4/state/worker-deadline" "$UL/m5/state/worker-deadline" 2>/dev/null | grep -v ':$' | grep .)
[ -z "$LEFT" ] && ok || bad "M4 nothing left under worker-deadline/ ($LEFT)"

# ============================================================================
# M3 — a 7-field mark from an older writer.
# ============================================================================
mkdir -p "$UL/m3"
( load m3
  m=$(_mc_deadline_mark "example-org/demo#103"); mkdir -p "${m%/*}"
  printf '30\tprequeue\tprequeue\t3\tstart=0s\tstep-timeout\t2\n' > "$m"
  echo "word=$(mc_fanin_outcome 0 "$(ROW 103)")"
) > "$UL/m3/out" 2>&1
grep -qx 'word=killed:step-timeout' "$UL/m3/out" && ok || bad "M3 the outcome still reads ($(cat "$UL/m3/out"))"
sed -n 6p "$UL/m3/sentry" 2>/dev/null | jq -e 'has("call") | not' >/dev/null 2>&1 && ok || bad "M3 no call tag ($(sed -n 6p "$UL/m3/sentry" 2>/dev/null))"
STL=$(grep 'example-org/demo#103 STEP_TIMEOUT' "$UL/m3/log" 2>/dev/null)
[[ "$STL" == *"the next tick works it again | calls: "* ]] && [[ "$STL" != *"| call:"* ]] && ok || bad "M3 the line has no call segment ($STL)"
[ "$(sed -n 5p "$UL/m3/sentry" 2>/dev/null | jq -r '.call' 2>/dev/null)" = none ] && ok || bad "M3 extra.call is none ($(sed -n 5p "$UL/m3/sentry" 2>/dev/null))"

echo "prequeue-call-bound.bh-7029: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
