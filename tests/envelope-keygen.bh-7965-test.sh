#!/bin/bash
# tests/envelope-keygen.bh-7965-test.sh — BH-7965 (BH-7937.2): bin/envelope-keygen.sh
# against the REAL jobs worker over HTTP (tests/lib/envelope-worker.bh-7965.mjs).
#   K1 the key: mode 600, RSA-4096, openssl pkey -check ok
#   K2 a second run without --rotate keeps the key (same public fingerprint)
#   K3 the PUT body is one PUBLIC KEY block, nothing private; the row reads back equal
#   K4 --rotate: a new fingerprint, the old key kept as envelope.key.<epoch>, mode 600
#   K5 the worker down: exit 75, the key stays on disk
#   K6 a usage error and missing credentials: exit 1, no request
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/envelope-keygen.bh-7965-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/envelope-suite.bh-7965.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v openssl >/dev/null 2>&1 || { echo "SKIP: node, jq, curl or openssl missing"; exit 0; }
[ -s "$DIR/bin/envelope-keygen.sh" ] && ok "source exists: bin/envelope-keygen.sh" || bad "missing bin/envelope-keygen.sh"
es_init || { echo "setup failed"; exit 1; }
trap 'es_stop' EXIT
es_srv w1; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "${PORT:-}" ] || { echo "setup: worker did not start: $(cat "$T/w1.err")"; exit 1; }
# A curl shim in front of the real one keeps a copy of every request body file.
REAL_CURL=$(command -v curl)
mkdir -p "$T/curlbin" "$T/bodies"
cat > "$T/curlbin/curl" <<EOF
#!/bin/bash
cfg=\$(cat)
f=\$(printf '%s\n' "\$cfg" | sed -n 's/^data-binary = "@\(.*\)"\$/\1/p')
[ -n "\$f" ] && cp "\$f" "$T/bodies/\$(date +%s%N).json"
printf '%s\n' "\$cfg" | "$REAL_CURL" "\$@"
EOF
chmod +x "$T/curlbin/curl"
KG() { PATH="$T/curlbin:$PATH" "$H/bin/envelope-keygen.sh" "$@" > "$T/kg.out" 2>&1; RC=$?; }
fp() { openssl pkey -in "$1" -pubout -outform DER 2>/dev/null | sha256sum | cut -c1-64; }
row() { es_get "SELECT value FROM settings WHERE key='hub_envelope_public_key'" | jq -r '.[0].value'; }

echo "K1: the key"
KG
[ "$RC" = 0 ] && ok "K1 exit 0" || bad "K1 rc=$RC $(cat "$T/kg.out")"
[ "$(stat -c %a "$ENVELOPE_KEY" 2>/dev/null)" = 600 ] && ok "K1 mode 600" || bad "K1 mode $(stat -c %a "$ENVELOPE_KEY" 2>&1)"
openssl pkey -in "$ENVELOPE_KEY" -check -noout >/dev/null 2>&1 && ok "K1 openssl pkey -check ok" || bad "K1 key check"
openssl pkey -in "$ENVELOPE_KEY" -text -noout 2>/dev/null | grep -q '4096 bit' && ok "K1 RSA-4096" || bad "K1 not 4096 bit"
FP1=$(fp "$ENVELOPE_KEY")

echo "K2: a second run keeps the key"
KG
[ "$RC" = 0 ] && [ "$(fp "$ENVELOPE_KEY")" = "$FP1" ] && ok "K2 same fingerprint, exit 0" || bad "K2 rc=$RC"
grep -q 'kept' "$T/kg.out" && ok "K2 says the key was kept" || bad "K2 output $(cat "$T/kg.out")"

echo "K3: the PUT body"
LAST=$(find "$T/bodies" -name '*.json' | sort | tail -1)
[ -n "$LAST" ] && PEM=$(jq -r '.pem' "$LAST") || PEM=""
[ "$(grep -c -- '-----BEGIN PUBLIC KEY-----' <<<"$PEM")" = 1 ] && ! grep -q PRIVATE "$LAST" \
  && ok "K3 the body is one PUBLIC KEY block and nothing private" || bad "K3 body $(head -c 200 "$LAST" 2>&1)"
[ "$(row)" = "$(openssl pkey -in "$ENVELOPE_KEY" -pubout 2>/dev/null)" ] && ok "K3 the settings row reads back the public half" || bad "K3 row $(row | head -2)"
GOT=$(curl -sS -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/settings/hub_envelope_public_key" | jq -r '.setting.value')
[ "$GOT" = "$(row)" ] && ok "K3 GET /api/settings/hub_envelope_public_key returns it" || bad "K3 GET settings: $GOT"
grep -q '^PUT /api/secrets/envelope/public-key 200 hub=1$' "$T/w1.log" && ok "K3 the PUT carried x-envelope-hub-token" || bad "K3 log $(cat "$T/w1.log")"

echo "K4: --rotate"
ENVELOPE_NOW=1791000000 KG --rotate
FP2=$(fp "$ENVELOPE_KEY")
[ "$RC" = 0 ] && [ "$FP2" != "$FP1" ] && ok "K4 a new fingerprint" || bad "K4 rc=$RC"
[ "$(fp "$ENVELOPE_KEY.1791000000")" = "$FP1" ] && [ "$(stat -c %a "$ENVELOPE_KEY.1791000000")" = 600 ] \
  && ok "K4 the old key is envelope.key.1791000000, mode 600" || bad "K4 old key $(ls -la "$T/keys")"
[ "$(row)" = "$(openssl pkey -in "$ENVELOPE_KEY" -pubout 2>/dev/null)" ] && ok "K4 the row holds the new public half" || bad "K4 row"

echo "K5: the worker down"
JOBS_URL="http://127.0.0.1:9" KG
[ "$RC" = 75 ] && [ "$(fp "$ENVELOPE_KEY")" = "$FP2" ] && ok "K5 exit 75, the key stays" || bad "K5 rc=$RC"
es_stop; ES_PIDS=()
es_srv w2 FAIL_ALL=1
KG
[ "$RC" = 75 ] && ok "K5 a 5xx answer: exit 75" || bad "K5 5xx rc=$RC"

echo "K6: usage and credentials"
N0=$(wc -l < "$T/w2.log")
KG --bogus
[ "$RC" = 1 ] && ok "K6 an unknown flag: exit 1" || bad "K6 rc=$RC"
ENVELOPE_HUB_TOKEN='' KG
[ "$RC" = 1 ] && [ "$(wc -l < "$T/w2.log")" = "$N0" ] && ok "K6 no hub token: exit 1, no request" || bad "K6 rc=$RC"
! grep -q 'PRIVATE' "$T/kg.out" "$T/w1.log" "$T/w2.log" && ok "K6 no private key text in any output" || bad "K6 private key text in output"

echo "envelope-keygen.bh-7965: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
