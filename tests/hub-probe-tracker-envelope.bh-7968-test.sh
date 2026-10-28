#!/bin/bash
# tests/hub-probe-tracker-envelope.bh-7968-test.sh — BH-7968 (BH-7937.4): the
# hub probe `tracker-test` reads its credential from a secret envelope
# (bin/lib/hub-probes/tracker-test.sh onb_open) and opens it with the shared
# envelope_decrypt (bin/lib/envelope.sh).
#
#   D1-D4  envelope_decrypt: the current key; a rotated key younger than the
#          TTL; a rotated key older than the TTL is not tried; a wrong key
#   V1     hp_validate tracker-test takes <kind> <lower-case uuid> only
#   P1     a sealed linear envelope: ok list=2 dry-write=ok, rc 0, the
#          envelope is consumed, no temp file is left
#   P2     no envelope (404): FAIL credential expired, test again
#   P3     an ai-account scope: FAIL scope refused, no vendor call
#   P4     another kind; P5 an empty project: FAIL, no vendor call
#   P6     plaintext not JSON; P7 no fields; P8 a non-string field: FAIL, no vendor call
#   P9     a refused hub token: FAIL hub token not accepted; no hub token:
#          FAIL credential store not configured
#   P10    the scrub: a vendor that echoes the key shows [redacted]
#   F1     the field check the worker used to do, now on the hub: a private
#          board host, a short secret, a foreign Jira site: FAIL, no vendor call
#   R1     round trip: the console's sealSecret (console-ui/src/lib/envelope.js)
#          seals in node WebCrypto, the REAL worker stores it, the probe opens it
#
# The envelopes go through the REAL jobs worker over HTTP
# (tests/lib/envelope-worker.bh-7965.mjs, tests/lib/envelope-suite.bh-7965.sh).
# A front `curl` on PATH answers api.linear.app and board.example.com from
# fixtures and hands every other request (the worker on 127.0.0.1) to the real
# curl. The key pair is made here with openssl; no value is real.
#   HARNESS_TEST_SANDBOX=1 bash tests/hub-probe-tracker-envelope.bh-7968-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/envelope-suite.bh-7965.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 || { echo "SKIP: jq or openssl missing"; exit 0; }
HPD="$DIR/bin/lib/hub-probes"
LIBENV="$DIR/bin/lib/envelope.sh"

mkdir -p "$T/k" "$T/tmp"
NOW=1800000000
mkkey() { openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$1" 2>/dev/null && openssl pkey -in "$1" -pubout -out "$1.pub" 2>/dev/null; }
seal() { printf '%s' "$1" | openssl pkeyutl -encrypt -pubin -inkey "$2" -pkeyopt rsa_padding_mode:oaep \
  -pkeyopt rsa_oaep_md:sha256 -pkeyopt rsa_mgf1_md:sha256 | base64 -w0; }
mkkey "$T/k/a" && mkkey "$T/k/b" && mkkey "$T/k/c" || { echo "setup: openssl genpkey failed"; exit 1; }

# ── D1-D4: envelope_decrypt ─────────────────────────────────────────────────
dec() { # dec <key> <ciphertext> — prints "<rc>|<plaintext>"
  bash -c '. "$1" || exit 99; declare -F envelope_decrypt >/dev/null || exit 98; out=$(printf "%s" "$3" | envelope_decrypt "$2"); r=$?; printf "%s|%s" "$r" "$out"' \
    _ "$LIBENV" "$1" "$2" 2>/dev/null
}
mkdir -p "$T/kd"; cp "$T/k/a" "$T/kd/envelope.key"
cp "$T/k/b" "$T/kd/envelope.key.$((NOW - 100))"
cp "$T/k/c" "$T/kd/envelope.key.$((NOW - 1000))"
export ENVELOPE_NOW="$NOW"
P='{"fields":{"team":"CRO"}}'
[ "$(dec "$T/kd/envelope.key" "$(seal "$P" "$T/k/a.pub")")" = "0|$P" ] && ok "D1 the current key opens it" || bad "D1 $(dec "$T/kd/envelope.key" "$(seal "$P" "$T/k/a.pub")")"
[ "$(dec "$T/kd/envelope.key" "$(seal "$P" "$T/k/b.pub")")" = "0|$P" ] && ok "D2 a rotated key younger than the TTL opens it" || bad "D2 $(dec "$T/kd/envelope.key" "$(seal "$P" "$T/k/b.pub")")"
[ "$(dec "$T/kd/envelope.key" "$(seal "$P" "$T/k/c.pub")")" = "1|" ] && ok "D3 a rotated key older than the TTL is not tried" || bad "D3 $(dec "$T/kd/envelope.key" "$(seal "$P" "$T/k/c.pub")")"
mkkey "$T/k/d"
[ "$(dec "$T/k/a" "$(seal "$P" "$T/k/d.pub")")" = "1|" ] && ok "D4 a wrong key prints nothing, rc 1" || bad "D4"
[ "$(dec "$T/k/a" "not base64 at all")" = "1|" ] && ok "D4 a ciphertext that is not base64 prints nothing, rc 1" || bad "D4 junk"

# ── V1: hp_validate ─────────────────────────────────────────────────────────
val() { bash -c '. "$1/common.sh" || exit 99; shift; hp_validate "$@"' _ "$HPD" "$@"; echo $?; }
U=$(tr "[:upper:]" "[:lower:]" < /proc/sys/kernel/random/uuid)   # made at run time: no literal id in a test file
[ "$(val tracker-test linear "$U")" = 0 ] && [ "$(val tracker-test board "$U")" = 0 ] && ok "V1 linear/board + uuid validate" || bad "V1 uuid"
[ "$(val tracker-test linear "$(printf '%s' 0123456789abcdef 0123456789abcdef)")" = 2 ] && ok "V1 32 hex refused" || bad "V1 32 hex"
[ "$(val tracker-test linear "$(tr '[:lower:]' '[:upper:]' <<<"$U")")" = 2 ] && ok "V1 upper-case uuid refused" || bad "V1 upper"
[ "$(val tracker-test linear ../x)" = 2 ] && [ "$(val tracker-test Linear "$U")" = 2 ] && [ "$(val tracker-test linear "$U" x)" = 2 ] && ok "V1 ../x, Linear, an extra arg refused" || bad "V1 near misses"

# ── the worker and the vendor stub ──────────────────────────────────────────
command -v node >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 || { echo "SKIP P/F/R: node or curl missing"; echo "hub-probe-tracker-envelope: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit; }
es_init || { echo "setup failed"; exit 1; }
trap 'es_stop; __scratch_exit_trap' EXIT
es_srv w1; src=$?
if [ "$src" = 3 ]; then echo "SKIP P/F/R: node:sqlite unavailable"; echo "hub-probe-tracker-envelope: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit; fi
[ -n "${PORT:-}" ] || { echo "setup: worker did not start: $(cat "$T/w1.err")"; exit 1; }
cp "$T/k/a" "$ENVELOPE_KEY"; cp "$T/k/a.pub" "$T/keys/pub.pem"
unset ENVELOPE_NOW

REAL_CURL=$(command -v curl)
STUB="$T/vstub"; mkdir -p "$STUB"
LIN_KEY=lin-api-fixture-SENTINEL-7968
BOARD_TOK=board-fixture-SENTINEL-7968
export TT_STUB="$STUB" TT_REAL_CURL="$REAL_CURL" TT_LIN_KEY="$LIN_KEY" TT_BOARD_TOK="$BOARD_TOK" TT_LFIX="$DIR/tests/fixtures/tracker-linear"
cat > "$STUB/curl" <<'SH'
#!/bin/bash
# The vendor stub: Linear and the board from fixtures; anything else (the
# worker on 127.0.0.1, read through a -K config) goes to the real curl.
S="$TT_STUB"; m=GET; url=""; data=""; out=""; fmt=""; auth=""
args=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift ;;
    --data-binary|-d) data="$2"; shift ;;
    -o) out="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -m|--max-time|--connect-timeout) shift ;;
    -H) case "$2" in [Aa]uthorization:*) auth="${2#*: }" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
reply() { if [ -n "$out" ]; then printf '%s' "$2" > "$out"; else printf '%s' "$2"; fi; [ -n "$fmt" ] && printf '%s' "$fmt" | sed "s/%{http_code}/$1/g"; exit 0; }
body() { case "$data" in @*) cat "${data#@}" ;; *) printf '%s' "$data" ;; esac; }
case "$url" in
  https://api.linear.app/graphql)
    op=$(body | jq -r '.query // ""' | sed -nE '1s/^(query|mutation) ([A-Za-z]+).*/\2/p')
    echo "linear $op" >> "$S/vendor.log"
    if [ "$auth" != "$TT_LIN_KEY" ] || [ -f "$S/arm-echo401" ]; then
      reply 401 "$(jq -nc --arg k "$auth" '{errors:[{message:("Authentication required, key " + $k + " is not valid")}]}')"
    fi
    case "$op" in
      TrkIssues) [ -z "$(body | jq -r '.variables.after // empty')" ] && reply 200 "$(cat "$TT_LFIX/issues-page1.json")"; reply 200 "$(cat "$TT_LFIX/issues-page2.json")" ;;
      TrkIssueMeta|TrkIssue) id=$(body | jq -r '.variables.id'); [ -r "$TT_LFIX/issue-$id.json" ] && reply 200 "$(cat "$TT_LFIX/issue-$id.json")"; reply 200 "$(cat "$TT_LFIX/not-found.json")" ;;
    esac
    reply 400 '{"errors":[{"message":"unknown operation"}]}' ;;
  https://board.example.com/api/board/*)
    p="${url#https://board.example.com/api/board}"; echo "board $m $p" >> "$S/vendor.log"
    [ "$auth" = "Bearer $TT_BOARD_TOK" ] || reply 401 '{"error":"bad token"}'
    case "$p" in
      /boards) reply 200 '{"boards":[{"id":"b1"}]}' ;;
      /boards/b1/tickets) reply 200 '{"tickets":[{"id":"t1","title":"One","status":"todo"}]}' ;;
    esac
    reply 404 '{"error":"no route"}' ;;
  https://*) echo "OFFBASE $m $url" >> "$S/vendor.log"; [ -n "$fmt" ] && printf '000'; exit 7 ;;
esac
exec "$TT_REAL_CURL" "${args[@]}"
SH
chmod +x "$STUB/curl"
export PATH="$STUB:$PATH"

LIN_FIELDS=$(jq -nc --arg k "$LIN_KEY" '{api_key:$k, team:"CRO", label:"ai-build"}')
BOARD_FIELDS=$(jq -nc --arg t "$BOARD_TOK" '{api_base:"https://board.example.com/api/board", token:$t}')
# envelope <scope> <plaintext> — seal to the hub key, store it in the worker, print the id.
envelope() { es_seal "$2" "$1"; }
# probe <kind> <id> — hp_run as the lane runs it, in a child shell. Out in $T/out, rc in $T/rc.
probe() {
  rm -f "$STUB/vendor.log"
  TMPDIR="$T/tmp" bash -c '. "$1/common.sh" || exit 99; hp_run tracker-test "$2" "$3"' _ "$HPD" "$1" "$2" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
rc() { cat "$T/rc"; }
first() { head -1 "$T/out"; }
novendor() { [ ! -s "$STUB/vendor.log" ]; }
pending() { es_get "SELECT COUNT(*) AS n FROM secret_envelopes WHERE id='$1'" | jq -r '.[0].n'; }

echo "P1: linear"
ID=$(envelope tracker:linear:newproj "{\"fields\":$LIN_FIELDS}")
[ -n "$ID" ] && [ "$(pending "$ID")" = 1 ] || bad "P1 setup: the envelope was not stored"
probe linear "$ID"
[ "$(rc)" = 0 ] && grep -qx "ok list=2 dry-write=ok" "$T/out" && ok "P1 ok list=2 dry-write=ok, rc 0" || bad "P1 rc=$(rc) out=$(cat "$T/out")"
grep -q "^linear TrkIssues" "$STUB/vendor.log" 2>/dev/null && ok "P1 the sealed key reached Linear" || bad "P1 vendor log: $(cat "$STUB/vendor.log" 2>/dev/null)"
[ "$(pending "$ID")" = 0 ] && ok "P1 the read consumed the envelope" || bad "P1 envelope still pending"
[ -z "$(ls -A "$T/tmp")" ] && ok "P1 no temp file left" || bad "P1 temp files: $(ls "$T/tmp")"
grep -q "GET /api/secrets/envelope/$ID 200 hub=1" "$T/w1.log" && ok "P1 one hub-token read of the envelope" || bad "P1 worker log: $(cat "$T/w1.log")"

echo "P2: no envelope"
probe linear "$(tr "[:upper:]" "[:lower:]" < /proc/sys/kernel/random/uuid)"
[ "$(rc)" = 1 ] && [ "$(first)" = "FAIL credential expired, test again" ] && novendor && ok "P2 FAIL credential expired, no vendor call" || bad "P2 rc=$(rc) out=$(cat "$T/out")"

echo "P3-P8: refused envelopes"
refuse() { # refuse <name> <arg kind> <scope> <plaintext> <expected first-line prefix>
  local id; id=$(envelope "$3" "$4")
  [ -n "$id" ] || { bad "$1 setup: not stored"; return; }
  probe "$2" "$id"
  if [ "$(rc)" = 1 ] && [[ "$(first)" == "$5"* ]] && novendor && [ -z "$(ls -A "$T/tmp")" ]; then ok "$1 -> $(first)"; else bad "$1 rc=$(rc) out=$(cat "$T/out") vendor=$(cat "$STUB/vendor.log" 2>/dev/null)"; fi
}
refuse "P3 an ai-account scope" linear "ai-account:claude:a:project:newproj" "{\"fields\":$LIN_FIELDS}" "FAIL scope refused"
refuse "P4 another kind" linear "tracker:jira:newproj" "{\"fields\":$LIN_FIELDS}" "FAIL scope refused"
refuse "P5 an empty project" linear "tracker:linear:" "{\"fields\":$LIN_FIELDS}" "FAIL scope refused"
refuse "P5 a project with a colon" linear "tracker:linear:a:b" "{\"fields\":$LIN_FIELDS}" "FAIL scope refused"
refuse "P6 plaintext not JSON" linear "tracker:linear:newproj" "api_key=$LIN_KEY" "FAIL credential is not readable"
refuse "P7 no fields object" linear "tracker:linear:newproj" "$LIN_FIELDS" "FAIL credential is not readable"
refuse "P8 a non-string field" linear "tracker:linear:newproj" '{"fields":{"api_key":12345678,"team":"CRO","label":"ai-build"}}' "FAIL credential is not readable"
refuse "P8 an array field" board "tracker:board:newproj" '{"fields":{"api_base":["https://board.example.com/api/board"],"token":"board-fixture-SENTINEL-7968"}}' "FAIL credential is not readable"
for f in "$T/out" "$T/w1.log"; do ! grep -q "SENTINEL-7968" "$f" && ok "P3-P8 no secret in $(basename "$f")" || bad "P3-P8 secret in $f"; done

echo "P9: the hub token"
ID=$(envelope tracker:linear:newproj "{\"fields\":$LIN_FIELDS}")
( export ENVELOPE_HUB_TOKEN=tok-fixture-wrong; probe linear "$ID" )
[ "$(rc)" = 1 ] && [ "$(first)" = "FAIL hub token not accepted" ] && novendor && ok "P9 a refused token: FAIL hub token not accepted" || bad "P9 rc=$(rc) out=$(cat "$T/out")"
[ "$(pending "$ID")" = 1 ] && ok "P9 a refused read leaves the envelope" || bad "P9 envelope gone"
( unset ENVELOPE_HUB_TOKEN; probe linear "$ID" )
[ "$(rc)" = 1 ] && [ "$(first)" = "FAIL credential store not configured" ] && novendor && ok "P9 no hub token: FAIL credential store not configured" || bad "P9b rc=$(rc) out=$(cat "$T/out")"

echo "P10: the scrub"
touch "$STUB/arm-echo401"
probe linear "$(envelope tracker:linear:newproj "{\"fields\":$LIN_FIELDS}")"
rm -f "$STUB/arm-echo401"
[ "$(rc)" = 1 ] && grep -q "^FAIL tracker list failed" "$T/out" && grep -q "\[redacted\]" "$T/out" && ! grep -q "$LIN_KEY" "$T/out" \
  && ok "P10 the echoed key is [redacted]" || bad "P10 rc=$(rc) out=$(cat "$T/out")"

echo "F1: the field check on the hub"
refuse "F1 a private board host" board "tracker:board:newproj" "$(jq -nc --argjson f "$BOARD_FIELDS" '{fields:($f + {api_base:"https://10.0.0.5/api"})}')" "FAIL api_base must be a public host"
refuse "F1 a metadata board host" board "tracker:board:newproj" "$(jq -nc --argjson f "$BOARD_FIELDS" '{fields:($f + {api_base:"https://169.254.169.254/latest"})}')" "FAIL api_base must be a public host"
refuse "F1 http board base" board "tracker:board:newproj" "$(jq -nc --argjson f "$BOARD_FIELDS" '{fields:($f + {api_base:"http://board.example.com/api/board"})}')" "FAIL api_base must be an https:// URL"
refuse "F1 a short secret" linear "tracker:linear:newproj" '{"fields":{"api_key":"short","team":"CRO","label":"ai-build"}}' "FAIL api_key must be at least 8 characters"
refuse "F1 a missing field" linear "tracker:linear:newproj" "{\"fields\":{\"api_key\":\"$LIN_KEY\",\"team\":\"CRO\"}}" "FAIL label is required"
refuse "F1 an extra field" board "tracker:board:newproj" "$(jq -nc --argjson f "$BOARD_FIELDS" '{fields:($f + {x:"y"})}')" "FAIL x is not a board field"
refuse "F1 a foreign Jira site" jira "tracker:jira:newproj" '{"fields":{"site":"acme.atlassian.net.evil.example","email":"bot@example.com","api_token":"tok-fixture-jira-1","project_key":"CROM","status_map":"todo=To Do;in_progress=In Progress;review=In Review;closed=Done"}}' "FAIL site must be <name>.atlassian.net"
ID=$(envelope tracker:board:newproj "{\"fields\":$BOARD_FIELDS}")
probe board "$ID"
[ "$(rc)" = 0 ] && grep -qx "ok list=1 dry-write=ok" "$T/out" && ok "F1 a public board host passes" || bad "F1 board pass rc=$(rc) out=$(cat "$T/out")"

echo "R1: the console seal, opened on the hub"
NODE_SEAL=$(cat <<'JS'
const { sealSecret } = await import(process.argv[1]);
const { readFileSync } = await import('node:fs');
process.stdout.write(await sealSecret(readFileSync(process.argv[2], 'utf8'), process.argv[3]));
JS
)
CT=$(node --input-type=module -e "$NODE_SEAL" "$DIR/console-ui/src/lib/envelope.js" "$T/keys/pub.pem" "{\"fields\":$LIN_FIELDS}" 2> "$T/r1.err")
if [ -z "$CT" ]; then
  bad "R1 the console seal failed: $(cat "$T/r1.err")"
else
  ID=$(jq -nc --arg c "$CT" '{scope:"tracker:linear:newproj", ciphertext:$c}' \
    | "$REAL_CURL" -sS -X POST -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' --data-binary @- "$JOBS_URL/api/secrets/envelope" | jq -r '.id // empty')
  probe linear "$ID"
  [ "$(rc)" = 0 ] && grep -qx "ok list=2 dry-write=ok" "$T/out" && ok "R1 the hub opened the browser seal and the test passed" || bad "R1 rc=$(rc) out=$(cat "$T/out")"
fi

echo "hub-probe-tracker-envelope: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
