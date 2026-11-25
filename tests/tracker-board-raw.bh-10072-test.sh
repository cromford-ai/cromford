#!/bin/bash
# tests/tracker-board-raw.bh-10072-test.sh — the two raw board reads of the
# tracker board adapter (bin/lib/tracker/board.sh) that
# bin/lib/flow-agent/collect.sh now uses instead of its own curl (BH-10072),
# and the optional TRK_BOARD_MAX_TIME context of _trk_board_curl.
#
# A `curl` stub on PATH writes its argv (one arg per line, then `--`) to
# $T/curl.log, prints a fixture body and exits $STUB_RC. No network.
#
#   B1  trk_board_boards_raw: url, --max-time 30, token header, body, rc 0
#   B2  TRK_BOARD_MAX_TIME=7 → --max-time 7; abc, 0, -3, empty → 30
#   B3  trk_board_tickets_raw board-1: url /boards/board-1/tickets
#   B4  refused ids (empty, a/b, a b, ../x): rc 1, 0 calls; b_1.x:2-3 sent
#   B5  TRK_BOARD_BASE empty: both verbs rc 1, 0 calls
#   B6  curl rc 22: both verbs rc 22
#   B7  TRK_DRY=1 in the caller: both verbs still send, no DRYRUN line
#   B8  TRK_LOG names the token variable, never the token value
#   B9  _trk_board_curl, TRK_BOARD_MAX_TIME unset: log line unchanged
#   B10 collect.sh has no non-comment line with curl and /boards or /tickets
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$2] got [$3]"; fi; }
has() { if grep -qF -- "$2" <<<"$3"; then ok; else bad "$1: [$2] not in [$3]"; fi; }

mkdir -p "$T/stub"
cat > "$T/stub/curl" <<'STUB'
#!/bin/bash
{ for a in "$@"; do printf '%s\n' "$a"; done; printf -- '--\n'; } >> "$CURL_LOG"
printf '%s' '{"fixture":"body-10072"}'
exit "${STUB_RC:-0}"
STUB
chmod +x "$T/stub/curl"
export CURL_LOG="$T/curl.log"

# run <shell snippet> — a fresh subshell with the seam loaded and the context set;
# prints the snippet's stdout, then `rc=<n>`.
run() {
  : > "$CURL_LOG"
  ( PATH="$T/stub:$PATH"
    unset TRK_BOARD_MAX_TIME TRK_LOG TRK_DRY TRK_ERR
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/tracker.sh" || exit 9
    tracker_load board || exit 9
    TRK_BOARD_BASE=http://b/x TRK_BOARD_TOKEN=tok-b1 TRK_BOARD_TOKEN_VAR=BOARD_TOK
    eval "$1"; echo "rc=$?" )
}
calls() { grep -c -- '^--$' "$CURL_LOG" 2>/dev/null || true; }
argv()  { tr '\n' ' ' < "$CURL_LOG"; }

# B1
out=$(run 'trk_board_boards_raw')
eq  "B1 body and rc" $'{"fixture":"body-10072"}rc=0' "$out"
has "B1 url" " http://b/x/boards --" "$(argv)"
has "B1 max-time 30" "--max-time 30 " "$(argv)"
has "B1 token header" "Authorization: Bearer tok-b1" "$(argv)"
eq  "B1 one call" 1 "$(calls)"

# B2
run 'TRK_BOARD_MAX_TIME=7; trk_board_boards_raw' >/dev/null
has "B2 max-time 7" "--max-time 7 " "$(argv)"
for v in abc 0 -3 ""; do
  run "TRK_BOARD_MAX_TIME='$v'; trk_board_boards_raw" >/dev/null
  has "B2 max-time [$v] falls back to 30" "--max-time 30 " "$(argv)"
done

# B3
out=$(run 'trk_board_tickets_raw board-1')
eq  "B3 body and rc" $'{"fixture":"body-10072"}rc=0' "$out"
has "B3 url" " http://b/x/boards/board-1/tickets --" "$(argv)"

# B4
for id in "" "a/b" "a b" "../x"; do
  out=$(run "trk_board_tickets_raw '$id'")
  eq "B4 id [$id] refused" "rc=1" "$out"
  eq "B4 id [$id] no call" 0 "$(calls)"
done
run 'trk_board_tickets_raw b_1.x:2-3' >/dev/null
has "B4 near miss b_1.x:2-3 sent" " http://b/x/boards/b_1.x:2-3/tickets --" "$(argv)"

# B5
eq "B5 boards no base" "rc=1" "$(run 'TRK_BOARD_BASE=""; trk_board_boards_raw')"
eq "B5 boards no call" 0 "$(calls)"
eq "B5 tickets no base" "rc=1" "$(run 'TRK_BOARD_BASE=""; trk_board_tickets_raw board-1')"
eq "B5 tickets no call" 0 "$(calls)"

# B6
export STUB_RC=22
has "B6 boards rc 22" "rc=22" "$(run 'trk_board_boards_raw')"
has "B6 tickets rc 22" "rc=22" "$(run 'trk_board_tickets_raw board-1')"
export STUB_RC=0

# B7
out=$(run 'TRK_DRY=1; trk_board_boards_raw')
eq "B7 boards sent under TRK_DRY" 1 "$(calls)"
if grep -q DRYRUN <<<"$out"; then bad "B7 boards printed DRYRUN"; else ok; fi
out=$(run 'TRK_DRY=1; trk_board_tickets_raw board-1')
eq "B7 tickets sent under TRK_DRY" 1 "$(calls)"
if grep -q DRYRUN <<<"$out"; then bad "B7 tickets printed DRYRUN"; else ok; fi

# B8
: > "$T/trk.log"
run "TRK_LOG='$T/trk.log'; trk_board_boards_raw; trk_board_tickets_raw board-1" >/dev/null
has "B8 log names the variable" 'Authorization: Bearer $BOARD_TOK' "$(cat "$T/trk.log")"
eq "B8 log has two lines" 2 "$(wc -l < "$T/trk.log" | tr -d ' ')"
if grep -q tok-b1 "$T/trk.log"; then bad "B8 token value in the log"; else ok; fi

# B9
: > "$T/trk9.log"
run "TRK_LOG='$T/trk9.log'; _trk_board_curl GET http://b/x/tickets/9" >/dev/null
eq "B9 default log line unchanged" \
  "curl -sS -f --max-time 30 -H \"Authorization: Bearer \$BOARD_TOK\" 'http://b/x/tickets/9'" \
  "$(cat "$T/trk9.log")"

# B10 (guarded: a missing file, or one that no longer calls the seam, fails)
has "B10 collect.sh reads boards through the seam" 'trk_board_boards_raw' "$(cat "$DIR/bin/lib/flow-agent/collect.sh" 2>/dev/null)"
has "B10 collect.sh reads tickets through the seam" 'trk_board_tickets_raw "$bid"' "$(cat "$DIR/bin/lib/flow-agent/collect.sh" 2>/dev/null)"
hits=$(grep -vE '^[[:space:]]*#' "$DIR/bin/lib/flow-agent/collect.sh" | grep -E 'curl' | grep -E '/boards|/tickets' || true)
eq "B10 collect.sh calls the board through the seam only" "" "$hits"

echo "tracker-board-raw.bh-10072: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
