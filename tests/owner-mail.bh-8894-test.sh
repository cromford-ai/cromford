#!/bin/bash
# tests/owner-mail.bh-8894-test.sh — THE RESEND SEAM AND THE OWNER-MAIL HELPER
# (BH-8894, slice C0: the email half of #8781 item 2).
#
# bin/lib/vendor/resend.sh resend_send POSTs one email to Resend (key by
# variable NAME, curl config on stdin). bin/lib/owner-mail.sh owner_mail
# resolves sender and recipient, dedupes on a key in state/owner-mail.json
# (stamp before send), calls the seam and prints one word.
#
# Driven: the real libs, installed with scratch_install_closure and sourced.
# A PATH `curl` stub records argv, stdin and the state file at call time and
# answers from the case dir. NOW is fixed. 0 real network.
#
#   R1-R7  the seam: bad name rc 2, empty key rc 3, empty from/to/subject rc 4,
#          fake answer, unseeded fake rc 70, real mode config on stdin (key
#          not in argv, body round-trips), one VENDOR_CALL_LOG line
#   M1-M7  the answer rule: only a non-empty string .id is `sent`
#   M8-M13 the config rule: from, to, HARNESS_GIT_EMAIL, the key (env, file)
#   D1-D7  the dedupe rule on <key> with ttl T
#   K1     RESEND_API_TIMEOUT_S reaches --max-time; a bad value is 20
#   K2     OWNER_MAIL_ERR_CHARS cuts the recorded why
#   A1     bad args print bad-args
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/owner-mail.bh-8894-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: owner-mail: %s\n' "$*"; }

LIBH="$T/libh"; mkdir -p "$LIBH"
scratch_install_closure bin/lib/owner-mail.sh "$LIBH" >/dev/null || bad "setup: cannot install bin/lib/owner-mail.sh"
for f in bin/lib/owner-mail.sh bin/lib/vendor/resend.sh bin/lib/vendor/seam.sh bin/lib/env-path.sh; do
  [ -f "$LIBH/$f" ] || bad "setup: the closure has no $f"
done
# shellcheck source=/dev/null
if ! . "$LIBH/bin/lib/owner-mail.sh"; then
  bad "setup: cannot source owner-mail.sh"
  echo "owner-mail.bh-8894: $PASS passed, $FAIL failed"; exit 1
fi
FIXDIR="$DIR/tests/fixtures/vendor-fake"

# The curl stub: one numbered record per call in $CS.
FB="$T/fakebin"; mkdir -p "$FB"
cat > "$FB/curl" <<'STUB'
#!/bin/bash
n=$(( $(cat "$CS/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CS/n"
printf '%s\n' "$*" > "$CS/argv.$n"
cat > "$CS/stdin.$n"
[ -n "${CS_STATE:-}" ] && [ -f "$CS_STATE" ] && cp "$CS_STATE" "$CS/state.$n"
cat "$CS/answer" 2>/dev/null
exit "$(cat "$CS/rc" 2>/dev/null || echo 0)"
STUB
# A sed wrapper that logs its file arguments (M10: the env file is never read).
REAL_SED=$(command -v sed)
cat > "$FB/sed" <<STUB
#!/bin/bash
printf '%s\\n' "\$*" >> "\${SED_LOG:-/dev/null}"
exec "$REAL_SED" "\$@"
STUB
chmod +x "$FB/curl" "$FB/sed"

# newcase <name> — a fresh harness root, curl stub dir and env dir.
newcase() {
  C="$T/c/$1"; mkdir -p "$C/h/bin" "$C/h/state" "$C/cs" "$C/env"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$AL_LOG"\nexit 0\n' > "$C/h/bin/alert-line.sh"
  chmod +x "$C/h/bin/alert-line.sh"
  echo '{"id":"99999999-9999-9999-9999-999999999999"}' > "$C/cs/answer"
  echo 0 > "$C/cs/rc"
  : > "$C/alerts"
}
# run_om [VAR=value]... [-- owner_mail args] — owner_mail in a subshell with
# the case env. Default args: ttl 86400, key prodred:pa, project pa.
OMARGS=(86400 prodred:pa pa "Production deploy failed: pa" "PROD RED pa: the newest production deploy failed")
run_om() {
  (
    export HARNESS="$C/h" HARNESS_ENV_DIR="$C/env" CS="$C/cs" CS_STATE="$C/h/state/owner-mail.json" \
      AL_LOG="$C/alerts" SED_LOG="$C/sed.log" PATH="$FB:$PATH" HARNESS_VENDOR_FAKE=0 \
      VENDOR_CALL_LOG="$C/calls" NOW=1793400000 OWNER_MAIL_FROM=alerts@example.test \
      HARNESS_GIT_EMAIL=owner@example.test RESEND_API_KEY=re_fixture_key
    unset OWNER_MAIL_TO RESEND_API_TIMEOUT_S OWNER_MAIL_ERR_CHARS H
    while [ $# -gt 0 ] && [[ $1 == *=* ]]; do export "${1?}"; shift; done
    [ "${1:-}" = -- ] && shift
    if [ $# -gt 0 ]; then owner_mail "$@"; else owner_mail "${OMARGS[@]}"; fi
  ) 2>>"$T/stderr"
}
ncalls() { cat "$C/cs/n" 2>/dev/null || echo 0; }
row() { jq -c --arg k "${1:-prodred:pa}" '.[$k]' "$C/h/state/owner-mail.json" 2>/dev/null; }
answer() { printf '%s\n' "$1" > "$C/cs/answer"; }
# run_rs [VAR=value]... -- resend_send args — the seam alone, rc in RS_RC.
run_rs() {
  RS_OUT=$(
    export CS="$C/cs" PATH="$FB:$PATH" HARNESS_VENDOR_FAKE=0 VENDOR_CALL_LOG="$C/calls" RS_KEY=re_fixture_key
    unset RESEND_API_TIMEOUT_S
    while [ $# -gt 0 ] && [[ $1 == *=* ]]; do export "${1?}"; shift; done
    [ "${1:-}" = -- ] && shift
    resend_send "$@" 2>"$C/rs.err"
  ); RS_RC=$?
}
# cfg_val <stdin file> <option> — the decoded value of one curl config line.
cfg_val() {
  python3 -I -c '
import sys
opt = sys.argv[2]
for line in open(sys.argv[1], encoding="utf-8"):
    k, _, v = line.rstrip("\n").partition(" = ")
    if k != opt: continue
    v = v[1:-1]
    out, i = [], 0
    while i < len(v):
        c = v[i]
        if c == "\\" and i + 1 < len(v):
            n = v[i + 1]
            out.append({"n": "\n", "r": "\r", "t": "\t"}.get(n, n)); i += 2; continue
        out.append(c); i += 1
    print("".join(out))
' "$1" "$2"
}

# ================= R: the seam ==============================================
newcase r1
run_rs -- bad-name a@example.test b@example.test subj text
[ "$RS_RC" = 2 ] && ok || bad "R1 a bad variable name is rc 2 (got $RS_RC)"
run_rs RS_KEY= -- RS_KEY a@example.test b@example.test subj text
[ "$RS_RC" = 3 ] && ok || bad "R2 an empty key is rc 3 (got $RS_RC)"
for spec in 'from::b@example.test:s' 'to:a@example.test::s' 'subject:a@example.test:b@example.test:'; do
  IFS=: read -r what fr to su <<<"$spec"
  run_rs -- RS_KEY "$fr" "$to" "$su" text
  [ "$RS_RC" = 4 ] && ok || bad "R3 an empty $what is rc 4 (got $RS_RC)"
done
[ "$(ncalls)" = 0 ] && ok || bad "R1-R3 no curl call on a refused argument (got $(ncalls))"

newcase r4
run_rs HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$FIXDIR" -- RS_KEY a@example.test b@example.test subj text
[ "$RS_RC" = 0 ] && [ "$(jq -r '.id' <<<"$RS_OUT" 2>/dev/null)" = fake-email-0001 ] && ok \
  || bad "R4 fake mode answers the seeded id (rc $RS_RC, got '$RS_OUT')"
[ "$(ncalls)" = 0 ] && [ ! -s "$C/calls" ] && ok || bad "R4 fake mode makes 0 curl calls and 0 call-log lines"
mkdir -p "$C/empty-fake"
run_rs HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$C/empty-fake" -- RS_KEY a@example.test b@example.test subj text
[ "$RS_RC" = 70 ] && ok || bad "R5 an unseeded fake is rc 70 (got $RS_RC)"

newcase r6
TXT=$'line one "quoted" \\ back\nline two\tTAB\r\nurl = "https://example.test/evil"'
run_rs -- RS_KEY alerts@example.test owner@example.test 'Production deploy failed: pa' "$TXT"
[ "$RS_RC" = 0 ] && [ "$RS_OUT" = '{"id":"99999999-9999-9999-9999-999999999999"}' ] && ok \
  || bad "R6 real mode prints the raw answer (rc $RS_RC, got '$RS_OUT')"
[ "$(ncalls)" = 1 ] && ok || bad "R6 one curl call (got $(ncalls))"
[ "$(cfg_val "$C/cs/stdin.1" url)" = https://api.resend.com/emails ] && ok || bad "R6 the url is https://api.resend.com/emails (got '$(cfg_val "$C/cs/stdin.1" url)')"
grep -q 'Authorization: Bearer re_fixture_key' <<<"$(cfg_val "$C/cs/stdin.1" header)" && ok || bad "R6 the Authorization header is on stdin"
grep -q 'Content-Type: application/json' <<<"$(cfg_val "$C/cs/stdin.1" header)" && ok || bad "R6 the Content-Type header is on stdin"
DATA=$(cfg_val "$C/cs/stdin.1" data)
jq -e --arg t "$TXT" '.from == "alerts@example.test" and .to == ["owner@example.test"] and .subject == "Production deploy failed: pa" and .text == $t' <<<"$DATA" >/dev/null 2>&1 \
  && ok || bad "R6 the data line decodes to the JSON body, text byte for byte (got '$DATA')"
[ "$(grep -c '^url = ' "$C/cs/stdin.1")" = 1 ] && ok || bad "R6 a text line cannot start a second url option"
grep -q 're_fixture_key' "$C/cs/argv.1" && bad "R6 the key is in the curl argv" || ok
grep -q -- '-K -' "$C/cs/argv.1" && ok || bad "R6 curl reads its config from stdin (argv: $(cat "$C/cs/argv.1"))"
[ "$(grep -c ' resend send$' "$C/calls" 2>/dev/null)" = 1 ] && ok || bad "R7 one 'resend send' line in VENDOR_CALL_LOG (got $(cat "$C/calls" 2>/dev/null))"
# R7b: a curl failure is rc 1 and the error does not hold the key.
newcase r7
answer 'curl: (28) Operation timed out re_fixture_key'; echo 28 > "$C/cs/rc"
run_rs -- RS_KEY alerts@example.test owner@example.test subj text
[ "$RS_RC" = 1 ] && ok || bad "R7b a curl failure is rc 1 (got $RS_RC)"
grep -q re_fixture_key "$C/rs.err" && bad "R7b the key is in the curl error" || ok

# ================= M: the answer rule (1) ===================================
newcase m1
W=$(run_om)
[ "$W" = sent ] && ok || bad "M1 a REST answer with an id is sent (got '$W')"
jq -e '.status == "sent" and .id == "99999999-9999-9999-9999-999999999999" and .to == "owner@example.test" and .at == 1793400000' <<<"$(row)" >/dev/null 2>&1 \
  && ok || bad "M1 the state row is {sent, id, to, at} (got $(row))"
[ ! -s "$C/alerts" ] && ok || bad "M1 a sent mail raises no alert"
for spec in \
  'M2|{"statusCode":422,"name":"validation_error","message":"Invalid to"}' \
  'M3|{"statusCode":403,"message":"domain is not verified"}' \
  'M4a|{"id":""}' \
  'M4b|{"id":null}' \
  'M5|{"data":{"id":"x"}}' \
  'M6|<html>502 Bad Gateway</html>'; do
  c=${spec%%|*}; a=${spec#*|}
  newcase "$c"; answer "$a"
  W=$(run_om)
  [ "$W" = failed ] && ok || bad "$c answer '$a' is failed (got '$W')"
  [ "$(jq -r '.status' <<<"$(row)")" = failed ] && [ -n "$(jq -r '.why // empty' <<<"$(row)")" ] && ok || bad "$c the state row is failed with a why (got $(row))"
  [ "$(grep -c '^--severity warn --id owner-mail-prodred:pa \[owner-mail\] pa: the owner email to owner@example.test failed: ' "$C/alerts")" = 1 ] && ok \
    || bad "$c one owner-mail alert line (got '$(cat "$C/alerts")')"
done
newcase m7
answer 'curl: (28) Operation timed out re_fixture_key'; echo 28 > "$C/cs/rc"
W=$(run_om)
[ "$W" = failed ] && ok || bad "M7 a curl failure is failed (got '$W')"
grep -q re_fixture_key "$C/h/state/owner-mail.json" "$C/alerts" && bad "M7 the key is in the state why or the alert" || ok
grep -q 'timed out' <<<"$(jq -r '.why' <<<"$(row)")" && ok || bad "M7 the why names the curl error (got $(row))"
# M7b: an answer that echoes the key (rc 0) is cut by owner_mail itself.
newcase m7b
answer '{"statusCode":401,"message":"API key re_fixture_key is invalid"}'
W=$(run_om)
[ "$W" = failed ] && grep -q 'API key <key> is invalid' <<<"$(jq -r '.why' <<<"$(row)")" && ok || bad "M7b the echoed key is cut from why (got $(row))"
grep -q re_fixture_key "$C/h/state/owner-mail.json" "$C/alerts" && bad "M7b the key is in the state why or the alert" || ok

# ================= M: the config rule (2) ===================================
newcase m8
W=$(run_om); DATA=$(cfg_val "$C/cs/stdin.1" data)
[ "$W" = sent ] && [ "$(jq -c '.to' <<<"$DATA")" = '["owner@example.test"]' ] && ok || bad "M8 no OWNER_MAIL_TO sends to HARNESS_GIT_EMAIL (got '$W', $DATA)"
[ "$(jq -r '.from' <<<"$DATA")" = alerts@example.test ] && ok || bad "M8 the sender is OWNER_MAIL_FROM"
newcase m9
W=$(run_om OWNER_MAIL_TO=other@example.test); DATA=$(cfg_val "$C/cs/stdin.1" data)
[ "$W" = sent ] && [ "$(jq -c '.to' <<<"$DATA")" = '["other@example.test"]' ] && [ "$(jq -r '.to' <<<"$(row)")" = other@example.test ] \
  && ok || bad "M9 OWNER_MAIL_TO wins (got '$W', $DATA)"
newcase m10
W=$(run_om OWNER_MAIL_FROM= HARNESS_ENV_DIR="$C/no-such-env")
[ "$W" = not-configured ] && ok || bad "M10 an empty sender is not-configured (got '$W')"
[ "$(ncalls)" = 0 ] && [ ! -e "$C/h/state/owner-mail.json" ] && ok || bad "M10 0 curl calls and 0 state writes"
grep -q 'global.env' "$C/sed.log" 2>/dev/null && bad "M10 the env file was read" || ok
newcase m11
printf 'export RESEND_API_KEY="re_fixture_x"\nOTHER=1\nRESEND_API_KEY=re_fixture_y\n' > "$C/env/global.env"
W=$(run_om RESEND_API_KEY=)
[ "$W" = sent ] && grep -q 'Bearer re_fixture_y' <<<"$(cfg_val "$C/cs/stdin.1" header)" && ok \
  || bad "M11 the key comes from global.env, last assignment wins (got '$W', $(cfg_val "$C/cs/stdin.1" header 2>/dev/null))"
newcase m12
W=$(run_om RESEND_API_KEY=)
[ "$W" = not-configured ] && [ "$(ncalls)" = 0 ] && [ ! -e "$C/h/state/owner-mail.json" ] && ok || bad "M12 no key anywhere is not-configured, no write (got '$W')"
newcase m13
W=$(run_om OWNER_MAIL_TO=not-an-address)
[ "$W" = not-configured ] && [ "$(ncalls)" = 0 ] && ok || bad "M13 a recipient with no @ is not-configured (got '$W')"
newcase m14
W=$(run_om HARNESS= OWNER_MAIL_TO=a@example.test)
[ "$W" = not-configured ] && [ "$(ncalls)" = 0 ] && ok || bad "M14 no harness root is not-configured, no call (got '$W')"

# ================= D: the dedupe rule (3) ===================================
newcase d1
W=$(run_om)
[ "$W" = sent ] && [ "$(jq -r '.["prodred:pa"].status' "$C/cs/state.1" 2>/dev/null)" = sending ] && [ "$(jq -r '.["prodred:pa"].at' "$C/cs/state.1" 2>/dev/null)" = 1793400000 ] \
  && ok || bad "D1 the row is stamped sending BEFORE the call (at call: $(cat "$C/cs/state.1" 2>/dev/null))"
# D1 -> D2 round trip on the same file: run 1's row suppresses run 2.
W=$(run_om NOW=1793400060)
[ "$W" = suppressed ] && [ "$(ncalls)" = 1 ] && ok || bad "D1/D2 the file run 1 wrote suppresses run 2 (got '$W', calls $(ncalls))"
seed() { jq -nc --arg k "$1" --argjson a "$2" --arg s "${3:-sent}" '{($k):{at:$a,status:$s,to:"owner@example.test"}}' > "$C/h/state/owner-mail.json"; }
newcase d2; seed prodred:pa $((1793400000 - 3599))
W=$(run_om -- 3600 prodred:pa pa subj text)
[ "$W" = suppressed ] && [ "$(ncalls)" = 0 ] && ok || bad "D2 a row at now-(T-1) is suppressed (got '$W')"
[ "$(jq -r '.at' <<<"$(row)")" = $((1793400000 - 3599)) ] && ok || bad "D2 suppressed writes nothing"
newcase d3; seed prodred:pa $((1793400000 - 3600))
W=$(run_om -- 3600 prodred:pa pa subj text)
[ "$W" = sent ] && ok || bad "D3 a row at exactly now-T sends (got '$W')"
newcase d4; seed prodred:other 1793400000
W=$(run_om)
[ "$W" = sent ] && [ "$(jq -r '.["prodred:other"].at' "$C/h/state/owner-mail.json")" = 1793400000 ] && ok || bad "D4 another key does not suppress, and is kept (got '$W')"
newcase d5; printf '{"half": ' > "$C/h/state/owner-mail.json"
W=$(run_om)
[ "$W" = sent ] && jq -e '.["prodred:pa"].status == "sent"' "$C/h/state/owner-mail.json" >/dev/null 2>&1 && ok || bad "D5 a torn file reads as {} and is rewritten valid (got '$W')"
newcase d6; seed prodred:pa $((1793400000 - 60)) failed
W=$(run_om)
[ "$W" = suppressed ] && [ "$(ncalls)" = 0 ] && ok || bad "D6 a failed row inside the TTL is not retried (got '$W')"
newcase d7
W1=$(run_om OWNER_MAIL_FROM=); W2=$(run_om NOW=1793400060)
[ "$W1" = not-configured ] && [ "$W2" = sent ] && ok || bad "D7 not-configured writes no stamp, so a later configured run sends (got '$W1' then '$W2')"
newcase d8
W=$(run_om -- abc prodred:pa pa subj text)
seed prodred:pa $((1793400000 - 86399)); W2=$(run_om -- 0 prodred:pa pa subj text)
[ "$W" = sent ] && [ "$W2" = suppressed ] && ok || bad "D8 a bad ttl reads as 86400 (got '$W', '$W2')"

# ================= K: the knobs ==============================================
for spec in abc:20 0:20 500:20 45:45; do
  k=${spec%%:*}; w=${spec#*:}
  newcase "k1-$k"
  run_om RESEND_API_TIMEOUT_S="$k" >/dev/null
  grep -q -- "--max-time $w " "$C/cs/argv.1" 2>/dev/null && ok || bad "K1 RESEND_API_TIMEOUT_S=$k -> --max-time $w (argv: $(cat "$C/cs/argv.1" 2>/dev/null))"
done
newcase k2
answer "{\"statusCode\":422,\"message\":\"$(printf 'x%.0s' $(seq 1 300))\"}"
run_om OWNER_MAIL_ERR_CHARS=50 >/dev/null
[ "$(jq -r '.why | length' <<<"$(row)")" = 50 ] && ok || bad "K2 OWNER_MAIL_ERR_CHARS=50 cuts why to 50 (got $(jq -r '.why | length' <<<"$(row)"))"
newcase k2b; answer "{\"statusCode\":422,\"message\":\"$(printf 'x%.0s' $(seq 1 300))\"}"
run_om OWNER_MAIL_ERR_CHARS=abc >/dev/null
[ "$(jq -r '.why | length' <<<"$(row)")" = 200 ] && ok || bad "K2 a bad OWNER_MAIL_ERR_CHARS reads as 200 (got $(jq -r '.why | length' <<<"$(row)"))"

# ================= A: bad args ==============================================
newcase a1
for i in 2 4 5; do
  args=("${OMARGS[@]}"); args[$((i - 1))]=""
  W=$(run_om -- "${args[@]}")
  [ "$W" = bad-args ] && ok || bad "A1 an empty argument $i is bad-args (got '$W')"
done
[ "$(ncalls)" = 0 ] && [ ! -e "$C/h/state/owner-mail.json" ] && ok || bad "A1 bad-args makes no call and no write"

echo "owner-mail.bh-8894: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
