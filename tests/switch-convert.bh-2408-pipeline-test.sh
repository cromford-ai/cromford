#!/bin/bash
# tests/switch-convert.bh-2408-pipeline-test.sh — BH-2443 (BH-2408.3): the
# build-pipeline kill switches read through lane_switch, so a
# `switch.<name>[.<box>]` settings row decides them before the flag file does.
#
# Eight reads in five files, each driven through the REAL file on the scratch
# harness of tests/lib/switch-convert-fixture.sh:
#   1 bin/lane-checkpoint.sh `disabled`        lane-checkpoints-off   (executable)
#   2 bin/lib/rb/plan.sh CKPT_ON               lane-checkpoints-off   (its block)
#   3 bin/lib/rb/plan.sh SG_SWITCH_RESOLVE     size-gate-enforce-off  (its block)
#   4 bin/main-red-detector.sh                 main-red-detector-off  (executable, trace)
#   5 bin/lane-alert.sh `monitor_off`          monitor-off            (executable, --critical DM)
#   6 bin/lib/preplan-lib.sh preplan_speculative   preplan-speculative-off
#   7 bin/lib/preplan-lib.sh overlap_schedule      overlap-schedule-off
#   8 bin/lib/preplan-lib.sh preplan_skip_small_on preplan-skip-small-off
# For each site k:
#   Rk a row switch.<n>=1 and no file: the site reads switched off;
#   Fk a row switch.<n>=0 plus flags/<n>: the site runs, and logs/lane-gate.log
#      holds one `flags/<n> ignored` line;
#   Lk no rows: the file present is off, absent is running.
# Plus: S1/S2 the size gate's SG_SWITCH_SRC text (legacy literal unchanged, a
# row 0 falls to the env chain); N4 the orchestrator's monitor-off file still
# silences lane-alert under a row 0; NEG a row for another switch, another box,
# or an unreadable value does not switch a site off; FB1 preplan-lib with no
# lane-switch.sh beside it answers the file and ignores rows; Q1 no read asked
# flag_active or wrote a row (the `file` mode pin); C1/O1/X1 the registry.
# Run from anywhere: tests/switch-convert.bh-2408-pipeline-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/switch-convert-fixture.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

export LANE_GATE_NOW=1758300000
# Every case would record a flag_active call if a site read in flag mode (Q1).
export STUB_FLAG_ACTIVE=1
unset CHECKPOINTS SIZE_GATE_ENFORCE PREPLAN_SPECULATIVE OVERLAP_SCHEDULE PREPLAN_SKIP_SMALL MAIN_RED_DETECT LANE_GATE_DISABLE

# The real product files, placed where they live so each loader resolves
# lane-switch.sh next to them.
build_root() { # build_root <root>
  sc_harness "$1" || return 1
  mkdir -p "$1/bin/lib/rb" "$1/env" || return 1
  cp "$DIR/bin/lane-checkpoint.sh" "$DIR/bin/lane-alert.sh" "$DIR/bin/main-red-detector.sh" "$1/bin/" || return 1
  cp "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/alert-state.sh" \
     "$DIR/bin/lib/main-red-label.sh" "$1/bin/lib/" || return 1
  cp "$DIR/bin/lib/rb/plan.sh" "$1/bin/lib/rb/" || return 1
  printf '#!/bin/bash\nexit 0\n' > "$1/bin/beat.sh" && chmod +x "$1/bin/beat.sh"
  echo 'TELEGRAM_BOT_TOKEN=tok-test' > "$1/env/global.env"
}
build_root "$T/h2" || { echo "FAIL: cannot build \$T/h2"; exit 1; }
build_root "$T/h"  || { echo "FAIL: cannot build \$T/h"; exit 1; }   # last: SC_ROOT=$T/h
sc_stub_path "$T/stub"

# plan.sh's two sites live inside rb_plan, so each is driven through its own
# marked block, cut from the real file into the same directory so the block's
# loader resolves ../lane-switch.sh exactly as it does in place.
cut_block() { # cut_block <marker> <out>
  awk -v n="$1" 'index($0,"# >>> " n)==1{f=1;next} index($0,"# <<< " n)==1{exit} f' \
    "$T/h/bin/lib/rb/plan.sh" > "$2"
}
cut_block "lane checkpoints"   "$T/h/bin/lib/rb/ckpt-block.sh"
cut_block "size enforce switch" "$T/h/bin/lib/rb/sg-block.sh"
[ -s "$T/h/bin/lib/rb/ckpt-block.sh" ] && [ -s "$T/h/bin/lib/rb/sg-block.sh" ] && ok \
  || bad "could not cut the lane-checkpoints / size-enforce-switch blocks out of plan.sh"

fresh() { # fresh — no rows, no files, no cache, no gate log, in both roots
  local r
  for r in "$T/h" "$T/h2"; do
    scratch_rm "$r/state/lane-gate"; scratch_rm "$r/logs/lane-gate.log"; scratch_rm "$r/state/settings-cache.json"
    rm -f "$r/flags"/*
  done
  rm -f "$T/orc/flags"/* 2>/dev/null
  : > "$CALLS"; : > "$T/stub/calls.log"
  sc_rows
}

# ---- the eight observations; each prints `off` or `run` ----------------------
# Each site runs inside $(…), so a counter would never advance: every run gets
# its own mktemp dir instead, and never reads an earlier run's log.
site1() { # lane-checkpoint.sh disabled
  local b; b=$(mktemp -d "$T/b.XXXXXX")
  printf '{"project":"p","key":"K-1"}\n' > "$b/job.json"
  HARNESS="$T/h" "$T/h/bin/lane-checkpoint.sh" "$b" "$T/no-such-wt" ticket/k-1 execute >/dev/null 2>&1
  if grep -q 'skipped — checkpointing is switched off' "$b/pipeline.log" 2>/dev/null; then echo off
  elif grep -q "CHECKPOINT execute cannot run — $T/no-such-wt is not a directory" "$b/pipeline.log" 2>/dev/null; then echo run
  else echo "?($(cat "$b/pipeline.log" 2>/dev/null))"; fi
}
site2() { # plan.sh CKPT_ON
  ( HARNESS="$T/h"; . "$T/h/bin/lib/rb/ckpt-block.sh" >/dev/null 2>&1
    if CKPT_ON 2>/dev/null; then echo run; else echo off; fi )
}
sg() { # plan.sh SG_SWITCH_RESOLVE -> "<SG_ENFORCE>|<SG_SWITCH_SRC>"
  ( HARNESS="$T/h"; PROJECT=proj; KEY=K-1; ALERTS="$T/h/logs/ALERTS.log"
    STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
    . "$T/h/bin/lib/rb/sg-block.sh" >/dev/null 2>&1
    SG_SWITCH_SRC=""; SG_SWITCH_RESOLVE 2>/dev/null; echo "$SG_ENFORCE|$SG_SWITCH_SRC" )
}
site3() { case "$(sg)" in 0\|*) echo off ;; 1\|*) echo run ;; *) echo "?" ;; esac; }
# The switch line, found not hardcoded: the lane_switch read, or on an
# unconverted tree the bare file read it replaces (so L4 still means something).
MRD_LINE=$(grep -nE 'lane_switch main-red-detector-off|flags/main-red-detector-off" \] && exit 0' \
  "$T/h/bin/main-red-detector.sh" | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
# The statement right after the switch must be the `command -v gh` guard, so a
# trace line `+<MRD_LINE+1>: command -v gh` means the detector ran past its
# switch. sc_trace_past alone cannot say that here: once lane_switch runs, the
# trace also carries lane-gate.sh's own LINENOs, which are larger.
MRD_NEXT=$(( ${MRD_LINE:-0} + 1 ))
sed -n "${MRD_NEXT}p" "$T/h/bin/main-red-detector.sh" | grep -q '^command -v gh ' && ok \
  || bad "main-red-detector.sh line $MRD_NEXT is not the 'command -v gh' guard the trace case keys on"
site4() { # main-red-detector.sh: did the trace get past the switch line?
  [ -n "$MRD_LINE" ] || { echo "?(no lane_switch main-red-detector-off line)"; return; }
  local tr; tr=$(mktemp "$T/trace.XXXXXX")
  HARNESS="$T/h" sc_trace "$tr" "$T/h/bin/main-red-detector.sh" >/dev/null 2>&1
  sc_trace_past "$tr" "$MRD_LINE" >/dev/null 2>&1; [ $? -eq 2 ] && { echo "?(no trace)"; return; }
  if grep -qE "^\++${MRD_NEXT}: command -v gh\$" "$tr"; then echo run; else echo off; fi
}
site5() { # lane-alert.sh --critical: a DM is sent only while the monitor is off
  local id; id=$(mktemp -u XXXXXX); : > "$T/stub/calls.log"
  HARNESS="$T/h" ORCHESTRATOR="$T/orc" LANE_ALERT_DM_CHAT=4242 \
    "$T/h/bin/lane-alert.sh" --critical "pipe-$id" "case $id went red" >/dev/null 2>&1
  if grep -q '^curl .*sendMessage' "$T/stub/calls.log"; then echo off; else echo run; fi
}
pp() { # pp <fn> — the function called for $T/h2 from a shell whose HARNESS is $T/h
  ( HARNESS="$T/h"; . "$T/h/bin/lib/preplan-lib.sh" >/dev/null 2>&1; "$1" "$T/h2" 2>/dev/null )
}
ppsite() { case "$(pp "$1")" in 0) echo off ;; 1) echo run ;; *) echo "?" ;; esac; }
site6() { ppsite preplan_speculative; }
site7() { ppsite overlap_schedule; }
site8() { ppsite preplan_skip_small_on; }

NAME=([1]=lane-checkpoints-off lane-checkpoints-off size-gate-enforce-off main-red-detector-off
      monitor-off preplan-speculative-off overlap-schedule-off preplan-skip-small-off)
# The root each site's flag file and gate log live in: preplan-lib is handed $T/h2.
ROOT=([1]="$T/h" "$T/h" "$T/h" "$T/h" "$T/h" "$T/h2" "$T/h2" "$T/h2")
mkdir -p "$T/orc/flags"

for k in 1 2 3 4 5 6 7 8; do
  n=${NAME[$k]}; r=${ROOT[$k]}
  # Rk — a fleet row, no file.
  fresh; sc_rows "switch.$n=1"
  eq "R$k $n: row switch.$n=1, no file" "$(site$k)" off
  # Fk — row 0 beats the file, and says so once.
  fresh; sc_rows "switch.$n=0"; touch "$r/flags/$n"
  eq "F$k $n: row switch.$n=0 + flags/$n" "$(site$k)" run
  eq "F$k $n: one 'flags/$n ignored' line" "$(sc_ignored_lines "$r" "$n")" 1
  # Lk — no rows: the file decides, as it did before.
  fresh; touch "$r/flags/$n"
  eq "L$k $n: no rows, file present" "$(site$k)" off
  fresh
  eq "L$k $n: no rows, no file" "$(site$k)" run
  # Q1 — file mode: no flag_active read, no row written.
  if grep -qE "^FLAG_ACTIVE $n\$|^PUT " "$CALLS"; then bad "Q1 $n: \$CALLS shows a flag_active read or a PUT: $(cat "$CALLS")"; else ok; fi
done

# ---- the size gate's text --------------------------------------------------------
fresh; touch "$T/h/flags/size-gate-enforce-off"
eq "S1 legacy SG_SWITCH_SRC is today's literal" "$(sg)" "0|flags/size-gate-enforce-off"
fresh; sc_rows switch.size-gate-enforce-off=1
eq "R3 fleet row source text" "$(sg)" "0|settings switch.size-gate-enforce-off (fleet-row)"
fresh; sc_rows switch.size-gate-enforce-off.hub-1=1
eq "R3 box row source text" "$(sg)" "0|settings switch.size-gate-enforce-off (box-row)"
fresh; sc_rows switch.size-gate-enforce-off=0; touch "$T/h/flags/size-gate-enforce-off"
eq "F3 row 0 + file = the shipped default" "$(sg)" "1|the shipped default (armed)"
fresh; sc_rows switch.size-gate-enforce-off=0; touch "$T/h/flags/size-gate-enforce-off"
eq "S2 row 0 falls through to the env chain" "$(SIZE_GATE_ENFORCE=0 sg)" "0|SIZE_GATE_ENFORCE"
fresh
eq "L3 nothing set = the shipped default" "$(sg)" "1|the shipped default (armed)"

# ---- N4: the orchestrator's own flag is still a file read -------------------------
fresh; sc_rows switch.monitor-off=0; touch "$T/orc/flags/monitor-off"
eq "N4 \$ORCHESTRATOR/flags/monitor-off under row switch.monitor-off=0 still DMs" "$(site5)" off

# ---- NEG: rows that must NOT switch a site off ------------------------------------
fresh; sc_rows switch.monitor-off=1
eq "NEG a monitor-off row does not stop main-red-detector" "$(site4)" run
fresh; sc_rows switch.lane-checkpoints-off.other-box=1
eq "NEG another box's row does not stop CKPT_ON" "$(site2)" run
fresh; sc_rows switch.preplan-speculative-off=maybe
eq "NEG an unreadable row value with no file is running" "$(site6)" run
fresh; sc_rows switch.size-gate-enforce-off=0
case "$(sg)" in *settings*) bad "NEG row 0 put 'settings' in SG_SWITCH_SRC: $(sg)" ;; *) ok ;; esac

# ---- FB1: preplan-lib with no lane-switch.sh beside it ----------------------------
mkdir -p "$T/fb/bin/lib" "$T/fb/flags"
cp "$DIR/bin/lib/preplan-lib.sh" "$T/fb/bin/lib/"
fbs() { ( unset -f lane_switch; HARNESS="$T/h"; . "$T/fb/bin/lib/preplan-lib.sh" >/dev/null 2>&1; preplan_speculative "$T/fb" 2>/dev/null ) }
fresh; sc_rows switch.preplan-speculative-off=1
eq "FB1 no lib: a row is not read" "$(fbs)" 1
touch "$T/fb/flags/preplan-speculative-off"
eq "FB1 no lib: the file decides" "$(fbs)" 0

# ---- C1/O1/X1: the registry --------------------------------------------------------
FILES="bin/lane-checkpoint.sh bin/lib/rb/plan.sh bin/lib/preplan-lib.sh bin/lane-alert.sh bin/main-red-detector.sh"
for f in $FILES; do
  names=$(grep -vE '^[[:space:]]*#' "$DIR/$f" | grep -oE 'lane_switch [a-z0-9_-]+' | awk '{print $2}' | sort -u)
  [ -n "$names" ] || { bad "C1 $f reads no switch through lane_switch"; continue; }
  for n in $names; do
    c="$DIR/catalog/switches.d/$n.json"
    if [ "$(jq -r '.name // empty' "$c" 2>/dev/null)" = "$n" ] \
       && jq -e --arg f "$f" '.readers | index($f)' "$c" >/dev/null 2>&1; then ok
    else bad "C1 $f reads $n: catalog/switches.d/$n.json missing, misnamed, or its readers lack $f"; fi
  done
  low=$(head -1 <<<"$names")
  case "$low" in [g-o]*) ok ;; *) bad "O1 $f: lowest-sorted switch '$low' is outside g–o" ;; esac
done
X_NAMES='lane-checkpoints-off|size-gate-enforce-off|preplan-speculative-off|overlap-schedule-off|preplan-skip-small-off|monitor-off|main-red-detector-off'
X=$(cd "$DIR" && grep -rnE "((touch|rm)[^|;&]*|>[[:space:]]*[^|;&[:space:]]*)flags/($X_NAMES)([^a-z0-9-]|\$)|flag_(set|clear)[[:space:]]+\"?($X_NAMES)" \
      bin fly worker console-ui/src 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|//|\*)' | grep -vE '(echo|printf)[[:space:]]')
[ -z "$X" ] && ok || bad "X1 code writes one of this slice's switch files:
$X"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
