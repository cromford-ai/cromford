#!/bin/bash
# tests/unblock-act-phase-unreadable.bh-9446-test.sh — BH-9446 (scope 1): the
# rebuild arm of bin/lib/unblock/act.sh. A 409 from lifecycle_transition whose
# body names no current phase is an UNREAD phase, not a moved one: the
# transition is sent again (UNBLOCK_PHASE_REREADS, default 1), and still no
# phase is `failed phase-unreadable`, never `refused phase-moved:unknown`.
#
#   P1  409 {} then 409 {"current":"planned"}: done launched, 2 transitions.
#   P2  409 {} twice: failed phase-unreadable; phase-moved:unknown is in
#       neither the detail nor logs/unblock.log; 0 launches.
#   P3  409 {} then rc 0: done; 409 {} then 409 building: refused
#       phase-moved:building; 409 {} then rc 1: failed transition rc 1.
#   P4  UNBLOCK_PHASE_REREADS=0: 409 {} = failed phase-unreadable after 1
#       transition; a non-JSON 409 body reads as no phase; a bad knob value
#       is the fallback 1 (2 transitions).
#   P5  the plan's REPRO command, verbatim: no longer phase-moved:unknown.
#   P6  unchanged: 409 building = refused phase-moved:building after ONE
#       transition (no re-read when the phase was read).
#
# Every case runs the REAL ub_act (the production entry, action rebuild) with
# a lifecycle_transition stub that answers from a queue file (one line per
# call: `<rc> <body>`), a launch-fastpath stub and a jobs-client stub for the
# mode row. 0 network calls: a PATH gh/curl stub logs and fails, and the
# suite asserts its log is empty.
#
# MUTATIONS (D1), each tried once by hand: put back `${cur:-unknown}` with no
# re-read -> P1, P2 red; re-read with no bound -> P2 (3 calls) red; ignore the
# knob -> P4 red; re-read when the phase was read -> P6 red.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-act-phase-unreadable.bh-9446-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "${2:0:1500}"; return 0; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want '$3' got '$2'"; fi; }
cnt() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }

mkdir -p "$T/pathbin"
for s in gh curl claude; do printf '#!/bin/bash\necho "%s $*" >> "%s/vendor.log"\nexit 7\n' "$s" "$T" > "$T/pathbin/$s"; done
chmod +x "$T/pathbin/"*
: > "$T/vendor.log"

# mk <name> — one case root: a mode row (act), a logging launch-fastpath.
mk() {
  local A="$T/$1"
  mkdir -p "$A/h/bin" "$A/h/logs" "$A/fx"
  printf '#!/bin/bash\n[ "$1" = setting-get ] && [ "$2" = unblock.project.cromford.mode ] && { echo act; exit 0; }\nexit 2\n' \
    > "$A/h/bin/jobs-client.sh"
  printf '#!/bin/bash\necho "$*" >> "$FXT/launch.log"\nexit 0\n' > "$A/h/bin/launch-fastpath.sh"
  printf '#!/bin/bash\nexit 0\n' > "$A/h/bin/lane-alert.sh"
  chmod +x "$A/h/bin/"*.sh
  : > "$A/fx/answers"
  printf '%s' "$A"
}
# answer <case> <rc> <body> — queue one lifecycle_transition answer.
answer() { printf '%s %s\n' "$2" "$3" >> "$1/fx/answers"; }
# act <case> [env...] — the REAL ub_act rebuild; prints "<outcome>|<detail>".
act() {
  local A="$1"; shift
  ( export HARNESS="$A/h" FXT="$A/fx" UNBLOCK_ACT=1 PATH="$T/pathbin:$PATH"
    for e in "$@"; do export "${e?}"; done
    . "$SRC/bin/lib/unblock/act.sh"
    lifecycle_transition() {
      local n line
      n=$(( $(cat "$FXT/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FXT/calls"
      line=$(sed -n "${n}p" "$FXT/answers")
      [ -n "$line" ] || return 1
      printf '%s' "${line#* }"
      return "${line%% *}"
    }
    ub_act "$(jq -nc '{decision_key: "bh9446p", project: "cromford", repo: "example-org/cromford",
      subject_kind: "build", subject: "cromford:BH-9340", pr: null, head: null, rule_id: "U14-REBUILD",
      class: "build-relaunch", cites: ["G1"], action: {name: "rebuild", args: {key: "BH-9340"}}}')" >/dev/null
    printf '%s|%s' "$UB_ACT_OUTCOME" "$UB_ACT_DETAIL" )
}
calls() { cat "$1/fx/calls" 2>/dev/null || echo 0; }

# ═════ P1 ════════════════════════════════════════════════════════════════════
A=$(mk p1); answer "$A" 9 '{}'; answer "$A" 9 '{"current":"planned"}'
check "P1 409 {} then 409 planned: done launched" "$(act "$A")" "done|launched"
check "P1 2 transitions, 1 launch" "$(calls "$A") $(cnt . "$A/fx/launch.log")" "2 1"

# ═════ P2 ════════════════════════════════════════════════════════════════════
A=$(mk p2); answer "$A" 9 '{}'; answer "$A" 9 '{"error":"conflict"}'
check "P2 409 with no phase twice: failed phase-unreadable" "$(act "$A")" "failed|phase-unreadable"
check "P2 2 transitions, 0 launches" "$(calls "$A") $(cnt . "$A/fx/launch.log")" "2 0"
check "P2 phase-moved:unknown is not in the log" "$(cnt 'phase-moved:unknown' "$A/h/logs/unblock.log")" 0
check "P2 the log line names phase-unreadable" "$(cnt 'rebuild failed phase-unreadable' "$A/h/logs/unblock.log")" 1

# ═════ P3 ════════════════════════════════════════════════════════════════════
A=$(mk p3a); answer "$A" 9 '{}'; answer "$A" 0 '{"ok":true}'
check "P3 409 {} then 200: done launched, 2 transitions" "$(act "$A") $(calls "$A")" "done|launched 2"
A=$(mk p3b); answer "$A" 9 '{}'; answer "$A" 9 '{"current":"building"}'
check "P3 409 {} then 409 building: refused phase-moved:building, 0 launches" \
  "$(act "$A") $(cnt . "$A/fx/launch.log")" "refused|phase-moved:building 0"
A=$(mk p3c); answer "$A" 9 '{}'; answer "$A" 1 ''
check "P3 409 {} then rc 1: failed transition rc 1" "$(act "$A")" "failed|transition rc 1"
A=$(mk p3d); answer "$A" 9 '{}'; answer "$A" 2 ''
check "P3 409 {} then 404: refused no-row" "$(act "$A")" "refused|no-row"

# ═════ P4 ════════════════════════════════════════════════════════════════════
A=$(mk p4a); answer "$A" 9 '{}'; answer "$A" 9 '{"current":"planned"}'
check "P4 UNBLOCK_PHASE_REREADS=0: failed phase-unreadable after 1 transition" \
  "$(act "$A" UNBLOCK_PHASE_REREADS=0) $(calls "$A")" "failed|phase-unreadable 1"
A=$(mk p4b); answer "$A" 9 'not json'; answer "$A" 9 'still not json'
check "P4 a non-JSON 409 body reads as no phase" "$(act "$A") $(calls "$A")" "failed|phase-unreadable 2"
A=$(mk p4c); answer "$A" 9 '{}'; answer "$A" 9 '{}'; answer "$A" 9 '{}'
check "P4 UNBLOCK_PHASE_REREADS=2: 3 transitions" "$(act "$A" UNBLOCK_PHASE_REREADS=2) $(calls "$A")" "failed|phase-unreadable 3"
A=$(mk p4d); answer "$A" 9 '{}'; answer "$A" 9 '{}'; answer "$A" 9 '{}'
check "P4 a bad knob (x) is the fallback 1: 2 transitions" "$(act "$A" UNBLOCK_PHASE_REREADS=x) $(calls "$A")" "failed|phase-unreadable 2"

# ═════ P5: the plan's REPRO, verbatim (run from the repo root) ═══════════════
OUT=$(cd "$SRC" && PATH="$T/pathbin:$PATH" HARNESS=$(mktemp -d "$T/repro.XXXXXX") bash -c '. bin/lib/unblock/act.sh; lifecycle_transition(){ echo "{}"; return 9; }; _UB_P=cromford; _UB_ARGS="{\"key\":\"BH-9340\"}"; _ub_arg(){ jq -r --arg k "$1" ".[\$k] // \"\"" <<<"$_UB_ARGS"; }; _ub_to_planned x; echo "$UB_ACT_OUTCOME $UB_ACT_DETAIL"' 2>&1 | tail -n 1)
check "P5 the REPRO prints failed phase-unreadable" "$OUT" "failed phase-unreadable"

# ═════ P6: a read phase is never re-read ═════════════════════════════════════
A=$(mk p6); answer "$A" 9 '{"current":"building"}'; answer "$A" 9 '{"current":"planned"}'
check "P6 409 building: refused phase-moved:building after 1 transition" "$(act "$A") $(calls "$A")" "refused|phase-moved:building 1"

check "B 0 gh, curl or model CLI calls" "$(grep -c . "$T/vendor.log")" 0
echo "unblock-act-phase-unreadable.bh-9446: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
