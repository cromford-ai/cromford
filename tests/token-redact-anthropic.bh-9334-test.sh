#!/bin/bash
# tests/token-redact-anthropic.bh-9334-test.sh — bin/lib/token-redact.sh turns
# an Anthropic API key (`sk-ant-api<NN>-` + 20 or more [A-Za-z0-9_-]) into
# `<redacted:anthropic-key>` (BH-9334 Fix 6). The OAuth shape `sk-ant-oat…` is
# NOT this lib's concern and stays unchanged; the GitHub shapes still redact.
#
# Every fake key is built at run time and carries the word FIXTURE. No
# key-shaped literal is written in this file. No network, nothing outside $T.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

rep() { printf "$1%.0s" $(seq 1 "$2"); }   # rep <char> <n>
MARK='<redacted:anthropic-key>'
GHMARK='<redacted:github-token>'
SK="sk-""ant-"                               # split: no key prefix literal in source
BODY="FIXTURE_$(rep Q 24)-$(rep R 8)"        # 41 of [A-Za-z0-9_-]
K03="${SK}api03-$BODY"
K04="${SK}api04-FIXTURE$(rep Z 20)"
OAT="${SK}oat01-FIXTURE$(rep Q 40)"
SHORT="${SK}api03-FIXTURE123"                # 10 after the prefix: under the floor
ADMIN="${SK}admin01-FIXTURE$(rep Q 40)"
GHS="ghs_FIXTURE$(rep Q 29)"

LIB="$DIR/bin/lib/token-redact.sh"
# shellcheck source=bin/lib/token-redact.sh
. "$LIB" || { bad "lib must load"; echo "token-redact-anthropic.bh-9334: $PASS pass, $FAIL fail"; exit 1; }

red() { printf '%s\n' "$1" | token_redact; }
same() { # same <case> <input> <expected>
  local got; got=$(red "$2")
  [ "$got" = "$3" ] && ok || bad "$1: expected [$3], got [$got]"
}

# ── R1-R6. redact ───────────────────────────────────────────────────────────
same R1 "2026-11-13T02:00:00Z agent-call: key=$K03 project=proj-a" "2026-11-13T02:00:00Z agent-call: key=$MARK project=proj-a"
same R2 "ANTHROPIC_API_KEY='$K03'" "ANTHROPIC_API_KEY='$MARK'"
same R3 "x-api-key: $K03" "x-api-key: $MARK"
same R4 "https://proxy.test/v1?key=$K03&x=1" "https://proxy.test/v1?key=$MARK&x=1"
same R5 "$K03 then $K04" "$MARK then $MARK"
same R6 "v4 $K04." "v4 $MARK."

# ── R7-R9. keep ─────────────────────────────────────────────────────────────
same R7 "oauth $OAT end" "oauth $OAT end"
same R8 "short $SHORT end" "short $SHORT end"
same R9a "bare ${SK}api end" "bare ${SK}api end"
same R9b "admin $ADMIN end" "admin $ADMIN end"

# ── R10. the GitHub shapes still redact, on the same line ──────────────────
same R10 "gh $GHS and $K03" "gh $GHMARK and $MARK"

# ── R11. token_redact_file scrubs a key in place ────────────────────────────
printf 'line one\nleak %s here\nHARNESS_EXIT: 0\n' "$K03" > "$T/k.log"
token_redact_file "$T/k.log"; RC=$?
[ "$RC" = 0 ] && ok || bad "R11: rc $RC"
grep -qF "$K03" "$T/k.log" && bad "R11: the key must be gone from the file" || ok
[ "$(sed -n 2p "$T/k.log")" = "leak $MARK here" ] && ok || bad "R11: got [$(sed -n 2p "$T/k.log")]"

echo "token-redact-anthropic.bh-9334: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
