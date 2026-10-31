#!/bin/bash
# tests/plan-blocked-stop-parent.bh-8839-test.sh — BH-8839: the PLAN_BLOCKED
# `after` gate (bin/lib/plan-blocked-stop.sh, BH-8309) never waits on the
# ticket's own rollout parent.
#
# THE INCIDENT (project-6-os, 2026-10-28). TK-3204 is a rollout child ("Part of
# #3153"). Its plan named the parent, so the gate held it `after TK-1394
# TK-3153 TK-3198`. The parent closes only after its children merge: TK-3204
# waited 2.5 days.
#
# Driven, not grepped. The REAL lib and bin/lib/plan-blocked.sh run against hub
# build records in a scratch root. The issue body read goes through a
# `_gh_rest_field` stub that runs the lib's own jq filter on $T/body/<n>.json;
# `gh` on PATH fails the test (0 network).
#   P1  `Part of #10`, after #10 #11, #11 closed, #10 open -> released, one line.
#   P2  #11 open -> waits on BH-11 only.
#   P3  no Part-of line -> as today (waits on BH-10); parent cached `none`.
#   P4  a second tick makes 0 body reads (the cache).
#   P5  `> **Part of #10**`, `Part of: #10` -> released.
#   P6  `Part of the fix for #10`, `Blocked-by: #10`, `Part of #100` -> waits.
#   P8  an unreadable body -> waits, nothing cached, one say line.
#   P9  a class line cached before the fix (the TK-3204 shape) -> released.
#   G   0 real gh calls.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/plan-blocked-stop-parent.bh-8839-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

LIB="$DIR/bin/lib/plan-blocked-stop.sh"
H="$T/h"; mkdir -p "$H/bin" "$H/builds" "$T/fakebin" "$T/q" "$T/st" "$T/body"
scratch_install_closure bin/transcript-scrub.sh "$H" >/dev/null || { echo "FAIL: cannot install bin/transcript-scrub.sh"; exit 1; }
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$2" in repo) echo o/r ;; *) echo - ;; esac
SH
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$REALGH"
exit 1
SH
chmod +x "$H/bin/fleet-conf.sh" "$T/fakebin/gh"

NOW=1791640000
rec() { # rec <key> <plan line...> — one PLAN_BLOCKED hub record, 600 s old
  local k="$1" d; shift
  d="$H/builds/pool-bh-$k-202610281000"; mkdir -p "$d"
  printf 'PLAN_BLOCKED /root/harness/builds/x-%s/plan.md\n' "$k" > "$d/RESULT"
  printf '%s\n' "$@" > "$d/plan.md"
  touch -d "@$((NOW - 600))" "$d/RESULT"
}
recd() { printf '%s' "$H/builds/pool-bh-$1-202610281000"; }
issue() { printf '%s\n' "$2" > "$T/st/$1"; }
body() { jq -n --arg b "$2" '{body: $b}' > "$T/body/$1.json"; rm -f "$T/body/$1.rc"; }
GATE() { # GATE <key> -> rc of pbs_stop_check bh <key> <n>
  local k="$1"
  ( export HARNESS="$H" PBS_NOW="$NOW" REALGH="$T/realgh.log" PATH="$T/fakebin:$PATH"
    say() { printf '%s\n' "$*" >> "$T/say.log"; }
    # shellcheck disable=SC1090,SC1091
    . "$DIR/bin/lib/plan-blocked.sh" || exit 9
    # shellcheck disable=SC1090,SC1091
    . "$DIR/bin/lib/tracker.sh" || exit 9
    tracker_adapter() { echo github-issues; }
    _gh_rest_field() { printf 'field %s\n' "$1" >> "$T/gh.log"
      case "$1" in
        repos/o/r/issues/*)
          local n="${1##*/}" rc s
          rc=$(cat "$T/body/$n.rc" 2>/dev/null || echo 0); [ "$rc" = 0 ] || return "$rc"
          [ -f "$T/body/$n.json" ] || return 44
          s=$(jq -er "$2" "$T/body/$n.json" 2>/dev/null) && [ -n "$s" ] || return 75
          printf '%s\n' "$s" ;;
        *) return 75 ;;
      esac; }
    gh_rest_issue_state() { printf 'state %s\n' "$2" >> "$T/gh.log"; cat "$T/st/$2" 2>/dev/null || echo open; }
    gh_rest_comment() { printf 'comment %s\n' "$*" >> "$T/gh.log"; return 0; }
    gh_rest() { printf 'rest %s\n' "$*" >> "$T/gh.log"; return 0; }
    _pb_answers_since() { echo 0; }
    # shellcheck disable=SC1090
    . "$LIB" || exit 9
    pbs_stop_check bh "$k" "${k#BH-}" "$T/q/$k.json" )
}
cnt() { local c; c=$(grep -c -- "$2" "$1" 2>/dev/null); echo "${c:-0}"; }
reset() {
  for d in "$H"/builds/*/; do [ -d "$d" ] && scratch_rm "${d%/}"; done
  rm -f "$T"/st/* "$T"/body/* "$T/gh.log" "$T/say.log"
}
PLAN="BLOCKED: waits on #10 and #11"

# P1 the parent is dropped; the other key is closed -> released.
reset; issue 10 open; issue 11 closed; body 9501 $'Part of #10\nOrder: 1 of 2'
rec BH-9501 "$PLAN"
GATE BH-9501; R=$?
[ "$R" = 0 ] && ok || bad "P1 the parent BH-10 must not hold the key (rc $R): $(cat "$T/say.log" 2>/dev/null)"
[ -e "$(recd BH-9501)/plan-blocked.released" ] && ok || bad "P1 no plan-blocked.released"
[ "$(cat "$(recd BH-9501)/plan-blocked.after" 2>/dev/null)" = "After: BH-11" ] && ok || bad "P1 the After: file must name BH-11 only: $(cat "$(recd BH-9501)/plan-blocked.after" 2>/dev/null)"
[ "$(cnt "$T/say.log" "^BH-9501: BH-10 is this ticket's rollout parent — not waited on$")" = 1 ] && ok || bad "P1 want one drop line: $(cat "$T/say.log" 2>/dev/null)"
[ "$(cnt "$T/gh.log" '^state 10$')" = 0 ] && ok || bad "P1 the parent's state must not be read: $(cat "$T/gh.log")"
grep -q "^RELEASED BH-9501: PLAN_BLOCKED after BH-11 — all closed$" "$T/say.log" 2>/dev/null && ok || bad "P1 no RELEASED line on BH-11: $(cat "$T/say.log" 2>/dev/null)"

# P2 the other key is open -> waits on BH-11 only.
reset; issue 10 open; issue 11 open; body 9502 'Part of #10'
rec BH-9502 "$PLAN"
GATE BH-9502; R=$?
[ "$R" = 1 ] && ok || bad "P2 BH-11 open: refused (rc $R)"
grep -q "^skipping BH-9502: PLAN_BLOCKED after BH-11 — waits, no machine (BH-11 open)$" "$T/say.log" 2>/dev/null && ok || bad "P2 must wait on BH-11 only: $(cat "$T/say.log" 2>/dev/null)"
# P4 the second tick reads no body.
B1=$(cnt "$T/gh.log" '^field repos/o/r/issues/')
GATE BH-9502 >/dev/null; B2=$(cnt "$T/gh.log" '^field repos/o/r/issues/')
[ "$B1" = 1 ] && [ "$B2" = 1 ] && ok || bad "P4 the parent must be cached: body reads $B1 then $B2"
[ "$(head -1 "$(recd BH-9502)/plan-blocked.parent" 2>/dev/null)" = 10 ] && ok || bad "P4 plan-blocked.parent must hold 10"

# P3 no Part-of line -> as today.
reset; issue 10 open; issue 11 closed; body 9503 'Fix the widget.'
rec BH-9503 "$PLAN"
GATE BH-9503; R=$?
[ "$R" = 1 ] && grep -q "skipping BH-9503: PLAN_BLOCKED after BH-10 BH-11 — waits, no machine (BH-10 open)" "$T/say.log" && ok || bad "P3 no parent: waits on BH-10 as today (rc $R): $(cat "$T/say.log" 2>/dev/null)"
[ "$(head -1 "$(recd BH-9503)/plan-blocked.parent" 2>/dev/null)" = none ] && ok || bad "P3 plan-blocked.parent must be none"
GATE BH-9503 >/dev/null; R=$?
[ "$R" = 1 ] && [ "$(cnt "$T/gh.log" '^field repos/o/r/issues/')" = 1 ] && ok || bad "P3 none round-trips: rc $R, body reads $(cnt "$T/gh.log" '^field repos/o/r/issues/')"

# P5 / P5b other parent line shapes drop the parent.
i=0
for b in $'Intro.\r\n> **Part of #10**' 'Part of: #10'; do
  i=$((i + 1)); k="BH-955$i"
  reset; issue 10 open; issue 11 closed; body "${k#BH-}" "$b"
  rec "$k" "$PLAN"
  GATE "$k"; R=$?
  [ "$R" = 0 ] && [ -e "$(recd "$k")/plan-blocked.released" ] && ok || bad "P5 '$b' names the parent: released (rc $R)"
done

# P6 / P6b / P7 a non-parent #N is never dropped.
i=0
for b in 'Part of the fix for #10' 'Blocked-by: #10' 'Part of #100' 'See also: Part of #10 in text'; do
  i=$((i + 1)); k="BH-956$i"
  reset; issue 10 open; issue 11 closed; issue 100 open; body "${k#BH-}" "$b"
  rec "$k" "$PLAN"
  GATE "$k"; R=$?
  [ "$R" = 1 ] && grep -q "(BH-10 open)" "$T/say.log" && ok || bad "P6 '$b' is not the parent of BH-10: still waits (rc $R): $(cat "$T/say.log" 2>/dev/null)"
  grep -q "rollout parent" "$T/say.log" && bad "P6 '$b' must drop nothing" || ok
done

# P8 an unreadable body: waits, nothing cached, one say line, retried next tick.
reset; issue 10 open; issue 11 closed; body 9508 'Part of #10'; echo 75 > "$T/body/9508.rc"
rec BH-9508 "$PLAN"
GATE BH-9508; R=$?
[ "$R" = 1 ] && ok || bad "P8 an unreadable body must not drop the key (rc $R)"
[ ! -e "$(recd BH-9508)/plan-blocked.parent" ] && ok || bad "P8 an unreadable body must cache nothing"
[ "$(cnt "$T/say.log" "^BH-9508: the body of #9508 could not be read — its rollout parent is not known this tick$")" = 1 ] && ok || bad "P8 want one could-not-be-read line: $(cat "$T/say.log" 2>/dev/null)"
rm -f "$T/body/9508.rc"; GATE BH-9508; R=$?
[ "$R" = 0 ] && ok || bad "P8 the next readable tick drops the parent (rc $R)"

# P9 a class line cached before the fix (TK-3204: after TK-1394 TK-3153 TK-3198).
reset; issue 1394 closed; issue 10 open; issue 11 closed; body 9509 'Part of #10'
rec BH-9509 "BLOCKED: waits on #1394, #10 and #11"
echo "after BH-1394 BH-10 BH-11" > "$(recd BH-9509)/plan-blocked.class"
GATE BH-9509; R=$?
[ "$R" = 0 ] && [ -e "$(recd BH-9509)/plan-blocked.released" ] && ok || bad "P9 a precached class with the parent: released (rc $R): $(cat "$T/say.log" 2>/dev/null)"
grep -q "^RELEASED BH-9509: PLAN_BLOCKED after BH-1394 BH-11 — all closed$" "$T/say.log" && ok || bad "P9 RELEASED names the filtered list: $(cat "$T/say.log")"

# G nothing reached a real GitHub client.
[ ! -s "$T/realgh.log" ] && ok || bad "G a real gh call was made: $(cat "$T/realgh.log")"

echo "plan-blocked-stop-parent.bh-8839: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
