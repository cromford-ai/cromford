#!/bin/bash
# tests/ticket-ref-regex.bh-7922-test.sh — BH-7922: the one shared ticket-ref
# regex and its two line parsers (bin/lib/ticket-ref.sh), tested alone.
#
#   R1-R7   ticket_ref_valid accepts #12, CRO-12, PROJ-7, SCRUM-1, A1_B-3,
#           #7921, and a ref read from `Blocked-by: CRO-12 (hard)`
#   R8-R14  it rejects 12, CRO 12, cro-12, CRO-, -12, #, #12a, CRO-12-3, ""
#   B1-B8   ticket_ref_blocked_by: (hard)/(soft), a comma list, and the
#           adversarial lines (see CRO-12, indented, a bad item, cro-12)
#   P1-P5   ticket_ref_part_of: Part of #7916 / CRO-12; Not Part of, indented,
#           trailing words refused
#   N1-N3   ticket_ref_num #12 -> 12, CRO-12 -> CRO-12, 12 -> rc 1
#   S1      sourcing twice prints nothing and keeps the functions; set -u safe
# Pure bash, no network, no state.
#   HARNESS_TEST_SANDBOX=1 bash tests/ticket-ref-regex.bh-7922-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# S1: sourcing prints nothing, twice
o=$( set -u; . "$DIR/bin/lib/ticket-ref.sh" && . "$DIR/bin/lib/ticket-ref.sh" && ticket_ref_valid CRO-12 && echo LOADED 2>&1 )
[ "$o" = LOADED ] && ok || bad "S1 sourcing twice under set -u is inert and the lib works (got '$o')"
# shellcheck source=bin/lib/ticket-ref.sh
. "$DIR/bin/lib/ticket-ref.sh" || { echo "FAIL: bin/lib/ticket-ref.sh did not source"; exit 1; }
o=$(. "$DIR/bin/lib/ticket-ref.sh" 2>&1)
[ -z "$o" ] && ok || bad "S1 a source prints nothing (got '$o')"

# R1-R7 accepted
for r in '#12' CRO-12 PROJ-7 SCRUM-1 A1_B-3 '#7921'; do
  ticket_ref_valid "$r" && ok || bad "R accept $r"
done
[ "$(printf 'Blocked-by: CRO-12 (hard)\n' | ticket_ref_blocked_by)" = CRO-12 ] && ok || bad "R7 Blocked-by: CRO-12 (hard) yields CRO-12"
# R8-R14 rejected
for r in 12 'CRO 12' cro-12 CRO- -12 '#' '#12a' CRO-12-3 '' ' CRO-12' 'CRO-12 ' 'x#12'; do
  ticket_ref_valid "$r" && bad "R reject '$r'" || ok
done
# the ERE is usable on its own with grep -E
printf 'see CRO-12 and #4\n' | grep -oE "$TICKET_REF_ERE" | tr '\n' ' ' | grep -qx 'CRO-12 #4 ' && ok || bad "R the ERE finds refs with grep -E"

# B1-B8 Blocked-by
bb() { printf '%b' "$1" | ticket_ref_blocked_by | tr '\n' ' '; }
[ "$(bb 'Blocked-by: #7921 (hard)\n')" = '#7921 ' ] && ok || bad "B1 #7921 (hard): $(bb 'Blocked-by: #7921 (hard)\n')"
[ "$(bb 'Blocked-by: CRO-13 (soft)\nBlocked-by: CRO-14\n')" = 'CRO-13 CRO-14 ' ] && ok || bad "B2 two lines"
[ "$(bb 'Blocked-by: #12 (hard), #13 (hard)\n')" = '#12 #13 ' ] && ok || bad "B3 a comma list: $(bb 'Blocked-by: #12 (hard), #13 (hard)\n')"
[ "$(bb 'Blocked-by: see CRO-12\n')" = '' ] && ok || bad "B4 'see CRO-12' yields nothing"
[ "$(bb '  Blocked-by: CRO-12\n')" = '' ] && ok || bad "B5 an indented line yields nothing"
[ "$(bb 'Blocked-by: CRO-12, maybe\n')" = '' ] && ok || bad "B6 one bad item drops the line"
[ "$(bb 'Blocked-by: cro-12\nBlocked-by: 12\nBlocked-by: CRO 12\n')" = '' ] && ok || bad "B7 lower case, bare number, space"
[ "$(bb 'text\r\nBlocked-by: CRO-12 (hard)\r\n')" = 'CRO-12 ' ] && ok || bad "B8 a CRLF body still reads"
[ "$(bb 'Blocked-by: CRO-12 (firm)\n')" = '' ] && ok || bad "B9 only (hard) or (soft)"
[ "$(printf 'Blocked-by: CRO-12' | ticket_ref_blocked_by)" = CRO-12 ] && ok || bad "B10 a last line with no newline"

# P1-P5 Part of
po() { printf '%b' "$1" | ticket_ref_part_of | tr '\n' ' '; }
[ "$(po '---\nPart of #7916\nOrder: 4 of 7\n')" = '#7916 ' ] && ok || bad "P1 Part of #7916"
[ "$(po 'Part of CRO-12\n')" = 'CRO-12 ' ] && ok || bad "P2 Part of CRO-12"
[ "$(po 'Not Part of CRO-12\n')" = '' ] && ok || bad "P3 Not Part of yields nothing"
[ "$(po '  Part of CRO-12\n')" = '' ] && ok || bad "P4 indented yields nothing"
[ "$(po 'Part of CRO-12 maybe\nPart of 12\nPart of cro-12\n')" = '' ] && ok || bad "P5 trailing words, bare number, lower case"

# N1-N3 ticket_ref_num
[ "$(ticket_ref_num '#12')" = 12 ] && ok || bad "N1 #12 -> 12"
[ "$(ticket_ref_num CRO-12)" = CRO-12 ] && ok || bad "N2 CRO-12 -> CRO-12"
o=$(ticket_ref_num 12); rc=$?
[ "$rc" = 1 ] && [ -z "$o" ] && ok || bad "N3 12 is rc 1 with nothing printed (rc=$rc out=$o)"

echo "ticket-ref-regex.bh-7922: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
