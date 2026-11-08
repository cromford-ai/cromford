#!/bin/bash
# tests/triage-empty-tick.bh-9073-test.sh — BH-9073 (BH-9067.1): the run-triage
# wake gate short-circuit in ts_tick (bin/lib/triage-state.sh,
# _ts_wake_idle_end / _ts_end_zero / _ts_wake_counts). With
# lib.lane-wake-gate.mode_run_triage = on, a tick whose pre-check found
# new=0 chg=0 due=0 (and no other model-set row, no queue work) ends at $0 in
# any TS_MODE but off. Shadow writes a would-end line to
# logs/lane-wake-gate.log (never the project log) and the session runs. Off
# does nothing.
#
# WHAT IS REAL. bin/lib/triage-state.sh and its siblings (triage-state-waste.sh,
# triage-state-unreadable.sh), installed by scratch_install_closure into a
# scratch harness and sourced; ts_tick runs as rt_shards calls it.
# WHAT IS STUBBED. ts_precheck (writes this case's decisions.tsv in the column
# layout ts_precheck writes: key label decision reason hash seed in-scope base
# work, and sets TS_MODE / TS_READY / TS_ROWS_OK), lwg_mode (prints this case's
# mode word), rt_gate_consume, job_update and LANE_TICK (one line each in
# $T/calls). Nothing reaches a network.
#
# Each case runs ts_tick in its own subshell; "ended" = the subshell exited
# before its MARKER line (ts_tick exits 0 on a $0 end, returns 0 otherwise).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/triage-empty-tick.bh-9073-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

H="$T/h"; P=project-3-fixture
mkdir -p "$H/logs" "$H/state" "$H/env"
( cd "$DIR" && scratch_install_closure bin/lib/triage-state.sh "$H" ) >/dev/null \
  || { echo "FAIL: scratch_install_closure bin/lib/triage-state.sh"; exit 1; }
[ ! -e "$H/bin/lib/lane-wake-gate.sh" ] || scratch_rm "$H/bin/lib/lane-wake-gate.sh" || exit 1
LOGF="$H/logs/$P.log"
WAKE_ON='rc=skip :: triage-state: wake gate on, new=0 chg=0 due=0 — no session'
WAKE_SH='triage-state: wake gate shadow, new=0 chg=0 due=0 — would end at $0, the session runs'

# tick <mode|-> <TS_MODE> <TS_READY> <GATE_REASON> [VAR=value ...] — rows come
# from $T/rows (one "<decision>\t<reason>" per line); mode "-" defines no
# lwg_mode at all (the lib-missing case). Writes $T/out, $T/calls, the log.
tick() {
  local m="$1" tsm="$2" tsr="$3" gr="$4"; shift 4
  scratch_rm "$T/calls" || exit 1; scratch_rm "$LOGF" || exit 1; : > "$T/calls"
  scratch_rm "$H/state/triage-state" || exit 1; scratch_rm "$H/logs/lane-wake-gate.log" || exit 1
  (
    export HARNESS="$H"
    PROJECT=$P; STAMP="2026-11-09 11:05:00Z"; LOG="$LOGF"
    GATE_REASON="$gr"; SCOPE_N=full; TICK_SCOPE=""; BOARD_SEC=""; QLINES=""; QDIRS=""; RDIRS=""
    JOB_ID=job-fixture-1; JOB_BEAT=""; PROMPT_TEXT="SOP"
    . "$H/bin/lib/triage-state.sh" || exit 9
    ts_precheck() {
      local d; d=$(_ts_dir); mkdir -p "$d"; : > "$d/decisions.tsv"
      local i=0 dec why
      TS_LLM=""; TS_LLM_KEYS=""; TS_SKIPSET=" "; TS_ENQ="${FX_ENQ:-}"
      while IFS=$'\t' read -r dec why; do
        [ -n "$dec" ] || continue
        i=$((i+1))
        printf 'k%s\tFX-%s\t%s\t%s\th%s\t-\t1\t-\t0\n' "$i" "$i" "$dec" "$why" "$i" >> "$d/decisions.tsv"
        [ "$dec" = llm ] && { TS_LLM="$TS_LLM FX-$i"; TS_LLM_KEYS="$TS_LLM_KEYS k$i"; }
      done < "$T/rows"
      TS_MODE=$tsm; TS_READY=$tsr; TS_ROWS_OK=$tsr; TS_SUMMARY="$i open [reads=0 cap=0 budget=0]"; export TS_ROWS_OK
    }
    [ "$m" = - ] || eval "lwg_mode() { printf '%s\n' '$m'; }"
    rt_gate_consume() { echo rt_gate_consume >> "$T/calls"; }
    job_update()      { echo "job_update $*" >> "$T/calls"; }
    LANE_TICK()       { echo "LANE_TICK $*" >> "$T/calls"; }
    for kv in "$@"; do eval "${kv%%=*}=\"\${kv#*=}\""; done
    ts_tick
    echo MARKER
  ) > "$T/out" 2>&1
}
rows()   { printf '%b' "$*" > "$T/rows"; }
ended()  { grep -q MARKER "$T/out" && echo runs || echo ended; }
ncall()  { local c; c=$(grep -c "^$1" "$T/calls" 2>/dev/null); printf '%s' "${c:-0}"; }
hasln()  { grep -qF -- "$1" "$LOGF" 2>/dev/null && echo yes || echo no; }

# The rows of an idle tick: two unchanged tickets, one buildable-owned.
IDLE='skip\tunchanged:defer\nskip\tunchanged:needs_clarification\nskip\tbuildable-owned:build\n'

# runs <case> — the tick ran on: MARKER, no wake-on line, no end stubs.
runs() {
  eq "$1 the session runs" "$(ended)" runs
  eq "$1 no wake-gate-on line" "$(hasln "$WAKE_ON")" no
  eq "$1 no LANE_TICK skip" "$(ncall 'LANE_TICK skip')" 0
}
# ends <case> — the $0 end: no MARKER, the line, each end stub once.
ends() {
  eq "$1 the tick ended at \$0" "$(ended)" ended
  eq "$1 the wake-gate-on line" "$(hasln "$WAKE_ON")" yes
  eq "$1 rt_gate_consume once" "$(ncall rt_gate_consume)" 1
  eq "$1 job_update once" "$(ncall 'job_update job-fixture-1 stage=done status=done')" 1
  eq "$1 LANE_TICK skip once" "$(ncall 'LANE_TICK skip')" 1
  eq "$1 the line carries the gate reason" "$(grep -c "no session \[gate=$2" "$LOGF")" 1
  eq "$1 the line is written after the stubs ran (exit after the decision)" "$(tail -1 "$T/calls")" "LANE_TICK skip"
}

# ═════ ENDS ($0) ═════════════════════════════════════════════════════════════
rows "$IDLE"; tick on enforce 1 board-changed;  ends E1 board-changed
rows "$IDLE"; tick on enforce 1 event-wake;     ends E2 event-wake
rows "$IDLE"; tick on shadow 1 event-wake;      ends "E3 (TS_MODE shadow)" event-wake
rows "$IDLE"; tick on enforce 1 unknown-project; ends "E4 (enforce, observe-only reason)" unknown-project
rows '';      tick on shadow 1 board-changed;   ends "E1b (no open ticket)" board-changed

# ═════ RUNS ══════════════════════════════════════════════════════════════════
rows "$IDLE"; tick shadow shadow 1 event-wake
runs E5
eq "E5 shadow writes the would-end line once to logs/lane-wake-gate.log" \
  "$(grep -cF -- "triage-state $P: ${WAKE_SH#triage-state: } [gate=event-wake]" "$H/logs/lane-wake-gate.log" 2>/dev/null)" 1
eq "E5 shadow leaves the project log without a wake-gate line" "$(hasln 'wake gate')" no
eq "E5 shadow calls no end stub" "$(grep -c . "$T/calls")" 0

rows "$IDLE"; tick off shadow 1 event-wake
runs E6
eq "E6 off writes no wake-gate line" "$(hasln 'wake gate')" no

rows "${IDLE}llm\tnew\n";         tick on shadow 1 event-wake; runs "E7 (1 new)"
rows "${IDLE}llm\tchanged\n";     tick on shadow 1 event-wake; runs "E8 (1 changed)"
rows "${IDLE}llm\trecheck-due\n"; tick on shadow 1 event-wake; runs "E9 (1 recheck-due)"
rows "${IDLE}llm\tunhashable\n";  tick on shadow 1 event-wake; runs "E10 (1 unhashable)"
rows "${IDLE}llm\trows-unreadable\n"; tick on shadow 1 event-wake; runs "E10b (1 rows-unreadable)"
rows "$IDLE"; tick on shadow 1 event-wake FX_ENQ=$'k9\tFX-9'; runs "E11 (an enqueue candidate)"
rows "$IDLE"; tick on shadow 1 event-wake QLINES='FX-1 queued';   runs "E12 (a queue line)"
rows "$IDLE"; tick on shadow 1 event-wake QDIRS='/fixture/b1';    runs "E12b (a finished build)"
rows "$IDLE"; tick on shadow 1 event-wake RDIRS='/fixture/r1';    runs "E12c (a remote result)"
rows "$IDLE"; tick on shadow 1 event-wake BOARD_SEC='board prs: #12 open';      runs "E13 (a board prs: line)"
rows "$IDLE"; tick on shadow 1 event-wake TICK_SCOPE='UNBLOCKED FX-2 child';     runs "E13b (an UNBLOCKED line)"
rows "$IDLE"; tick on shadow 1 event-wake TICK_SCOPE='STACKABLE FX-3 base=b';    runs "E13c (a STACKABLE line)"
rows "$IDLE"; tick on shadow 1 gate-reoffer TICK_SCOPE='board gate: REOFFER FX-4 "t"'; runs "E13d (a REOFFER line)"
rows "$IDLE"; tick on enforce 1 forced;        runs "E14 (forced)"
rows "$IDLE"; tick on enforce 1 forced-env;    runs "E14b (forced-env)"
rows "$IDLE"; tick on enforce 1 daily-sweep;   runs "E15 (daily-sweep)"
rows "$IDLE"; tick on enforce 1 remote-results-pending; runs "E15b (remote-results-pending)"
rows "$IDLE"; tick on enforce 1 no-gate-state; runs "E15c (no-gate-state)"
rows "$IDLE"; tick on enforce 1 gate-fetch-failed; runs "E15d (gate-fetch-failed)"
rows "$IDLE"; tick on off 0 event-wake;        runs "E16 (TS_MODE off, TS_READY 0)"
rows "$IDLE"; tick on shadow 0 event-wake;     runs "E16b (TS_READY 0)"
rows "$IDLE"; tick - shadow 1 event-wake;      runs "E17 (no lane-wake-gate lib: fail-open)"
eq "E17 no wake-gate line" "$(hasln 'wake gate')" no
rows "$IDLE"; tick ON shadow 1 event-wake;     runs "E18 (mode word ON, case-sensitive)"
rows "$IDLE"; tick enforce shadow 1 event-wake; runs "E18b (mode word enforce)"

# ═════ the existing enforce $0 end is unchanged (the factored _ts_end_zero) ══
rows "$IDLE"; tick off enforce 1 board-changed
eq "X1 enforce, mode off: still ends at \$0" "$(ended)" ended
eq "X1 the old line, byte for byte" "$(grep -c 'rc=skip :: triage-state: 0 changed — 3 open \[reads=0 cap=0 budget=0\]; no model call \[gate=board-changed' "$LOGF")" 1
eq "X1 LANE_TICK skip once" "$(ncall 'LANE_TICK skip')" 1

echo "triage-empty-tick: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
