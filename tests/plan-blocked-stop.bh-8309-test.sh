#!/bin/bash
# tests/plan-blocked-stop.bh-8309-test.sh — BH-8309: the pool stops relaunching
# a key whose newest hub build record is PLAN_BLOCKED.
#
# THE INCIDENT (cromford, 2026-10-25). 12 tickets looped plan -> PLAN_BLOCKED
# -> re-queued -> plan again until the per-key spawn cap (12 in 24 h). BH-7405,
# BH-7864 and BH-7865 stopped 20 times each in 2 days: 100 Fly runs in one day.
#
# Driven, not grepped, for the behavior. The REAL bin/lib/plan-blocked-stop.sh,
# bin/lib/plan-blocked.sh (pb_excerpt), bin/lib/execute-empty.sh
# (_ee_lift_epoch, _ee_defang) and bin/transcript-scrub.sh run against hub build
# records in a scratch harness root. Every GitHub path is a shell stub that
# logs its call; `gh` on PATH fails the test if anything reaches it (0 network).
#   A  classify: done / after / other, and the class file is reused.
#   B  done: ancestor sha -> one comment + one close (completed), not on a
#      non-ancestor, a 404, an unreadable compare, a closed issue, a reopen.
#   C  the wiring: the REAL pool_spawn_decision refuses an After:-held key
#      before the after/HOLD/cap gates; removing the call makes it spawn.
#   D  after: one After: file; refused while a prerequisite is open; released
#      when all are closed or a person answers; refused on an unreadable read.
#   E  other: 2 in the window -> refused + ONE NEEDS_HUMAN hold; lift on RESUME.
#   F  the three knobs are fly-pool lane knobs with the planned defaults.
#   G  passes: not an Issues board, switch off, newest record not PLAN_BLOCKED.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/plan-blocked-stop.bh-8309-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

LIB="$DIR/bin/lib/plan-blocked-stop.sh"
[ -f "$LIB" ] && ok || bad "missing bin/lib/plan-blocked-stop.sh"

H="$T/h"; mkdir -p "$H/bin" "$H/builds" "$H/logs" "$T/fakebin" "$T/q"
scratch_install_closure bin/transcript-scrub.sh "$H" >/dev/null || { echo "FAIL: cannot install bin/transcript-scrub.sh"; exit 1; }
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$2" in board_prefix) cat "$BPFILE" 2>/dev/null || echo - ;; repo) echo o/r ;; *) echo - ;; esac
SH
cat > "$H/bin/needs-human-hold.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HOLDLOG"
exit "$(cat "$HOLDRC" 2>/dev/null || echo 0)"
SH
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERTLOG"
exit 0
SH
# No real GitHub client may ever run (G4).
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$REALGH"
exit 1
SH
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/needs-human-hold.sh" "$H/bin/alert-line.sh" "$T/fakebin/gh"

NOW=1791640000
# rec <key> <stamp> <age-s> <plan line 1> [more plan lines...] — one hub record
# in the shape the reap writes (RESULT "PLAN_BLOCKED <path>/plan.md", plan.md).
rec() {
  local k="$1" s="$2" age="$3" d; shift 3
  d="$H/builds/pool-bh-$k-$s"; mkdir -p "$d"
  printf 'PLAN_BLOCKED /root/harness/builds/cromford-%s-%s/plan.md\n' "$k" "$s" > "$d/RESULT"
  printf '%s\n' "$@" > "$d/plan.md"
  touch -d "@$((NOW - age))" "$d/RESULT"
}
recd() { printf '%s' "$H/builds/pool-bh-$1-$2"; }
# The stubs' answers, per issue number: $T/st/<n> (open|closed), $T/st/<n>.rc.
mkdir -p "$T/st"
issue() { printf '%s\n' "$2" > "$T/st/$1"; rm -f "$T/st/$1.rc"; }
# trk_stub_adapter — the tracker the gate sees: fleet.conf column 4 from $T/bp
# ("-", the default, is github-issues; a prefix is board), with no D1 read.
trk_stub_adapter() { case "$(cat "$T/bp" 2>/dev/null || echo -)" in -) echo github-issues ;; *) echo board ;; esac; }
GATE() { # GATE <key> [VAR=value ...] -> rc of pbs_stop_check bh <key> <n> <job>
  local k="$1"; shift
  ( for kv in "$@"; do export "${kv?}"; done
    export HARNESS="$H" PBS_NOW="${PBS_NOW_T:-$NOW}" EE_NOW="${PBS_NOW_T:-$NOW}" HOLDLOG="$T/hold.log" HOLDRC="$T/hold.rc" \
           ALERTLOG="$T/alert.log" BPFILE="$T/bp" REALGH="$T/realgh.log" PATH="$T/fakebin:$PATH"
    say() { printf '%s\n' "$*" >> "$T/say.log"; }
    # shellcheck disable=SC1090,SC1091
    . "$DIR/bin/lib/plan-blocked.sh" || exit 9
    # shellcheck disable=SC1090,SC1091
    . "$DIR/bin/lib/execute-empty.sh" || exit 9
    # BH-7919 (on main): _ee_lift_epoch resolves the issue through
    # tracker_kind/trk_gh_issue_number, so the tracker lib is loaded before its
    # adapter answer is stubbed (the tests/execute-empty.bh-5911-test.sh shape).
    # shellcheck disable=SC1090,SC1091
    . "$DIR/bin/lib/tracker.sh"
    tracker_adapter() { trk_stub_adapter; }
    hold_check() { local v; v=$(cat "$T/holdv" 2>/dev/null); printf '%s\n' "$v"
      case "$v" in clear*) return 0 ;; held*) return 1 ;; esac; return 2; }
    _gh_rest_field() { printf 'field %s\n' "$1" >> "$T/gh.log"
      case "$1" in
        *"/compare/"*) local rc; rc=$(cat "$T/cmp.rc" 2>/dev/null || echo 0); [ "$rc" = 0 ] || return "$rc"; cat "$T/cmp" ;;
        *) return 75 ;;
      esac; }
    gh_rest_issue_state() { printf 'state %s\n' "$2" >> "$T/gh.log"
      local rc; rc=$(cat "$T/st/$2.rc" 2>/dev/null || echo 0); [ "$rc" = 0 ] || return "$rc"
      cat "$T/st/$2" 2>/dev/null || echo open; }
    gh_rest_comment() { printf 'comment %s %s\n' "$1" "$2" >> "$T/gh.log"; cat "$3" >> "$T/comments.txt"
      return "$(cat "$T/comment.rc" 2>/dev/null || echo 0)"; }
    gh_rest() { printf 'rest %s\n' "$*" >> "$T/gh.log"
      local rc n; rc=$(cat "$T/patch.rc" 2>/dev/null || echo 0); [ "$rc" = 0 ] || return "$rc"
      n="${2##*/}"; [ -e "$T/noclose" ] || printf 'closed\n' > "$T/st/$n"; return 0; }
    _pb_answers_since() { printf 'answers %s %s %s\n' "$1" "$2" "$3" >> "$T/gh.log"; cat "$T/answers" 2>/dev/null || echo 0; }
    # shellcheck disable=SC1090
    . "$LIB" || exit 9
    pbs_stop_check bh "$k" "${k#BH-}" "$T/q/$k.json" )
}
cnt() { local c; c=$(grep -c "${2:-.}" "$1" 2>/dev/null); echo "${c:-0}"; }
reset() {
  for d in "$H"/builds/*/; do [ -d "$d" ] && scratch_rm "${d%/}"; done
  rm -f "$T"/st/* "$T/gh.log" "$T/comments.txt" "$T/hold.log" "$T/hold.rc" "$T/alert.log" "$T/say.log" \
        "$T/cmp" "$T/cmp.rc" "$T/patch.rc" "$T/comment.rc" "$T/noclose" "$T/answers" "$T/holdv" "$T/bp"
}
cls() { head -1 "$(recd "$1" "$2")/plan-blocked.class" 2>/dev/null; }
SHA=3c8ad37d0
DONE1="BLOCKED: already done on main by $SHA (spec BH-7230 shipped in #8100)"

# ═════ A: classify ══════════════════════════════════════════════════════════
# classify_case <n> <want-class-prefix> <plan line 1> [more lines] (compare ahead)
classify_case() {
  local id="$1" want="$2" k="BH-91$1"; shift 2
  reset; echo ahead > "$T/cmp"; issue "${k#BH-}" open
  rec "$k" 202610251000 600 "$@"
  GATE "$k" >/dev/null 2>&1
  local got; got=$(cls "$k" 202610251000)
  case "$got" in "$want"*) ok ;; *) bad "A$id want class '$want', got '$got' for: $1" ;; esac
}
classify_case 01 "done $SHA" "$DONE1"
classify_case 02 "done 3c8ad37d0aa1bb2cc3dd4ee5ff60718293a4b5c6" "# BLOCKED: already done on main by 3c8ad37d0aa1bb2cc3dd4ee5ff60718293a4b5c6"
classify_case 03 "other" "BLOCKED-NEEDS-CLARIFICATION" "" "Some context." "" "BLOCKED: already done on main by $SHA"
classify_case 04 "other" "Plan: partly done on main by $SHA"
classify_case 05 "other" "BLOCKED: already done on main by xyz123"
classify_case 06 "after BH-8250" "BLOCKED: needs #8250 merged first"
classify_case 07 "after BH-8266" "BLOCKED: Blocked by BH-8266, which is still open"
classify_case 08 "after BH-8289 BH-8299" "BLOCKED: waits for #8289 and #8299 to land"
classify_case 09 "after BH-8250" "BLOCKED: on hold until BH-8250 merges"
classify_case 10 "other" "BLOCKED: on hold until its prerequisites merge"
classify_case 11 "other" "BLOCKED: needs-human: design collision (BH-5791)"
classify_case 12 "other" "BLOCKED: - Other work changed \`pool_spawn_decision\` after this plan's base"
classify_case 13 "other" "BLOCKED: see BH-7123 review levels"
classify_case 14 "other" "BLOCKED: blocked by a missing credential"
classify_case 15 "other" "BLOCKED: needs BH-7916.1 merged first"
classify_case 16 "other" "BLOCKED: TK-12 merged first"
classify_case 17 "other" "BLOCKED: waiting on https://github.com/o/r/issues/9117#issuecomment-6400244896"
# A18 self: the ticket's own number is never a prerequisite.
reset; issue 9118 open; rec BH-9118 202610251000 600 "BLOCKED: needs #9118 merged first"
GATE BH-9118 >/dev/null 2>&1; [ "$(cls BH-9118 202610251000)" = other ] && ok || bad "A18 the ticket itself is not a prerequisite: $(cls BH-9118 202610251000)"
# A19 the class file is reused: tick 2 makes 0 compare calls.
reset; echo ahead > "$T/cmp"; issue 9119 open; echo 1 > "$T/patch.rc"
rec BH-9119 202610251000 600 "$DONE1"
GATE BH-9119 >/dev/null 2>&1; C1=$(cnt "$T/gh.log" compare)
GATE BH-9119 >/dev/null 2>&1; C2=$(cnt "$T/gh.log" compare)
[ "$C1" = 1 ] && [ "$C2" = 1 ] && ok || bad "A19 the class must be cached: compare calls $C1 then $C2"
# A20 an unreadable compare writes no class file (retried next tick).
reset; echo 75 > "$T/cmp.rc"; issue 9120 open
rec BH-9120 202610251000 600 "$DONE1"
GATE BH-9120 >/dev/null 2>&1
[ ! -e "$(recd BH-9120 202610251000)/plan-blocked.class" ] && ok || bad "A20 an unreadable compare must write no class file"

# ═════ B: done -> close once ════════════════════════════════════════════════
# B1 ancestor (ahead)
reset; echo ahead > "$T/cmp"; issue 9201 open
rec BH-9201 202610251000 600 "$DONE1"
GATE BH-9201; R=$?
[ "$R" = 1 ] && ok || bad "B1 the close tick must refuse the spawn (rc $R)"
[ "$(cnt "$T/gh.log" '^comment o/r 9201$')" = 1 ] && ok || bad "B1 want one comment on #9201: $(cat "$T/gh.log" 2>/dev/null)"
grep -q "already done on main by $SHA" "$T/comments.txt" 2>/dev/null && ok || bad "B1 the comment must carry the plan's sentence: $(cat "$T/comments.txt" 2>/dev/null)"
grep -qi "reopen" "$T/comments.txt" 2>/dev/null && ok || bad "B1 the comment must say a reopen plans it again"
[ "$(cnt "$T/gh.log" '^rest PATCH repos/o/r/issues/9201 ')" = 1 ] && ok || bad "B1 want one PATCH: $(cat "$T/gh.log")"
grep -q '^rest PATCH repos/o/r/issues/9201 .*state=closed.*state_reason=completed' "$T/gh.log" && ok || bad "B1 the PATCH must close as completed: $(grep PATCH "$T/gh.log")"
[ -e "$(recd BH-9201 202610251000)/plan-blocked.closed" ] && ok || bad "B1 no plan-blocked.closed marker"
grep -q "skipping BH-9201: PLAN_BLOCKED done $SHA — ticket #9201 closed (completed)" "$T/say.log" 2>/dev/null && ok || bad "B1 no closed say line: $(cat "$T/say.log" 2>/dev/null)"
# B3 the next tick passes, with no new comment and no new PATCH.
GATE BH-9201; R=$?
[ "$R" = 0 ] && ok || bad "B3 the tick after the close must pass to the HOLD gate (rc $R)"
[ "$(cnt "$T/gh.log" '^comment ')" = 1 ] && [ "$(cnt "$T/gh.log" '^rest PATCH')" = 1 ] && ok || bad "B3 a second comment or PATCH was sent: $(cat "$T/gh.log")"
# B2 identical
reset; echo identical > "$T/cmp"; issue 9202 open
rec BH-9202 202610251000 600 "$DONE1"
GATE BH-9202; R=$?
[ "$R" = 1 ] && [ -e "$(recd BH-9202 202610251000)/plan-blocked.closed" ] && [ "$(cnt "$T/gh.log" '^rest PATCH')" = 1 ] && ok || bad "B2 identical must close (rc $R)"
# B4 behind / diverged: not closed, class other
for s in behind diverged; do
  reset; echo "$s" > "$T/cmp"; issue 9204 open
  rec BH-9204 202610251000 600 "$DONE1"
  GATE BH-9204 >/dev/null 2>&1
  [ "$(cnt "$T/gh.log" '^comment ')" = 0 ] && [ "$(cnt "$T/gh.log" '^rest ')" = 0 ] && ok || bad "B4 $s: a non-ancestor sha must not close: $(cat "$T/gh.log")"
  [ "$(cls BH-9204 202610251000)" = other ] && ok || bad "B4 $s: class must be other, got $(cls BH-9204 202610251000)"
done
# B5 404 and unreadable compare: no close
for rc in 44 75; do
  reset; echo "$rc" > "$T/cmp.rc"; issue 9205 open
  rec BH-9205 202610251000 600 "$DONE1"
  GATE BH-9205 >/dev/null 2>&1
  [ "$(cnt "$T/gh.log" '^comment ')" = 0 ] && [ "$(cnt "$T/gh.log" '^rest ')" = 0 ] && ok || bad "B5 compare rc $rc must not close: $(cat "$T/gh.log")"
done
# B4b a failed re-read writes no closed marker and no closed line.
reset; echo ahead > "$T/cmp"; issue 9214 open; : > "$T/noclose"
rec BH-9214 202610251000 600 "$DONE1"
GATE BH-9214; R=$?
[ "$R" = 1 ] && [ ! -e "$(recd BH-9214 202610251000)/plan-blocked.closed" ] && ok || bad "B4b a close the re-read does not confirm must write no closed marker (rc $R)"
grep -q "closed (completed)" "$T/say.log" 2>/dev/null && bad "B4b said closed without a closed re-read" || ok
# B6 the issue is already closed: 0 comments, 0 PATCH, marker written.
reset; echo ahead > "$T/cmp"; issue 9206 closed
rec BH-9206 202610251000 600 "$DONE1"
GATE BH-9206 >/dev/null 2>&1
[ "$(cnt "$T/gh.log" '^comment ')" = 0 ] && [ "$(cnt "$T/gh.log" '^rest ')" = 0 ] && ok || bad "B6 a closed issue gets no comment and no PATCH: $(cat "$T/gh.log")"
[ -e "$(recd BH-9206 202610251000)/plan-blocked.closed" ] && ok || bad "B6 the closed marker must be written"
# B7 a person reopened after an auto-close: a new done record is class other.
reset; echo ahead > "$T/cmp"; issue 9207 open
rec BH-9207 202610250800 7200 "$DONE1"; echo "done $SHA" > "$(recd BH-9207 202610250800)/plan-blocked.class"; : > "$(recd BH-9207 202610250800)/plan-blocked.closed"
rec BH-9207 202610251000 600 "$DONE1"
GATE BH-9207 >/dev/null 2>&1
[ "$(cnt "$T/gh.log" '^comment ')" = 0 ] && [ "$(cnt "$T/gh.log" '^rest ')" = 0 ] && ok || bad "B7 a reopened ticket is never closed twice: $(cat "$T/gh.log")"
[ "$(cls BH-9207 202610251000)" = other ] && ok || bad "B7 class must be other, got $(cls BH-9207 202610251000)"
# B8 a failed PATCH: refused, one alert; the retry sends a PATCH and no second comment.
reset; echo ahead > "$T/cmp"; issue 9208 open; echo 75 > "$T/patch.rc"
rec BH-9208 202610251000 600 "$DONE1"
GATE BH-9208; R=$?
[ "$R" = 1 ] && [ "$(cnt "$T/alert.log")" = 1 ] && ok || bad "B8 a failed close: rc 1 and one alert (rc $R, alerts $(cnt "$T/alert.log"))"
GATE BH-9208 >/dev/null 2>&1
[ "$(cnt "$T/alert.log")" = 1 ] && ok || bad "B8 one alert per record, not per tick ($(cnt "$T/alert.log"))"
rm -f "$T/patch.rc"; GATE BH-9208 >/dev/null 2>&1
[ "$(cnt "$T/gh.log" '^rest PATCH')" = 3 ] && [ "$(cnt "$T/gh.log" '^comment ')" = 1 ] && ok || bad "B8 the retry must PATCH again with no second comment: $(cat "$T/gh.log")"
[ -e "$(recd BH-9208 202610251000)/plan-blocked.closed" ] && ok || bad "B8 the retried close must write the marker"

# ═════ D: after -> held until the prerequisite closes ═══════════════════════
reset; issue 9301 open; issue 8250 open
rec BH-9301 202610251000 600 "BLOCKED: needs #8250 merged first"
GATE BH-9301; R=$?
[ "$R" = 1 ] && ok || bad "D2 #8250 open: refused (rc $R)"
AF="$(recd BH-9301 202610251000)/plan-blocked.after"
[ "$(cat "$AF" 2>/dev/null)" = "After: BH-8250" ] && ok || bad "D1/D5 one After: file with the key form: $(cat "$AF" 2>/dev/null)"
grep -q "skipping BH-9301: PLAN_BLOCKED after BH-8250 — waits, no machine" "$T/say.log" 2>/dev/null && ok || bad "D2 no waits say line: $(cat "$T/say.log" 2>/dev/null)"
GATE BH-9301; R=$?
[ "$R" = 1 ] && [ "$(cnt "$T/gh.log" '^comment ')" = 0 ] && ok || bad "D2 tick 2 still refused, no comment (rc $R)"
issue 8250 closed
GATE BH-9301; R=$?
[ "$R" = 0 ] && [ -e "$(recd BH-9301 202610251000)/plan-blocked.released" ] && ok || bad "D3 #8250 closed: spawned and released (rc $R)"
grep -q "RELEASED BH-9301: PLAN_BLOCKED after BH-8250 — all closed" "$T/say.log" && ok || bad "D3 no RELEASED line"
# D4 two keys, one open
reset; issue 9304 open; issue 8289 closed; issue 8299 open
rec BH-9304 202610251000 600 "BLOCKED: waits for #8289 and #8299 to land"
GATE BH-9304; R=$?
[ "$R" = 1 ] && ok || bad "D4 one of two still open: refused (rc $R)"
[ "$(cat "$(recd BH-9304 202610251000)/plan-blocked.after" 2>/dev/null | tr '\n' ' ')" = "After: BH-8289 After: BH-8299 " ] && ok || bad "D5 the After: lines name exactly the keys"
# D6 an open prerequisite and a human comment after the record: released once.
reset; issue 9306 open; issue 8250 open; echo 1 > "$T/answers"
rec BH-9306 202610251000 600 "BLOCKED: needs #8250 merged first"
GATE BH-9306; R=$?
[ "$R" = 0 ] && [ -e "$(recd BH-9306 202610251000)/plan-blocked.released" ] && ok || bad "D6 a person's answer releases it (rc $R)"
grep -q "^answers o/r 9306 $((NOW - 600))$" "$T/gh.log" && ok || bad "D6 answers are read on the ticket since the RESULT: $(grep answers "$T/gh.log")"
reset; issue 9316 open; issue 8250 open; echo 0 > "$T/answers"
rec BH-9316 202610251000 600 "BLOCKED: needs #8250 merged first"
GATE BH-9316; R=$?
[ "$R" = 1 ] && ok || bad "D6 only bot comments: still refused (rc $R)"
# D7 an unreadable read: refused, retried
reset; issue 9307 open; issue 8250 closed; echo 75 > "$T/st/8250.rc"
rec BH-9307 202610251000 600 "BLOCKED: needs #8250 merged first"
GATE BH-9307; R=$?
[ "$R" = 1 ] && [ ! -e "$(recd BH-9307 202610251000)/plan-blocked.released" ] && ok || bad "D7 an unreadable read must refuse and not release (rc $R)"

# ═════ E: other -> cap at 2, ONE NEEDS_HUMAN ═══════════════════════════════
OQ="BLOCKED: which API should the RESUME hold button call?"
reset; issue 9401 open
rec BH-9401 202610251000 600 "$OQ"
GATE BH-9401; R=$?
[ "$R" = 0 ] && [ "$(cnt "$T/hold.log")" = 0 ] && ok || bad "E1 one other in the window: spawn, no hold (rc $R)"
reset; issue 9402 open
rec BH-9402 202610250800 7200 "BLOCKED: an older wording"
rec BH-9402 202610251000 600 "$OQ"
GATE BH-9402; R=$?
[ "$R" = 1 ] && ok || bad "E2 two others in 24 h: refused (rc $R)"
[ "$(cnt "$T/hold.log")" = 1 ] && ok || bad "E2 want exactly one hold, got $(cnt "$T/hold.log")"
HL=$(head -1 "$T/hold.log" 2>/dev/null)
[[ "$HL" == "bh 9402 "* ]] && [[ "$HL" == *" plan-blocked" ]] && ok || bad "E2 the hold names bh #9402 with source plan-blocked: $HL"
grep -q "Last question: which API should the R_ESUME h_old button call" <<<"$HL" && ok || bad "E2 the action holds the excerpt's first line, defanged: $HL"
grep -q "skipping BH-9402: PLAN_BLOCKED other 2x in 86400s (cap 2) — NEEDS_HUMAN" "$T/say.log" && ok || bad "E2 no cap say line: $(cat "$T/say.log")"
GATE BH-9402; R=$?
[ "$R" = 1 ] && [ "$(cnt "$T/hold.log")" = 1 ] && ok || bad "E3 next tick: refused, still one hold (rc $R, holds $(cnt "$T/hold.log"))"
# E4 one of two past the window
reset; issue 9404 open
rec BH-9404 202610240800 90000 "BLOCKED: old"; rec BH-9404 202610251000 600 "$OQ"
GATE BH-9404; R=$?
[ "$R" = 0 ] && ok || bad "E4 one of the two past the window: spawn (rc $R)"
GATE BH-9404 POOL_PLAN_BLOCKED_WINDOW_S=100000; R=$?
[ "$R" = 1 ] && ok || bad "E4 a wider window (the settings row) counts it (rc $R)"
# E5 done/after records do not count toward the cap
reset; issue 9405 open; issue 8250 closed; echo behind > "$T/cmp"
rec BH-9405 202610250700 9000 "BLOCKED: needs #8250 merged first"
rec BH-9405 202610250800 7200 "$DONE1"; echo "done $SHA" > "$(recd BH-9405 202610250800)/plan-blocked.class"
rec BH-9405 202610251000 600 "$OQ"
GATE BH-9405; R=$?
[ "$R" = 0 ] && [ "$(cnt "$T/hold.log")" = 0 ] && ok || bad "E5 only other records count (rc $R)"
# E6 a RESUME after the ask lifts it; the next other alone does not refuse.
reset; issue 9406 open
rec BH-9406 202610250800 7200 "BLOCKED: q1"; rec BH-9406 202610251000 600 "$OQ"
GATE BH-9406 PBS_NOW_T=$((NOW - 300)) >/dev/null 2>&1
ASKED=$(head -1 "$(recd BH-9406 202610251000)/plan-blocked.asked" 2>/dev/null)
[ "$ASKED" = $((NOW - 300)) ] && ok || bad "E6 the asked epoch is recorded: '$ASKED'"
printf 'held\thold:waiting-on-human x\n' > "$T/holdv"
GATE BH-9406; R=$?; [ "$R" = 1 ] && ok || bad "E6 still waiting on a person: refused (rc $R)"
printf 'clear\tlifted-by-comment %s\n' "$(date -u -d "@$((NOW - 60))" +%Y-%m-%dT%H:%M:%SZ)" > "$T/holdv"
GATE BH-9406; R=$?
[ "$R" = 0 ] && [ "$(head -1 "$(recd BH-9406 202610251000)/plan-blocked.lifted" 2>/dev/null)" = $((NOW - 60)) ] && ok || bad "E6 a RESUME after the ask lifts it (rc $R)"
rec BH-9406 202610251100 30 "BLOCKED: q3"
GATE BH-9406; R=$?
[ "$R" = 0 ] && [ "$(cnt "$T/hold.log")" = 1 ] && ok || bad "E6 one new other after the lift spawns (rc $R)"
# E7 MAX=0 is off
reset; issue 9407 open
rec BH-9407 202610250800 7200 "BLOCKED: q1"; rec BH-9407 202610251000 600 "$OQ"
GATE BH-9407 POOL_PLAN_BLOCKED_MAX=0; R=$?
[ "$R" = 0 ] && [ "$(cnt "$T/hold.log")" = 0 ] && ok || bad "E7 MAX=0 never refuses (rc $R)"
# E8 the hold script fails: refused, one alert, retried next tick
reset; issue 9408 open; echo 1 > "$T/hold.rc"
rec BH-9408 202610250800 7200 "BLOCKED: q1"; rec BH-9408 202610251000 600 "$OQ"
GATE BH-9408; R=$?
[ "$R" = 1 ] && [ "$(cnt "$T/alert.log" NEEDS_HUMAN)" = 1 ] && ok || bad "E8 a failed hold: refused, one alert (rc $R)"
rm -f "$T/hold.rc"; GATE BH-9408 >/dev/null 2>&1
[ "$(cnt "$T/hold.log")" = 2 ] && [ -e "$(recd BH-9408 202610251000)/plan-blocked.asked" ] && ok || bad "E8 the next tick retries the hold ($(cnt "$T/hold.log"))"

# ═════ G: passes ════════════════════════════════════════════════════════════
reset; echo pb > "$T/bp"; issue 9501 open
rec BH-9501 202610250800 7200 "BLOCKED: q1"; rec BH-9501 202610251000 600 "$OQ"
GATE BH-9501; R=$?
[ "$R" = 0 ] && [ "$(cnt "$T/gh.log")" = 0 ] && ok || bad "G1 not an Issues board: pass, 0 gh calls (rc $R)"
reset; issue 9502 open
rec BH-9502 202610250800 7200 "BLOCKED: q1"; rec BH-9502 202610251000 600 "$OQ"
GATE BH-9502 POOL_PLAN_BLOCKED_STOP=0; R=$?
[ "$R" = 0 ] && [ "$(cnt "$T/gh.log")" = 0 ] && [ "$(cnt "$T/hold.log")" = 0 ] && ok || bad "G2 the switch off: pass, 0 gh calls (rc $R)"
reset; issue 9503 open; issue 8250 open
rec BH-9503 202610250800 7200 "BLOCKED: needs #8250 merged first"
mkdir -p "$(recd BH-9503 202610251000)"; echo "PR_CREATED https://github.com/o/r/pull/1" > "$(recd BH-9503 202610251000)/RESULT"
touch -d "@$((NOW - 600))" "$(recd BH-9503 202610251000)/RESULT"
GATE BH-9503; R=$?
[ "$R" = 0 ] && ok || bad "G3 the newest record is PR_CREATED: pass (rc $R)"

# ═════ C: the wiring ════════════════════════════════════════════════════════
grep -qE '^\. "\$HARNESS/bin/lib/plan-blocked-stop.sh"' "$DIR/bin/fly-pool.sh" && ok || bad "C3 bin/fly-pool.sh must source bin/lib/plan-blocked-stop.sh"
awk '/^pool_spawn_decision\(\) \{/{f=1} f; f && /^}/{exit}' "$DIR/bin/fly-pool.sh" > "$T/psd.sh"
[ -s "$T/psd.sh" ] && ok || bad "C setup: could not extract pool_spawn_decision"
# The same function with the gate block removed (C4: the production path proof).
awk '/# >>> plan-blocked stop \(BH-8309\)/{s=1} !s; /# <<< plan-blocked stop/{s=0}' "$T/psd.sh" > "$T/psd-nogate.sh"
PSD() { # PSD <psd-file> <key> -> "rc=<rc>"; the gates after it log to $T/psd.log
  local k="$2"; echo '{}' > "$T/q/$k.json"
  ( export HARNESS="$H" PBS_NOW="$NOW" BPFILE="$T/bp" REALGH="$T/realgh.log" PATH="$T/fakebin:$PATH"
    # shellcheck disable=SC2034 # read by the extracted function
    P=bh; QDIR="$T/q"; LOG="$T/pool.err"; _PHC_READ_S=0
    say() { printf '%s\n' "$*" >> "$T/say.log"; }
    QROW() { printf 'QROW %s\n' "$*" >> "$T/psd.log"; }
    pool_tick_budget_spent() { return 1; }
    pool_gates_applicable() { printf 'gates\n' >> "$T/psd.log"; return 0; }
    pool_after_gate() { printf 'after\n' >> "$T/psd.log"; return 0; }
    pool_hold_check() { printf 'hold\n' >> "$T/psd.log"; printf 'clear\n'; }
    pool_hold_clear() { :; }; pool_terminal_path() { printf '%s/%s.terminal\n' "$T" "$1"; }
    pr_exists_for_key_rest() { return 1; }; pool_terminal_check() { return 0; }
    pool_spawn_cap_check() { printf 'cap\n' >> "$T/psd.log"; return 0; }
    # shellcheck disable=SC1090,SC1091
    . "$DIR/bin/lib/plan-blocked.sh"
    # shellcheck disable=SC1090,SC1091
    . "$DIR/bin/lib/tracker.sh"
    tracker_adapter() { trk_stub_adapter; }
    # The gate loads the tracker's GitHub adapter, which sources the real
    # gh-rest.sh when no gh_rest is defined; that would replace the stubs here.
    gh_rest() { printf 'rest %s\n' "$*" >> "$T/gh.log"; return 0; }
    gh_rest_issue_state() { printf 'state %s\n' "$2" >> "$T/gh.log"; cat "$T/st/$2" 2>/dev/null || echo open; }
    _pb_answers_since() { echo 0; }
    # shellcheck disable=SC1090
    . "$LIB" 2>/dev/null
    # shellcheck disable=SC1090
    . "$1"
    # The HOLD gate calls pool_hold_read since BH-7942; the real one wraps the
    # pool_hold_check stub above, so "hold" still logs on the production path.
    eval "$(awk '/^pool_hold_read\(\) \{/,/^}/' "$DIR/bin/fly-pool.sh")"
    pool_spawn_decision "$T/q/$k.json" "$k" "${k#BH-}"; echo "rc=$?" )
}
reset; rm -f "$T/psd.log"; issue 9601 open; issue 8250 open
rec BH-9601 202610251000 600 "BLOCKED: needs #8250 merged first"
OUT=$(PSD "$T/psd.sh" BH-9601)
[ "$OUT" = "rc=1" ] && ok || bad "C1 the pool must refuse an After:-held key (got $OUT)"
[ -e "$T/q/BH-9601.json" ] && ok || bad "C1 the refusal keeps the queue file"
[ "$(tr '\n' ' ' < "$T/psd.log" 2>/dev/null)" = "gates " ] && ok || bad "C2 the refusal runs after pool_gates_applicable and calls no after/HOLD/cap gate: $(tr '\n' ' ' < "$T/psd.log" 2>/dev/null)"
grep -q 'QROW' "$T/psd.log" 2>/dev/null && bad "C1 the refusal must not write a QROW" || ok
rm -f "$T/psd.log"
OUT=$(PSD "$T/psd-nogate.sh" BH-9601)
[ "$OUT" = "rc=0" ] && grep -q '^cap$' "$T/psd.log" && ok || bad "C4 without the gate the same key spawns (got $OUT): the gate is what refuses it"
issue 8250 closed; rm -f "$T/psd.log"
OUT=$(PSD "$T/psd.sh" BH-9601)
[ "$OUT" = "rc=0" ] && [ "$(tr '\n' ' ' < "$T/psd.log")" = "gates after hold cap " ] && ok || bad "C1 after #8250 closes the key spawns through every later gate (got $OUT; $(tr '\n' ' ' < "$T/psd.log" 2>/dev/null))"
# C2 the line order in the real function
ln_of() { grep -n "$1" "$T/psd.sh" | head -1 | cut -d: -f1; }
GA=$(ln_of 'if ! pool_gates_applicable'); PB=$(ln_of 'pbs_stop_check "\$P"'); AG=$(ln_of 'pool_after_gate "\$JF"')
HC=$(ln_of 'pool_hold_read "\$TICKET"'); CC=$(ln_of 'pool_spawn_cap_check "\$KEY"')
[ -n "$GA" ] && [ -n "$PB" ] && [ -n "$AG" ] && [ -n "$HC" ] && [ -n "$CC" ] \
  && [ "$GA" -lt "$PB" ] && [ "$PB" -lt "$AG" ] && [ "$AG" -lt "$HC" ] && [ "$HC" -lt "$CC" ] \
  && ok || bad "C2 order gates<pbs<after<hold<cap: $GA $PB $AG $HC $CC"

# ═════ F: the knobs ═════════════════════════════════════════════════════════
for kv in POOL_PLAN_BLOCKED_STOP=1 POOL_PLAN_BLOCKED_MAX=2 POOL_PLAN_BLOCKED_WINDOW_S=86400; do
  k="${kv%=*}"; v="${kv#*=}"; f="$DIR/catalog/lanes.d/fly-pool.knobs.d/$k.json"
  [ "$(jq -r '.default' "$f" 2>/dev/null)" = "$v" ] && [ "$(jq -r '.read_in' "$f" 2>/dev/null)" = bin/lib/plan-blocked-stop.sh ] \
    && ok || bad "F $k: want a knob fragment with default $v read in bin/lib/plan-blocked-stop.sh"
  grep -q "\${$k:-$v}" "$LIB" 2>/dev/null && ok || bad "F $k: the code fallback must be \${$k:-$v}"
done

# G4 nothing reached a real GitHub client
[ ! -s "$T/realgh.log" ] && ok || bad "G4 a real gh call was made: $(cat "$T/realgh.log")"

echo "plan-blocked-stop.bh-8309: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
