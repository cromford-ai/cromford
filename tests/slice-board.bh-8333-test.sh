#!/bin/bash
# tests/slice-board.bh-8333-test.sh — a sliced in-app board ticket never
# closes as done after C0 (BH-8333).
#
# TK-360 shipped C0 of five slices, read "This ticket is closed", and moved to
# `done` with C1-C4 never filed. This suite drives the four places that fix it
# against a curl stub that plays the board (every request recorded, no
# network) and a lane-alert stub that counts pages:
#
#   R1     the reproduction: slice_remainder_parse on a cuid parent gives ok:2
#   P1-P9  the decision rule: slice_board_token (board) and the parser's edges
#   F1-F5  fc_file_board FC_KIND=slice: parentId, dependsOn, abort, fail open,
#          decompose unchanged, the slice park comment, FC_BOARD_PARK=0
#   S1-S13 slice_board_settle: switch, filed, unknown, other ticket, lock,
#          resume, page once, merged spec fetch, spec 404, transport, dry run,
#          ledger answer
#   B1-B8  bin/board-closeout.sh as a process: a SLICE master is never done
#   M1     mc_settle_merged spawns bin/slice-board-settle.sh on a board project
#   M2     mc_settle_merged into the real CLI files the slices on the board stub
#   C1     bin/slice-board-settle.sh, the CLI, end to end
#   D1     the six board triage prompts carry the rule
#
#   HARNESS_TEST_SANDBOX=1 bash tests/slice-board.bh-8333-test.sh   exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
[ -r "$DIR/bin/lib/slice-board.sh" ] || { echo "FAIL: bin/lib/slice-board.sh does not exist"; exit 1; }
[ -x "$DIR/bin/slice-board-settle.sh" ] || { echo "FAIL: bin/slice-board-settle.sh does not exist"; exit 1; }

CUID=cmvmtfpj2000k07kzd588kq7r
TOKEN=tok-FIXTURE-8333
PRURL=https://github.com/example-org/ledger-os/pull/752

# ---- the scratch harness: one in-app board project -------------------------
mkdir -p "$T/h/bin/lib" "$T/h/env" "$T/h/flags" "$T/h/logs" "$T/h/state" "$T/h/builds" "$T/stub"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
ledger-os  example-org/ledger-os  https://ledger.example  /api/board  3
CONF
cat > "$T/h/env/ledger-os.env" <<CONF
LEDGER_API_BASE=https://ledger.example
LEDGER_INTERNAL_API_TOKEN=$TOKEN
CONF
printf '#!/bin/bash\necho %s\n' "$TOKEN" > "$T/h/bin/internal-token-for.sh"
printf '#!/bin/bash\necho OK\n' > "$T/h/bin/triage-gate.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$ALERT_LOG"\nexit 0\n' > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/"*.sh
# The code under test, with every lib it sources (the stubs above are kept).
for s in bin/board-closeout.sh bin/slice-board-settle.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$T/h" >/dev/null || exit 1
done
LIB="$T/h/bin/lib"
BASE=https://ledger.example/api/board

# The board. Both request shapes reach it: the tracker adapter's
# `-X POST --data-binary @file -H Idempotency-Key:` and board-closeout's
# `-X POST -d <json>`. One line per request in $CURL_LOG: METHOD URL KEY.
cat > "$T/stub/curl" <<'SH'
#!/bin/bash
method=GET; url=""; data=""; inline=""; k=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    --data-binary) data="$2"; shift ;;
    -d) inline="$2"; shift ;;
    -H) case "$2" in Idempotency-Key:*) k="${2#Idempotency-Key: }" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
printf '%s %s %s\n' "$method" "$url" "$k" >> "$CURL_LOG"
seq=$(wc -l < "$CURL_LOG" | tr -d ' ')
body=""
[ -n "$data" ] && body=$(cat "${data#@}")
[ -n "$inline" ] && body="$inline"
[ -n "$body" ] && printf '%s' "$body" > "$CURL_BODIES/$seq.json"
pos="${k##*-}"
case "$method $url" in
  "GET "*/boards) cat "$CURL_BOARDS" ;;
  "GET "*/tickets/*)
    [ -n "${CURL_PARENT_RC:-}" ] && exit "$CURL_PARENT_RC"
    printf '{"ticket":{"id":"%s","key":"%s","priority":"high","status":"in_progress"}}\n' "${url##*/}" "${CURL_PARENT_KEY:-LG-9}" ;;
  "POST "*/boards/*/tickets)
    [ "$pos" = "${CURL_FAIL_CREATE:-x}" ] && exit 22
    if [ "$pos" = "${CURL_NO_KEY:-x}" ]; then printf '{"ticket":{"id":"cmChild0%s"}}\n' "$pos"; exit 0; fi
    printf '{"ticket":{"id":"cmChild0%s","key":"LG-10%s"}}\n' "$pos" "$pos" ;;
  "POST "*/comments) printf '{"comment":{"id":"c%s"}}\n' "$seq" ;;
  "POST "*/move)
    [ "${CURL_MOVE_REFUSE:-}" = 1 ] && { echo '{"error":"nope"}'; exit 0; }
    printf '{"ticket":{"status":"%s"}}\n' "$(printf '%s' "$body" | jq -r .toStatus)" ;;
  *) exit 22 ;;
esac
exit 0
SH
chmod +x "$T/stub/curl"
printf '[{"id":"rb-1","capabilities":["dependencies"]}]\n' > "$T/boards-cap.json"
printf '[{"id":"rb-1","capabilities":["reactions"]}]\n' > "$T/boards-nocap.json"

export PATH="$T/stub:$PATH" HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" CURL_BOARDS="$T/boards-cap.json"

# case_dir <name> — a fresh, private request log, body dir and alert log.
case_dir() {
  C="$T/case/$1"; mkdir -p "$C/bodies"
  export CURL_LOG="$C/curl.log" CURL_BODIES="$C/bodies" ALERT_LOG="$C/alerts.log"
  : > "$CURL_LOG"; : > "$ALERT_LOG"
}
creates()  { grep -c '^POST .*/boards/rb-1/tickets ' "$CURL_LOG"; }
comments() { grep -c '^POST .*/comments ' "$CURL_LOG"; }
moves()    { grep -c '^POST .*/move ' "$CURL_LOG"; }
alerts()   { grep -c . "$ALERT_LOG"; }
body_n()   { # body_n <grep pattern> <nth> -> the body of that request
  local s; s=$(grep -n "$1" "$CURL_LOG" | sed -n "${2:-1}p" | cut -d: -f1)
  [ -n "$s" ] && cat "$C/bodies/$s.json" 2>/dev/null
}

# The TK-360 plan shape: C0 merged, C1 and C2 remain, C2 after C1.
plan_c0() { # plan_c0 <file> [token]
  cat > "$1" <<EOF
# PB plan

SLICE: C0 of #${2:-$CUID}

## Why this plan builds one slice

C1 and C2 below are the child slices.

- C1: Advisor extraction. Read the advisor from the thread.
- C2: Registration (after C1). Register the new line.

## Acceptance tests

- [C1] the advisor is extracted
- [C2] a new line registers
EOF
}

# ════════════════════════════════════════════════════════════════════════════
# R1  the reproduction
# ════════════════════════════════════════════════════════════════════════════
case_dir R1
plan_c0 "$C/plan.md"
W=$(bash -c '. "$1/slice-remainder.sh"; slice_remainder_parse "$2" "$3" "$4"' _ "$LIB" "$C/plan.md" "$CUID" "$C/o.json" 2>/dev/null)
[ "$W" = "ok:2" ] && ok || bad "R1: slice_remainder_parse on a cuid parent must give ok:2 (got '$W')"
[ "$(jq -c '[.[] | .after]' "$C/o.json" 2>/dev/null)" = '[[],[1]]' ] && ok || bad "R1: C2 must carry after [1] (got $(jq -c . "$C/o.json" 2>/dev/null))"
grep -q "Remaining slice C1 of #$CUID" "$C/o.json" && ok || bad "R1: the child body names the board parent token"

# ════════════════════════════════════════════════════════════════════════════
# P1-P8  the decision rule
# ════════════════════════════════════════════════════════════════════════════
tokrc() { # tokrc <line> -> "<rc>|<token>" for ticket CUID, KEY TK-360
  printf '# p\n\n%s\n' "$1" > "$T/tok.md"
  bash -c '. "$1/slice-board.sh"; t=$(slice_board_token "$2" "$3" TK-360); echo "$?|$t"' _ "$LIB" "$T/tok.md" "$CUID"
}
[ "$(tokrc "SLICE: C0 of #$CUID")" = "0|$CUID" ] && ok || bad "P1: the PR #752 line must match (got $(tokrc "SLICE: C0 of #$CUID"))"
[ "$(tokrc "**SLICE:** C0 of #$CUID.")" = "0|$CUID" ] && ok || bad "P2: a bold SLICE line ending in a dot must match"
[ "$(tokrc "> SLICE: C2 of #TK-360")" = "0|TK-360" ] && ok || bad "P3: a quoted SLICE line naming the KEY must match"
[ "$(tokrc "**The build for THIS ticket is C1.**")" = "0|$CUID" ] && ok || bad "P4: the 'THIS ticket is C1' guard form must match as this ticket"
R=$(tokrc "No slice here."); [ "${R%%|*}" = 1 ] && ok || bad "P5: no SLICE line is rc 1 (got $R)"
for L in "SLICE: C0 of #${CUID}X" "SLICE: C0 of #cmvmtfpj" "SLICE: C0 of #TK-3600" "SLICE: C0 of #cmzzzzzz9999k07kzd588kq7r"; do
  R=$(tokrc "$L"); [ "${R%%|*}" = 2 ] && ok || bad "P6: '$L' is another ticket's SLICE line, rc 2 (got $R)"
done
for L in "SLICE: C<n> of #$CUID" "Part of #$CUID"; do
  R=$(tokrc "$L"); [ "${R%%|*}" = 1 ] && ok || bad "P7: '$L' is not a SLICE line (got $R)"
done
# The parser's edges: a token edge for a token, the numeric edge unchanged.
printf 'SLICE: C0 of #TK-3600\n\n- C1: one\n' > "$T/p7.md"
W=$(bash -c '. "$1/slice-remainder.sh"; slice_remainder_parse "$2" TK-360 "$3"' _ "$LIB" "$T/p7.md" "$T/p7.json" 2>/dev/null)
[ "$W" = "bad:no-slice-line" ] && ok || bad "P8: #TK-3600 must not match parent TK-360 (got '$W')"
for L in "SLICE: C0 of #${CUID}x" "SLICE: C0 of #TK-360-2" "SLICE: C0 of #TK-360_b"; do
  printf '%s\n\n- C1: one\n' "$L" > "$T/p7b.md"
  W=$(bash -c '. "$1/slice-remainder.sh"; slice_remainder_parse "$2" "$3" "$4"' _ "$LIB" "$T/p7b.md" "$( [ "${L#*#cm}" != "$L" ] && echo "$CUID" || echo TK-360)" "$T/p7b.json" 2>/dev/null)
  [ "$W" = "bad:no-slice-line" ] && ok || bad "P8: '$L' is a longer token, not this parent (got '$W')"
done
# P9 no ticket id (the conductor knows only the KEY): a board id token is a
# candidate for the parent read; a KEY-shaped token that is not KEY is not.
tokrc_noid() { printf '# p\n\n%s\n' "$1" > "$T/tok.md"
  bash -c '. "$1/slice-board.sh"; t=$(slice_board_token "$2" "" TK-360); echo "$?|$t"' _ "$LIB" "$T/tok.md"; }
[ "$(tokrc_noid "SLICE: C0 of #$CUID")" = "0|$CUID" ] && ok || bad "P9: with no ticket id a cuid token is a candidate, rc 0 (got $(tokrc_noid "SLICE: C0 of #$CUID"))"
[ "$(tokrc_noid "SLICE: C0 of #TK-360")" = "0|TK-360" ] && ok || bad "P9: with no ticket id the KEY token matches"
R=$(tokrc_noid "SLICE: C0 of #TK-361"); [ "${R%%|*}" = 2 ] && ok || bad "P9: with no ticket id another KEY is rc 2 (got $R)"
printf 'SLICE: C1 of #360a\n\n- C2: two\n' > "$T/p8.md"
W=$(bash -c '. "$1/slice-remainder.sh"; slice_remainder_parse "$2" 360 "$3"' _ "$LIB" "$T/p8.md" "$T/p8.json" 2>/dev/null)
[ "$W" = "ok:1" ] && ok || bad "P8: the numeric edge stays [^0-9]: #360a still matches 360 (got '$W')"
W=$(bash -c '. "$1/slice-remainder.sh"; slice_remainder_parse "$2" "a.b" "$3"' _ "$LIB" "$T/p8.md" "$T/p8b.json" 2>/dev/null)
[ "$W" = "bad:no-slice-line" ] && ok || bad "P8: a parent with a regex character is refused (got '$W')"

# ════════════════════════════════════════════════════════════════════════════
# F1-F5  fc_file_board FC_KIND=slice
# ════════════════════════════════════════════════════════════════════════════
SPEC='[{"ordinal":1,"title":"Advisor extraction","body":"Remaining slice C1.","after":[]},
       {"ordinal":2,"title":"Registration","body":"Remaining slice C2.","after":[1]}]'
fcb() { # fcb <kind> [VAR=value ...] -> rc; FC_ERROR in $C/fc_error.txt
  local kind="$1"; shift
  mkdir -p "$C/b"; printf '%s\n' "$SPEC" > "$C/b/children.json"
  env "$@" bash -c '. "$1/file-children.sh" || exit 9; . "$1/fc-board.sh" || exit 9
    FC_PROJECT=ledger-os FC_PARENT=cmParent FC_KEY=LG-9 FC_BUILD="$2/b" FC_SPEC="$2/b/children.json" FC_KIND="$3" FC_LANE=board
    fc_file_board; rc=$?; printf "%s" "${FC_ERROR:-}" > "$2/fc_error.txt"; exit $rc' _ "$LIB" "$C" "$kind"
}
case_dir F1
fcb slice FC_SLICE_BASE=0 FC_SLICE_PR="$PRURL"; RC=$?
[ "$RC" = 0 ] && ok || bad "F1: a slice filing must succeed (rc $RC: $(cat "$C/fc_error.txt"))"
[ "$(creates)" = 2 ] && ok || bad "F1: two creates (got $(creates))"
B1=$(body_n '/boards/rb-1/tickets ' 1); B2=$(body_n '/boards/rb-1/tickets ' 2)
[ "$(jq -r .parentId <<<"$B1")" = cmParent ] && ok || bad "F1: the create carries parentId = the master id (got $B1)"
[ "$(jq -r .title <<<"$B1")" = "LG-9.1: Advisor extraction" ] && ok || bad "F1: the child title is <KEY>.<C> (got $(jq -r .title <<<"$B1"))"
grep -q 'tickets slice-LG-9-1$' "$CURL_LOG" && ok || bad "F1: the idempotency key is slice-<KEY>-<n>"
[ "$(jq -c .dependsOn <<<"$B1")" = '[]' ] && ok || bad "F1: the first slice waits on no contract (got $(jq -c .dependsOn <<<"$B1"))"
# F2 dependsOn from `after`
[ "$(jq -c .dependsOn <<<"$B2")" = '["cmChild01"]' ] && ok || bad "F2: C2 after C1 gives dependsOn [id of C1] (got $(jq -c .dependsOn <<<"$B2"))"
grep -q 'Blocked-by:' <<<"$(jq -r .description <<<"$B2")" && bad "F2: a capable board carries no Blocked-by text" || ok
jq -r .description <<<"$B2" | grep -q 'Remaining slice C2 of #LG-9' && ok || bad "F2: the footer is the slice footer"
grep -qE 'DEPENDS:|CONTRACT:|imports the contract' <<<"$(jq -r .description <<<"$B2")" && bad "F2: a slice has no contract child and no DEPENDS line" || ok
CB=$(body_n '/comments ' 1)
jq -r .body <<<"$CB" | grep -q "Slice C0 is merged: <a href=\"$PRURL\">" && ok || bad "F2: the park comment is the slice comment (got $CB)"
jq -r .body <<<"$CB" | grep -q 'Not live yet: the rest of the plan' && ok || bad "F2: the park comment says what is not live"
[ "$(jq -r .toStatus "$C/b/children/move.json" 2>/dev/null)" = in_progress ] && ok || bad "F2: the master moves to in_progress"
# F2b a slice with no `after` waits on nothing: there is no contract child.
case_dir F2b
SPEC0="$SPEC"
SPEC='[{"ordinal":1,"title":"A","body":"a","after":[]},{"ordinal":2,"title":"B","body":"b","after":[1]},{"ordinal":3,"title":"C","body":"c","after":[]}]'
fcb slice FC_SLICE_BASE=0 >/dev/null
[ "$(body_n '/boards/rb-1/tickets ' 3 | jq -c .dependsOn)" = '[]' ] && ok || bad "F2b: C3 with no after has dependsOn [] (got $(body_n '/boards/rb-1/tickets ' 3 | jq -c .dependsOn))"
SPEC="$SPEC0"
# F3 a create with no key aborts, nothing posted on the master
case_dir F3
fcb slice CURL_NO_KEY=2 FC_SLICE_BASE=0; RC=$?
[ "$RC" = 1 ] && ok || bad "F3: a create with no key must abort (rc $RC)"
[ "$(comments)$(moves)" = 00 ] && ok || bad "F3: nothing is posted on the master after a failed create"
[ "$(cat "$C/b/children.txt")" = LG-101 ] && ok || bad "F3: the record holds child 1 only"
# F4 no capability: fails open, text Blocked-by, no parentId
case_dir F4
fcb slice CURL_BOARDS="$T/boards-nocap.json" FC_SLICE_BASE=0; RC=$?
[ "$RC" = 0 ] && ok || bad "F4: slice fails open on a board without dependencies (rc $RC: $(cat "$C/fc_error.txt"))"
B2=$(body_n '/boards/rb-1/tickets ' 2)
jq -e 'has("parentId") | not' <<<"$B2" >/dev/null && ok || bad "F4: no parentId on a board without dependencies"
jq -r .description <<<"$B2" | grep -q 'Blocked-by: LG-101 (hard)' && ok || bad "F4: the order rides a Blocked-by text line"
# F5 decompose unchanged; FC_BOARD_PARK=0 skips the park
case_dir F5
SPEC='[{"title":"Types","body":"The types.","contract":"src/t.ts: T","after":[]},{"title":"Server","body":"The route.","after":[]}]'
fcb decompose; RC=$?
[ "$RC" = 0 ] && ok || bad "F5: decompose still files (rc $RC)"
[ "$(jq -r .body "$C/b/children/comment.json")" = '<p>We split this one into 2 parts and filed each as its own ticket. They are built in order, and this ticket stays open as the master until they land.</p><ol><li>LG-101: Types</li><li>LG-102: Server</li></ol>' ] \
  && ok || bad "F5: the decompose park comment is byte-identical (got $(jq -r .body "$C/b/children/comment.json"))"
[ "$(moves)" = 1 ] && ok || bad "F5: decompose with FC_BOARD_PARK unset still moves the master"
case_dir F5b
SPEC='[{"ordinal":1,"title":"Advisor extraction","body":"x","after":[]}]'
fcb slice FC_BOARD_PARK=0 FC_SLICE_BASE=0; RC=$?
[ "$RC" = 0 ] && [ "$(creates)" = 1 ] && ok || bad "F5: FC_BOARD_PARK=0 still files (rc $RC, $(creates) creates)"
[ "$(comments)$(moves)" = 00 ] && ok || bad "F5: FC_BOARD_PARK=0 posts no comment and no move"
SPEC='[{"ordinal":1,"title":"Advisor extraction","body":"Remaining slice C1.","after":[]},
       {"ordinal":2,"title":"Registration","body":"Remaining slice C2.","after":[1]}]'

# ════════════════════════════════════════════════════════════════════════════
# S1-S12  slice_board_settle
# ════════════════════════════════════════════════════════════════════════════
# settle <rec|-> [ticket] [park] [VAR=value ...] -> the word; rc in $SRC
settle() {
  local rec="$1" tid="${2-$CUID}" park="${3:-1}"; shift 3 2>/dev/null || shift $#
  SW=$(env "$@" bash -c '. "$1/slice-board.sh"; slice_board_settle ledger-os LG-9 "$2" "$3" "$4" "$5" "$6"' \
    _ "$LIB" "$PRURL" "$rec" "$tid" "$park" "$T/h" 2>>"$T/settle.err"); SRC=$?
}
rec_c0() { REC="$T/h/builds/ledger-os-LG-9-$1"; mkdir -p "$REC"; plan_c0 "$REC/plan.md" "${2:-$CUID}"; }

case_dir S1; rec_c0 s1
settle "$REC" "$CUID" 1 SLICE_REMAINDER_FILE=0
[ "$SW|$SRC" = "skip:off|3" ] && ok || bad "S1: the switch off gives skip:off rc 3 (got $SW|$SRC)"
[ "$(grep -c . "$CURL_LOG")" = 0 ] && ok || bad "S1: switched off, no board call"

case_dir S2; rec_c0 s2
settle "$REC" "$CUID" 1
[ "$SW|$SRC" = "filed:LG-101,LG-102|0" ] && ok || bad "S2: filed:<keys> rc 0 (got $SW|$SRC; $(tail -3 "$T/settle.err"))"
[ "$(cat "$REC/slice-board/filed" 2>/dev/null)" = "LG-101,LG-102" ] && ok || bad "S2: the filed ledger lists both keys"
[ "$(cat "$REC/slice-board/token" 2>/dev/null)" = "$CUID" ] && ok || bad "S2: the token is recorded"
grep -q "^GET $BASE/tickets/$CUID " "$CURL_LOG" && ok || bad "S2: the parent is read by its board id"
[ "$(comments)$(moves)" = 11 ] && ok || bad "S2: park 1 posts one comment and one move (got $(comments)$(moves))"
grep -q '"done"' "$C"/bodies/*.json && bad "S2: nothing moves anything to done" || ok

case_dir S3; rec_c0 s3
settle "$REC" "$CUID" 1 CURL_PARENT_KEY=LG-77
[ "$SW|$SRC" = "unknown:parent|2" ] && ok || bad "S3: a parent whose key is not KEY gives unknown:parent rc 2 (got $SW|$SRC)"
[ "$(alerts)" = 1 ] && grep -q 'slice-board-unknown:ledger-os:LG-9:752' "$ALERT_LOG" && ok || bad "S3: one page with the unknown id ($(cat "$ALERT_LOG"))"
[ "$(creates)" = 0 ] && ok || bad "S3: nothing filed under the wrong parent"

case_dir S4; rec_c0 s4 cmzzzzzz9999k07kzd588kq7r
settle "$REC" "$CUID" 1
[ "$SW|$SRC" = "skip:other-ticket|3" ] && ok || bad "S4: another ticket's SLICE line gives skip:other-ticket (got $SW|$SRC)"
[ "$(grep -c . "$CURL_LOG")" = 0 ] && ok || bad "S4: no board call for another ticket's plan"
[ ! -e "$REC/slice-board" ] && ok || bad "S4: a skip leaves no ledger behind"

case_dir S5; rec_c0 s5; mkdir -p "$REC/slice-board"
( flock -x 8; : > "$C/held"; sleep 4 ) 8>"$REC/slice-board/.lock" &
LP=$!
for _ in $(seq 1 50); do [ -e "$C/held" ] && break; sleep 0.1; done
settle "$REC" "$CUID" 1
[ "$SW|$SRC" = "deferred:locked|1" ] && ok || bad "S5: a held lock gives deferred:locked rc 1 (got $SW|$SRC)"
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null

case_dir S6; rec_c0 s6
settle "$REC" "$CUID" 1 CURL_FAIL_CREATE=2
[ "$SW|$SRC" = "deferred:file-failed|1" ] && ok || bad "S6: a failed create gives deferred:file-failed (got $SW|$SRC)"
[ "$(cat "$REC/slice-board/children.txt")" = LG-101 ] && ok || bad "S6: the record holds child 1"
[ "$(comments)$(moves)" = 00 ] && ok || bad "S6: nothing posted on the master before every child exists"
grep -q 'slice-board-failed:ledger-os:LG-9:752' "$ALERT_LOG" && ok || bad "S6: one failed page"
: > "$CURL_LOG"
settle "$REC" "$CUID" 1
[ "$SW|$SRC" = "filed:LG-101,LG-102|0" ] && ok || bad "S6: the rerun files the rest (got $SW|$SRC)"
[ "$(creates)" = 1 ] && grep -q 'tickets slice-LG-9-2$' "$CURL_LOG" && ok || bad "S6: the rerun creates child 2 only (got $(creates))"

case_dir S7; REC="$T/h/builds/ledger-os-LG-9-s7"; mkdir -p "$REC"
printf '# p\n\nSLICE: C0 of #%s\n\nNo list of slices here.\n' "$CUID" > "$REC/plan.md"
settle "$REC" "$CUID" 1; W1="$SW|$SRC"
settle "$REC" "$CUID" 1
[ "$W1" = "unknown:none|2" ] && [ "$SW|$SRC" = "unknown:none|2" ] && ok || bad "S7: no remainder is unknown, twice (got $W1 then $SW|$SRC)"
[ "$(alerts)" = 1 ] && ok || bad "S7: two settles of one unknown record page once (got $(alerts))"
[ "$(creates)$(moves)" = 00 ] && ok || bad "S7: unknown files and moves nothing"

# S8-S9 no plan in the record: the merged spec through sco_plan_fetch.
PLAN64=$(plan_c0 /dev/stdout | base64 | tr -d '\n')
settle_remote() { # settle_remote <spec-rc> [VAR=value ...]
  local src="$1"; shift
  SW=$(env "$@" bash -c '. "$1/slice-board.sh"; . "$1/slice-closeout.sh"
    P64="$4"; SRC_RC="$5"
    gh_rest() { printf "%s\n" "$*" >> "$CURL_LOG.gh"
      case "$2" in
        */pulls/752) printf "{\"title\":\"LG-9: iMessage W1\",\"merged_at\":\"2026-10-24T23:00:00Z\",\"merge_commit_sha\":\"abc123\",\"body\":\"SLICE: C0\"}" ;;
        */contents/.harness/specs/LG-9/plan.md*) [ "$SRC_RC" = 0 ] || return "$SRC_RC"; printf "{\"encoding\":\"base64\",\"content\":\"%s\"}" "$P64" ;;
        *) return 44 ;;
      esac; }
    slice_board_settle ledger-os LG-9 "$2" - "$3" 1 "$6"' _ "$LIB" "$PRURL" "$CUID" "$PLAN64" "$src" "$T/h" 2>>"$T/settle.err"); SRC=$?
}
case_dir S8; rm -rf "$T/h/state/slice-board"
settle_remote 0
[ "$SW|$SRC" = "filed:LG-101,LG-102|0" ] && ok || bad "S8: the merged spec is fetched and filed (got $SW|$SRC; $(tail -3 "$T/settle.err"))"
grep -q 'contents/.harness/specs/LG-9/plan.md?ref=abc123' "$CURL_LOG.gh" && ok || bad "S8: the spec is read at the merge sha"
[ -s "$T/h/state/slice-board/ledger-os-LG-9-pr752/filed" ] && ok || bad "S8: with no record the ledger is state/slice-board/<project>-<KEY>-pr<n>"
case_dir S9; rm -rf "$T/h/state/slice-board"
settle_remote 44
[ "$SW|$SRC" = "skip:no-plan|3" ] && ok || bad "S9: a spec 404 gives skip:no-plan (got $SW|$SRC)"
[ ! -e "$T/h/state/slice-board/ledger-os-LG-9-pr752" ] && ok || bad "S9: a skip leaves no state ledger"

case_dir S10; rec_c0 s10
settle "$REC" "$CUID" 1 CURL_PARENT_RC=7
[ "$SW|$SRC" = "deferred:parent-read|1" ] && ok || bad "S10: a transport error gives deferred:parent-read (got $SW|$SRC)"
[ "$(alerts)" = 0 ] && [ ! -e "$REC/slice-board/unknown-paged" ] && ok || bad "S10: a transport error pages nothing and is not terminal"
settle "$REC" "$CUID" 1 CURL_PARENT_RC=22
[ "$SW|$SRC" = "unknown:parent|2" ] && ok || bad "S10: an HTTP error on the parent is unknown:parent (got $SW|$SRC)"

case_dir S11; rec_c0 s11
settle "$REC" "$CUID" 1 FILE_CHILDREN_DRY_RUN=1
[ "$SW|$SRC" = "skip:dry-run|3" ] && ok || bad "S11: a dry run gives skip:dry-run (got $SW|$SRC)"
grep -q '^POST' "$CURL_LOG" && bad "S11: a dry run sends no write" || ok

case_dir S12; rec_c0 s12
settle "$REC" "$CUID" 1; : > "$CURL_LOG"
settle "$REC" "$CUID" 1
[ "$SW|$SRC" = "filed:LG-101,LG-102|0" ] && ok || bad "S12: a second settle answers from the ledger (got $SW|$SRC)"
[ "$(grep -c . "$CURL_LOG")" = 0 ] && ok || bad "S12: a second settle makes no board call"

# S13 no ticket id: the plan's cuid is the id, and the parent read decides.
case_dir S13; rec_c0 s13
settle "$REC" "" 1
[ "$SW|$SRC" = "filed:LG-101,LG-102|0" ] && ok || bad "S13: no ticket id, the right KEY files (got $SW|$SRC; $(tail -3 "$T/settle.err"))"
grep -q "^GET $BASE/tickets/$CUID " "$CURL_LOG" && ok || bad "S13: the parent is read by the plan's cuid"
case_dir S13b; rec_c0 s13b
settle "$REC" "" 1 CURL_PARENT_KEY=LG-77
[ "$SW|$SRC" = "unknown:parent|2" ] && [ "$(creates)" = 0 ] && ok || bad "S13: no ticket id, a parent with another key files nothing (got $SW|$SRC, $(creates) creates)"

# ════════════════════════════════════════════════════════════════════════════
# B1-B8  bin/board-closeout.sh, the process
# ════════════════════════════════════════════════════════════════════════════
closeout() { # closeout <rec> [VAR=value ...] -> stdout in $OUT, rc in $BRC
  local rec="$1"; shift
  OUT=$(env "$@" "$T/h/bin/board-closeout.sh" ledger-os "$CUID" LG-9 "$rec" 2>>"$T/closeout.err"); BRC=$?
}
brec() { # brec <name> <result-line> [plan token|none]
  rec_c0 "$1" "${3:-$CUID}"
  [ "${3:-}" = none ] && printf '# p\n\n## QA screens\n- /clients\n' > "$REC/plan.md"
  echo "$2" > "$REC/RESULT"
  printf -- '- the inbound ledger\n' > "$REC/what.txt"
}
moved_to() { body_n '/move ' 1 | jq -r .toStatus; }
cbody() { body_n '/comments ' 1 | jq -r .body; }

case_dir B1; brec b1 "PR_MERGED $PRURL"
closeout "$REC"
[ "$BRC" = 0 ] && ok || bad "B1: a merged slice closes out (rc $BRC; $(tail -3 "$T/closeout.err"))"
[ "$OUT" = "POSTED ledger-os/LG-9 -> in_progress (slice C0; children LG-101,LG-102)" ] && ok || bad "B1: the caller is told where it landed (got '$OUT')"
[ "$(moved_to)" = in_progress ] && ok || bad "B1: PR_MERGED + SLICE moves the master to in_progress (got $(moved_to))"
grep -q '"toStatus":"done"' "$C"/bodies/*.json && bad "B1: a SLICE master is never moved to done" || ok
[ "$(comments)" = 1 ] && ok || bad "B1: exactly one comment (got $(comments))"
cbody | grep -q 'Slice C0 of this ticket is merged and on its way to production.' && ok || bad "B1: the lead names the slice"
cbody | grep -q 'Not live yet: the rest of the plan.' && ok || bad "B1: the comment says what is not live"
cbody | grep -q '<li>LG-101: LG-9.1: Advisor extraction</li>\|<li>LG-101: Advisor extraction</li>' && ok || bad "B1: the comment names child LG-101 and its title ($(cbody))"
cbody | grep -q '<li>LG-102: ' && ok || bad "B1: the comment names child LG-102"
cbody | grep -q "pull/752" && ok || bad "B1: the comment links the PR"
cbody | grep -q 'Nobody drove the live app by hand' && ok || bad "B1: the VERIFIED line is kept"
# B2 order: every create, then the comment, then the move.
ORDER=$(grep -E '^POST ' "$CURL_LOG" | sed -E 's#^POST [^ ]*/(boards/rb-1/tickets|comments|move) .*#\1#' | paste -sd' ' -)
[ "$ORDER" = "boards/rb-1/tickets boards/rb-1/tickets comments move" ] && ok || bad "B2: creates, then comment, then move (got $ORDER)"

case_dir B3; brec b3 "PR_MERGED $PRURL"
closeout "$REC" CURL_PARENT_KEY=LG-77
[ "$BRC" = 0 ] && [ "$(moved_to)" = in_progress ] && ok || bad "B3: unknown still posts and moves to in_progress (rc $BRC, $(moved_to))"
cbody | grep -q 'not filed yet' && ok || bad "B3: the comment says the rest is not filed yet"
grep -q '<li>LG-10' <<<"$(cbody)" && bad "B3: no child is named when none was filed" || ok
[ "$(alerts)" = 1 ] && ok || bad "B3: the helper paged once (got $(alerts))"

case_dir B4; brec b4 "PR_MERGED $PRURL"
closeout "$REC" CURL_MOVE_REFUSE=1
[ "$BRC" = 0 ] && [ "$OUT" = "POSTED ledger-os/LG-9 (status not moved)" ] && ok || bad "B4: a refused move says so (rc $BRC, '$OUT')"

case_dir B5; brec b5 "PR_MERGED $PRURL"
closeout "$REC" CURL_FAIL_CREATE=1
[ "$BRC" = 1 ] && ok || bad "B5: a deferred filer exits 1 so the sweep carries it (rc $BRC)"
[ "$(comments)$(moves)" = 00 ] && ok || bad "B5: nothing posted while the children are not filed"

case_dir B6; brec b6 "PR_MERGED $PRURL"
closeout "$REC" SLICE_REMAINDER_FILE=0
[ "$BRC" = 0 ] && [ "$(moved_to)" = in_progress ] && ok || bad "B6: switched off, a SLICE master still goes to in_progress (rc $BRC, $(moved_to))"
cbody | grep -q 'not filed yet' && ok || bad "B6: the comment says the rest is not filed yet"
[ "$(creates)" = 0 ] && ok || bad "B6: switched off, nothing is filed"

case_dir B7; brec b7 "PR_CREATED $PRURL"
closeout "$REC"
[ "$BRC" = 0 ] && [ "$(moved_to)" = review ] && ok || bad "B7: PR_CREATED + SLICE stays review (rc $BRC, $(moved_to))"
cbody | grep -q 'This PR is slice C0 of the plan. When it merges, we file the remaining slices' && ok || bad "B7: the comment says the rest is filed at merge"
[ "$(creates)" = 0 ] && ok || bad "B7: nothing is filed before the merge"

case_dir B8; brec b8 "PR_MERGED $PRURL" none
closeout "$REC"
[ "$BRC" = 0 ] && [ "$OUT" = "POSTED ledger-os/LG-9 -> done" ] && ok || bad "B8: no SLICE line still goes to done as today (rc $BRC, '$OUT')"
cbody | grep -q 'This is merged and on its way to production.' && ok || bad "B8: today's lead"

# ════════════════════════════════════════════════════════════════════════════
# C1  bin/slice-board-settle.sh, the CLI the conductor spawns
# ════════════════════════════════════════════════════════════════════════════
case_dir C1; rec_c0 c1
OUT=$("$T/h/bin/slice-board-settle.sh" ledger-os LG-9 "$PRURL" "$REC" --ticket "$CUID" --park 1 2>>"$T/settle.err"); RC=$?
[ "$OUT|$RC" = "filed:LG-101,LG-102|0" ] && ok || bad "C1: the CLI prints the word and exits with its rc (got $OUT|$RC)"
[ "$(moves)" = 1 ] && [ "$(moved_to)" = in_progress ] && ok || bad "C1: --park 1 moves the master to in_progress"
"$T/h/bin/slice-board-settle.sh" ledger-os LG-9 >/dev/null 2>&1; [ "$?" = 64 ] && ok || bad "C1: a short argv is usage, rc 64"

# ════════════════════════════════════════════════════════════════════════════
# M1  mc_settle_merged spawns the CLI on a board project only
# ════════════════════════════════════════════════════════════════════════════
M="$T/m"; mkdir -p "$M/bin/lib/mc" "$M/logs" "$M/state" "$M/env" "$M/flags" "$M/builds" "$T/mtmp"
for s in beat.sh deploy-request.sh; do printf '#!/bin/bash\nexit 0\n' > "$M/bin/$s"; chmod +x "$M/bin/$s"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/spawned.txt"\n' "$M" > "$M/bin/slice-board-settle.sh"; chmod +x "$M/bin/slice-board-settle.sh"
: > "$M/env/global.env"
for s in bin/lib/merge-conductor-lib.sh bin/fleet-conf.sh; do scratch_install_closure "$s" "$M" >/dev/null || exit 1; done
printf 'ledger-os example-org/ledger-os https://ledger.example /api/board 3\nproj example-org/proj - - - box-proj\n' > "$M/fleet.conf"
MREC="$M/builds/ledger-os-LG-9-202610300000"; mkdir -p "$MREC"
jq -nc --arg t "$CUID" '{ticket_id:$t,key:"LG-9",project:"ledger-os"}' > "$MREC/job.json"
(
  export HARNESS="$M" TMPDIR="$T/mtmp" FLEET_CONF="$M/fleet.conf" MC_DETACHED_DEPLOY_VERIFY=0
  # shellcheck source=/dev/null
  . "$M/bin/lib/merge-conductor-lib.sh" || exit 1
  mc_init
  mc_settle_merged "example-org/ledger-os#752" "$PRURL" ledger-os example-org/ledger-os ticket/lg-9 "$MREC" - aaaa1111 cccc3333 >/dev/null 2>&1
  mc_settle_merged "example-org/proj#9" https://github.com/example-org/proj/pull/9 proj example-org/proj ticket/x "" - aaaa1111 dddd4444 >/dev/null 2>&1
  # No record: the KEY comes from the ticket/<key>-r<n> branch.
  mc_settle_merged "example-org/ledger-os#753" https://github.com/example-org/ledger-os/pull/753 ledger-os example-org/ledger-os ticket/lg-12-r2 "" - aaaa1111 eeee5555 >/dev/null 2>&1
  # No record and no KEY in the branch: no spawn, one log line.
  mc_settle_merged "example-org/ledger-os#754" https://github.com/example-org/ledger-os/pull/754 ledger-os example-org/ledger-os fix/thing "" - aaaa1111 ffff6666 >/dev/null 2>&1
) || bad "M1: mc_settle_merged could not run"
for _ in $(seq 1 20); do [ "$(grep -c . "$M/spawned.txt" 2>/dev/null)" -ge 2 ] && break; sleep 0.3; done
sleep 0.3
grep -qxF "ledger-os LG-9 $PRURL $MREC --ticket $CUID --park 1" "$M/spawned.txt" 2>/dev/null && ok \
  || bad "M1: a board merge spawns the CLI with the board KEY, the ticket id and the record (got '$(cat "$M/spawned.txt" 2>/dev/null)')"
grep -qxF "ledger-os LG-12 https://github.com/example-org/ledger-os/pull/753 - --park 1" "$M/spawned.txt" 2>/dev/null && ok \
  || bad "M1: with no record the KEY comes from the branch (got '$(cat "$M/spawned.txt" 2>/dev/null)')"
grep -q 'example-org/ledger-os#' "$M/spawned.txt" 2>/dev/null && bad "M1: the conductor's own key is never passed as the board KEY" || ok
[ "$(grep -c . "$M/spawned.txt" 2>/dev/null)" = 2 ] && ok || bad "M1: a GitHub-Issues project and a merge with no KEY do not spawn it"
grep -q 'board slice settle spawned for LG-9' "$M/logs/merge-conductor.log" 2>/dev/null && ok || bad "M1: the conductor logs the spawn"
grep -q 'example-org/ledger-os#754 board slice settle NOT spawned' "$M/logs/merge-conductor.log" 2>/dev/null && ok || bad "M1: no KEY is one log line"

# ════════════════════════════════════════════════════════════════════════════
# M2  mc_settle_merged into the REAL CLI against the board stub
# ════════════════════════════════════════════════════════════════════════════
case_dir M2
for s in beat.sh deploy-request.sh; do [ -e "$T/h/bin/$s" ] || { printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s"; chmod +x "$T/h/bin/$s"; }; done
scratch_install_closure bin/lib/merge-conductor-lib.sh "$T/h" >/dev/null || exit 1
[ -e "$T/h/env/global.env" ] || : > "$T/h/env/global.env"
mkdir -p "$T/m2tmp"
rec_c0 m2
jq -nc --arg t "$CUID" '{ticket_id:$t,key:"LG-9",project:"ledger-os"}' > "$REC/job.json"
(
  export HARNESS="$T/h" TMPDIR="$T/m2tmp" MC_DETACHED_DEPLOY_VERIFY=0
  # shellcheck source=/dev/null
  . "$T/h/bin/lib/merge-conductor-lib.sh" || exit 1
  mc_init
  mc_settle_merged "example-org/ledger-os#752" "$PRURL" ledger-os example-org/ledger-os ticket/lg-9 "$REC" - aaaa1111 cccc3333 >/dev/null 2>&1
) || bad "M2: mc_settle_merged could not run"
for _ in $(seq 1 60); do [ -s "$REC/slice-board/filed" ] && break; sleep 0.25; done
[ "$(cat "$REC/slice-board/filed" 2>/dev/null)" = "LG-101,LG-102" ] && ok \
  || bad "M2: the conductor path files the remaining slices (got '$(cat "$REC/slice-board/filed" 2>/dev/null)'; $(tail -3 "$T/h/logs/slice-board.log" 2>/dev/null))"
[ "$(creates)" = 2 ] && ok || bad "M2: two child creates on the board (got $(creates))"

# ════════════════════════════════════════════════════════════════════════════
# D1  the six board triage prompts
# ════════════════════════════════════════════════════════════════════════════
for p in project-1 project-2 project-3 project-4 project-8 project-9; do
  grep -q 'slice-board-settle.sh' "$DIR/prompts/$p.md" && grep -q 'A SLICE result is never `done`' "$DIR/prompts/$p.md" \
    && ok || bad "D1: prompts/$p.md must carry the SLICE results-sweep rule"
  if grep -q 'go straight to `done` once the what-shipped comment is posted' "$DIR/prompts/$p.md"; then
    grep -q 'go straight to `done` once the what-shipped comment is posted (except a SLICE build' "$DIR/prompts/$p.md" \
      && ok || bad "D1: prompts/$p.md: the system-actor exception must except a SLICE build"
  fi
done

echo "slice-board.bh-8333: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
