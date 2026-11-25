#!/bin/bash
# tests/secret-mask.bh-9799-test.sh — BH-9799 T0: bin/lib/token-redact.sh masks
# a Sentry token (`sntry<letter>_` + 20 or more chars) as `<redacted:sentry-token>`
# and a PostHog key (`ph<letter>_` + 20 or more chars) as `<redacted:posthog-key>`,
# with a left boundary so a word like `graphx_...` is not touched.
#
#   M1-M6   the must-mask shapes (line start, after Bearer, inside a JSON string)
#   M7-M12  near misses stay unchanged
#   M13     token_redact_file on a ticket body file with both shapes
#   M14     the sentry-triage lane log: _st_log writes the line masked
#
# Every fake value is built at run time and carries the word fixture. No
# key-shaped literal is in this file. No network, nothing outside $T.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/secret-mask.bh-9799-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

rep() { printf "$1%.0s" $(seq 1 "$2"); }   # rep <char> <n>
SM='<redacted:sentry-token>'
PM='<redacted:posthog-key>'
S="sn""try"; P="p""h"                       # split: no token prefix literal in source
SU="${S}u_fixture$(rep a 57)"               # sntryu_ + 64 chars
SS="${S}s_fixture$(rep Q 30)=="             # sntrys_ + 41 base64-shaped chars with =
PX="${P}x_fixture$(rep B 36)"               # phx_ + 43 chars
PC="${P}c_fixture$(rep c 20)"

LIB="$DIR/bin/lib/token-redact.sh"
# shellcheck source=bin/lib/token-redact.sh
. "$LIB" || { bad "lib must load"; echo "secret-mask: $PASS passed, $FAIL failed"; exit 1; }

red() { printf '%s\n' "$1" | token_redact; }
same() { # same <case> <input> <expected>
  local got; got=$(red "$2")
  [ "$got" = "$3" ] && ok || bad "$1: expected [$3], got [$got]"
}

# ── M1-M6: mask ─────────────────────────────────────────────────────────────
same M1 "token=$SU end" "token=$SM end"
# The class holds ".", so a full stop right after a token is masked with it (the safe side).
same M2 "org $SS end" "org $SM end"
same M3 "$PX at line start" "$PM at line start"
same M4 "Authorization: Bearer $SU" "Authorization: Bearer $SM"
same M5 "{\"key\":\"$PX\",\"n\":1}" "{\"key\":\"$PM\",\"n\":1}"
same M6 "two $PC and $SU" "two $PM and $SM"

# ── M7-M12: keep ────────────────────────────────────────────────────────────
same M7 "bare ${P}x_ end" "bare ${P}x_ end"
same M8 "short ${P}x_fixture end" "short ${P}x_fixture end"
G="gra${P}x_fixture$(rep d 30)"
same M9 "word $G end" "word $G end"
same M10 "phase_one_of_two" "phase_one_of_two"
N1="${S}_fixture$(rep e 30)"
same M11 "no letter $N1 end" "no letter $N1 end"
U1="SNTRYU_fixture$(rep f 30)"
same M12 "upper $U1 end" "upper $U1 end"

# ── M13: a ticket body file with both shapes ────────────────────────────────
printf '#### Cause\nThe key %s leaked.\n- token: %s\n<!-- sentry-issue: alpha:111 -->\n' "$PX" "$SU" > "$T/body.md"
token_redact_file "$T/body.md"; RC=$?
[ "$RC" = 0 ] && ok || bad "M13 rc $RC"
BODY=$(cat "$T/body.md")
[ "$(sed -n 2p "$T/body.md")" = "The key $PM leaked." ] && ok || bad "M13 line 2: [$(sed -n 2p "$T/body.md")]"
[ "$(sed -n 3p "$T/body.md")" = "- token: $SM" ] && ok || bad "M13 line 3: [$(sed -n 3p "$T/body.md")]"
if grep -qF "$PX" <<<"$BODY" || grep -qF "$SU" <<<"$BODY"; then bad "M13 a value survived"; else ok; fi
grep -qF '<!-- sentry-issue: alpha:111 -->' <<<"$BODY" && ok || bad "M13 the marker must survive"

# ── M14: the sentry-triage lane log line lands masked ───────────────────────
H="$T/h"; mkdir -p "$H/logs"
scratch_install_closure bin/sentry-triage.sh "$H" >/dev/null || bad "M14 closure install failed"
(
  # shellcheck disable=SC1091
  HARNESS="$H" . "$H/bin/lib/sentry-triage.sh" || exit 3
  HARNESS="$H" _st_log "list failed: token $SU and key $PX"
) || bad "M14 the lib did not load"
LOGTXT=$(cat "$H/logs/sentry-triage.log" 2>/dev/null)
grep -qF "list failed: token $SM and key $PM" <<<"$LOGTXT" && ok || bad "M14 log line not masked: [$LOGTXT]"
if grep -qF "$SU" <<<"$LOGTXT"; then bad "M14 the token is in the log"; else ok; fi

echo "secret-mask: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
