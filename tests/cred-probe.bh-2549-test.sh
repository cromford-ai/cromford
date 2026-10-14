#!/bin/bash
# tests/cred-probe.bh-2549-test.sh — BH-2559 (BH-2549.1): the real bodies of
# bin/lib/cred-probe.sh's cred_probe, cred_inference_claim and
# cred_inference_record, driven through a curl stub on PATH (which also plays
# the harness-jobs worker's /api/ledger route over a file-backed ledger).
#
#   P1 claude(setup-token)/codex/openrouter/fireworks/grok: 200+JSON -> ALIVE
#      rc 0; 401 -> DEAD 401 rc 1; 429 -> INCONCLUSIVE rc 2; curl rc 28 -> INCONCLUSIVE;
#   P2 adversarial negatives never read as DEAD: 5xx, an HTML 200, a DNS
#      failure, an unresolvable endpoint, codex 403; claude setup-token 403
#      -> DEAD 403 (the ticket table's 401/403); openrouter
#      limit_remaining 0 -> DEGRADED rc 3, null -> ALIVE; grok blocked -> DEAD,
#      unblocked -> ALIVE;
#   P3 the secret never reaches stdout, stderr or curl's argv; it rides in a
#      -H @<file> in a 0700 dir that is gone after the call; the body is never echoed;
#   P4 NO_ENDPOINT rc 4: codex with no key, grok off api billing, an unknown runner;
#   P5 claude full login through the OAUTH_USAGE_FETCH seam: JSON -> ALIVE,
#      HTTP 401 -> DEAD 401, URLError -> INCONCLUSIVE, token in env only;
#   L1-L5 the canary-inference ledger claim/record against the stub worker;
#   M1 a copy of the lib with its 429 arm mapped to DEAD is caught by P1.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/cred-probe.bh-2549-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/cred-probe.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SECRET="FIXTURESECRET-bh2549-cred-probe-test"
JURL=https://jobs.stub.invalid
mkdir -p "$T/bin" "$T/h" "$T/home" "$T/ledger" "$T/tmp"
: > "$T/argv.log"

# --- the curl stub -----------------------------------------------------------
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
S="$STUB_DIR"
printf '%s\n' "$*" >> "$S/argv.log"
o=""; w=""; method=GET; data=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) o="$2"; shift 2 ;;
    -w) w="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    --data-binary) data="$2"; shift 2 ;;
    -H) case "$2" in
          @*) f="${2#@}"; echo "$f" >> "$S/hfiles"
              stat -c %a "$(dirname "$f")" >> "$S/hmodes"
              cp "$f" "$S/hdr.last" ;;
        esac; shift 2 ;;
    -m|--max-time|--connect-timeout) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
code=""; body=""
if [ -n "${JOBS_URL:-}" ] && [ "${url#"$JOBS_URL"}" != "$url" ]; then
  [ "${STUB_WORKER:-}" = down ] && exit 7
  if [ "${STUB_WORKER:-}" = 500 ]; then code=500; body='{"error":"boom"}'
  elif [ "$method" = GET ]; then
    k=${url##*key=}; k=$(printf '%b' "${k//%/\\x}")
    f="$S/ledger/$(printf '%s' "$k" | sha256sum | cut -c1-16)"
    if [ -f "$f" ]; then code=200; body="{\"ledger\":$(cat "$f")}"; else code=404; body='{"error":"not found"}'; fi
  else
    echo "$data" >> "$S/puts.log"
    if [ "${STUB_WORKER:-}" = putfail ]; then code=500; body='{"error":"boom"}'
    else
      k=$(printf '%s' "$data" | jq -r .key)
      printf '%s' "$data" > "$S/ledger/$(printf '%s' "$k" | sha256sum | cut -c1-16)"
      code=200; body='{"ok":true}'
    fi
  fi
else
  echo "$url" >> "$S/urls"
  if [ "${STUB_RC:-0}" != 0 ]; then printf '%s' "${w//%\{http_code\}/000}"; exit "$STUB_RC"; fi
  code="${STUB_CODE:-200}"; body="${STUB_BODY-}"
fi
if [ -n "$o" ]; then printf '%s' "$body" > "$o"; else printf '%s' "$body"; fi
printf '%s' "${w//%\{http_code\}/$code}"
exit 0
STUB
chmod +x "$T/bin/curl"

# --- the OAUTH_USAGE_FETCH stub (full-login claude) ---------------------------
cat > "$T/bin/usage-fetch" <<'STUB'
#!/bin/bash
printf '%s\n' "$0 $*" >> "$STUB_DIR/fetch-argv.log"
[ "${OAUTH_USAGE_TOKEN:-}" = "$WANT_TOKEN" ] || { echo "wrong token" >&2; exit 5; }
case "${FETCH_MODE:-ok}" in
  ok)  echo '{"five_hour":{"utilization":3}}' ;;
  401) echo 'urllib.error.HTTPError: HTTP Error 401: Unauthorized' >&2; exit 1 ;;
  url) echo 'urllib.error.URLError: <urlopen error [Errno -2] Name or service not known>' >&2; exit 1 ;;
esac
STUB
chmod +x "$T/bin/usage-fetch"

# Every credential and endpoint the lib reads is set here explicitly, so the
# box's own environment never leaks in.
CLEAN=(env -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CONFIG_DIR -u CODEX_API_KEY -u OPENAI_API_KEY
       -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY -u XAI_API_KEY -u GROK_CODE_XAI_API_KEY
       -u GROK_BILLING -u OAUTH_USAGE_FETCH -u CRED_PROBE_LIB -u STUB_CODE -u STUB_BODY -u STUB_RC
       -u STUB_WORKER -u JOBS_URL -u HARNESS_SECRET -u BOX_NAME -u JOBS_BOX
       PATH="$T/bin:$PATH" HOME="$T/home" HARNESS="$T/h" TMPDIR="$T/tmp" STUB_DIR="$T"
       ENDPOINT_ANTHROPIC=https://stub.invalid ENDPOINT_OPENAI=https://stub.invalid
       ENDPOINT_OPENROUTER=https://stub.invalid ENDPOINT_FIREWORKS=https://stub.invalid
       ENDPOINT_XAI=https://stub.invalid ENDPOINT_ANTHROPIC_OAUTH=https://stub.invalid)

# probe <lib> <runner> [VAR=val ...] -> OUT (stdout), ERR (stderr), RC
probe() {
  local lib="$1" runner="$2"; shift 2
  OUT=$("${CLEAN[@]}" "$@" bash -c 'set -euo pipefail; . "$1"; cred_probe "$2"' _ "$lib" "$runner" 2>"$T/err")
  RC=$?; ERR=$(cat "$T/err")
}
cred_for() {  # the env that gives <runner> a credential (and api billing for grok)
  case "$1" in
    claude)     echo "CLAUDE_CODE_OAUTH_TOKEN=$SECRET" ;;
    codex)      echo "OPENAI_API_KEY=$SECRET" ;;
    openrouter) echo "OPENROUTER_API_KEY=$SECRET" ;;
    fireworks)  echo "FIREWORKS_API_KEY=$SECRET" ;;
    grok)       echo "XAI_API_KEY=$SECRET GROK_BILLING=api" ;;
  esac
}
expect() {  # expect <label> <want-regex> <want-rc>
  [[ "$OUT" =~ $2 ]] && [ "$RC" -eq "$3" ] && ok || bad "$1 -> '$OUT' rc=$RC (want /$2/ rc $3) stderr='$ERR'"
}

# P1 -----------------------------------------------------------------------------
p1_429() {  # p1_429 <lib> <runner> -> rc 0 when the 429 reads INCONCLUSIVE rc 2
  # shellcheck disable=SC2046
  probe "$1" "$2" $(cred_for "$2") STUB_CODE=429 STUB_BODY='{"error":"rate"}'
  [[ "$OUT" =~ ^INCONCLUSIVE ]] && [ "$RC" -eq 2 ]
}
for r in claude codex openrouter fireworks grok; do
  # shellcheck disable=SC2046
  probe "$LIB" "$r" $(cred_for "$r") STUB_CODE=200 STUB_BODY='{"data":[]}'
  expect "P1 $r 200 json" '^ALIVE' 0
  # shellcheck disable=SC2046
  probe "$LIB" "$r" $(cred_for "$r") STUB_CODE=401 STUB_BODY='{"error":"auth"}'
  expect "P1 $r 401" '^DEAD 401$' 1
  p1_429 "$LIB" "$r" && ok || bad "P1 $r 429 -> '$OUT' rc=$RC (want INCONCLUSIVE rc 2)"
  # shellcheck disable=SC2046
  probe "$LIB" "$r" $(cred_for "$r") STUB_RC=28
  expect "P1 $r curl timeout" '^INCONCLUSIVE' 2
done
# the setup-token probe carries the OAuth beta header; the paths are the free ones
: > "$T/urls"
probe "$LIB" claude CLAUDE_CODE_OAUTH_TOKEN="$SECRET" STUB_CODE=200 STUB_BODY='{}'
grep -qx 'anthropic-beta: oauth-2025-04-20' "$T/hdr.last" && grep -qx 'anthropic-version: 2023-06-01' "$T/hdr.last" \
  && grep -qx "Authorization: Bearer $SECRET" "$T/hdr.last" && ok || bad "P1 claude setup-token headers: $(sed 's/Bearer .*/Bearer <redacted>/' "$T/hdr.last")"
for pair in claude:/v1/models codex:/v1/models openrouter:/api/v1/key fireworks:/inference/v1/models grok:/v1/api-key; do
  r=${pair%%:*}; want=https://stub.invalid${pair#*:}; : > "$T/urls"
  # shellcheck disable=SC2046
  probe "$LIB" "$r" $(cred_for "$r") STUB_CODE=200 STUB_BODY='{}'
  [ "$(cat "$T/urls")" = "$want" ] && ok || bad "P1 $r probed '$(cat "$T/urls")' (want $want)"
done

# P2 -----------------------------------------------------------------------------
for c in 500 502 503; do
  probe "$LIB" claude CLAUDE_CODE_OAUTH_TOKEN="$SECRET" STUB_CODE=$c STUB_BODY='{}'
  expect "P2 claude $c" '^INCONCLUSIVE' 2
done
probe "$LIB" fireworks FIREWORKS_API_KEY="$SECRET" STUB_CODE=200 STUB_BODY='<html>captive portal</html>'
expect "P2 fireworks html 200" '^INCONCLUSIVE' 2
probe "$LIB" codex OPENAI_API_KEY="$SECRET" STUB_RC=6
expect "P2 codex DNS failure" '^INCONCLUSIVE' 2
probe "$LIB" claude CLAUDE_CODE_OAUTH_TOKEN="$SECRET" STUB_CODE=403 STUB_BODY='{"type":"error","error":{"type":"permission_error"}}'
expect "P2 claude setup-token 403" '^DEAD 403$' 1
probe "$LIB" codex OPENAI_API_KEY="$SECRET" STUB_CODE=403 STUB_BODY='{}'
expect "P2 codex 403" '^INCONCLUSIVE' 2
: > "$T/urls"
OUT=$("${CLEAN[@]}" FIREWORKS_API_KEY="$SECRET" bash -c 'unset ENDPOINT_FIREWORKS; . "$1"; cred_probe fireworks' _ "$LIB" 2>"$T/err")
RC=$?; ERR=$(cat "$T/err")
expect "P2 fireworks with no resolvable endpoint" '^INCONCLUSIVE' 2
[ -s "$T/urls" ] && bad "P2 an unresolved endpoint must not call curl: $(cat "$T/urls")" || ok
probe "$LIB" openrouter OPENROUTER_API_KEY="$SECRET" STUB_CODE=200 STUB_BODY='{"data":{"limit_remaining":0}}'
expect "P2 openrouter limit_remaining 0" '^DEGRADED limit_remaining=0$' 3
probe "$LIB" openrouter OPENROUTER_API_KEY="$SECRET" STUB_CODE=200 STUB_BODY='{"data":{"limit_remaining":-2.5}}'
expect "P2 openrouter limit_remaining negative" '^DEGRADED' 3
probe "$LIB" openrouter OPENROUTER_API_KEY="$SECRET" STUB_CODE=200 STUB_BODY='{"data":{"limit_remaining":null}}'
expect "P2 openrouter unlimited key" '^ALIVE' 0
probe "$LIB" openrouter OPENROUTER_API_KEY="$SECRET" STUB_CODE=200 STUB_BODY='{"data":{"limit_remaining":12.5}}'
expect "P2 openrouter credit left" '^ALIVE' 0
probe "$LIB" grok XAI_API_KEY="$SECRET" GROK_BILLING=api STUB_CODE=200 STUB_BODY='{"api_key_blocked":false,"api_key_disabled":false}'
expect "P2 grok unblocked" '^ALIVE' 0
probe "$LIB" grok XAI_API_KEY="$SECRET" GROK_BILLING=api STUB_CODE=200 STUB_BODY='{"api_key_blocked":true}'
expect "P2 grok blocked" '^DEAD 200' 1
probe "$LIB" grok GROK_CODE_XAI_API_KEY="$SECRET" GROK_BILLING=api STUB_CODE=200 STUB_BODY='{"api_key_disabled":true}'
expect "P2 grok disabled (fallback key)" '^DEAD 200' 1
probe "$LIB" grok XAI_API_KEY="$SECRET" GROK_BILLING=api STUB_CODE=403 STUB_BODY='{}'
expect "P2 grok 403" '^DEAD 403$' 1
# xAI answers a bad key with 400 + this body, not 401 (live, 2026-09-27): that
# one shape is DEAD; any other 400 stays INCONCLUSIVE.
probe "$LIB" grok XAI_API_KEY="$SECRET" GROK_BILLING=api STUB_CODE=400 \
  STUB_BODY='{"code":"invalid-argument","error":"Incorrect API key provided. You can obtain an API key from the console."}'
expect "P2 grok 400 incorrect key" '^DEAD 400$' 1
probe "$LIB" grok XAI_API_KEY="$SECRET" GROK_BILLING=api STUB_CODE=400 STUB_BODY='{"code":"invalid-argument","error":"bad request"}'
expect "P2 grok other 400" '^INCONCLUSIVE' 2
probe "$LIB" fireworks FIREWORKS_API_KEY="$SECRET" STUB_CODE=403 STUB_BODY='{}'
expect "P2 fireworks 403" '^DEAD 403$' 1
probe "$LIB" fireworks
expect "P2 fireworks with no key" '^INCONCLUSIVE' 2

# P3 -----------------------------------------------------------------------------
: > "$T/hfiles"; : > "$T/hmodes"; ALLOUT=""; ALLERR=""
for r in claude codex openrouter fireworks grok; do
  for c in 200 401 429; do
    # shellcheck disable=SC2046
    probe "$LIB" "$r" $(cred_for "$r") STUB_CODE=$c STUB_BODY='{"marker":"BODYMARKER"}'
    ALLOUT+="$OUT"$'\n'; ALLERR+="$ERR"$'\n'
    [ "$(printf '%s\n' "$OUT" | wc -l)" -eq 1 ] && [[ "$OUT" =~ ^(ALIVE|DEAD|INCONCLUSIVE|DEGRADED|NO_ENDPOINT) ]] \
      && ok || bad "P3 $r $c must print exactly one class line: '$OUT'"
  done
done
[[ "$ALLOUT$ALLERR" == *"$SECRET"* ]] && bad "P3 the secret reached stdout/stderr" || ok
[[ "$ALLOUT$ALLERR" == *BODYMARKER* ]] && bad "P3 the response body was echoed" || ok
grep -qF "$SECRET" "$T/argv.log" && bad "P3 the secret is on curl's argv" || ok
grep -q -- '-H @' "$T/argv.log" && ok || bad "P3 curl must read its headers from -H @<file>"
[ "$(wc -l < "$T/hfiles")" -eq 15 ] && ok || bad "P3 want 15 header files, got $(wc -l < "$T/hfiles")"
left=0; while read -r f; do [ -e "$f" ] || [ -e "$(dirname "$f")" ] && left=$((left+1)); done < "$T/hfiles"
[ "$left" -eq 0 ] && ok || bad "P3 $left header file(s)/dir(s) still exist after the probe returned"
[ "$(sort -u "$T/hmodes")" = 700 ] && ok || bad "P3 header dir modes: $(sort -u "$T/hmodes" | paste -sd,)"
[ -z "$(ls -A "$T/tmp")" ] && ok || bad "P3 temp leftovers: $(ls -A "$T/tmp")"

# P4 -----------------------------------------------------------------------------
: > "$T/urls"
probe "$LIB" codex
expect "P4 codex on a ChatGPT login" '^NO_ENDPOINT$' 4
probe "$LIB" grok XAI_API_KEY="$SECRET"
expect "P4 grok billing unset" '^NO_ENDPOINT$' 4
probe "$LIB" grok XAI_API_KEY="$SECRET" GROK_BILLING=subscription
expect "P4 grok on subscription" '^NO_ENDPOINT$' 4
probe "$LIB" nosuchrunner CLAUDE_CODE_OAUTH_TOKEN="$SECRET"
expect "P4 unknown runner" '^NO_ENDPOINT$' 4
[ -s "$T/urls" ] && bad "P4 a NO_ENDPOINT answer must not call curl" || ok

# P5 -----------------------------------------------------------------------------
mkdir -p "$T/home/.claude"
printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$SECRET" > "$T/home/.claude/.credentials.json"
: > "$T/fetch-argv.log"; : > "$T/urls"
probe "$LIB" claude OAUTH_USAGE_FETCH="$T/bin/usage-fetch" WANT_TOKEN="$SECRET" FETCH_MODE=ok
expect "P5 full login usage 200" '^ALIVE' 0
probe "$LIB" claude OAUTH_USAGE_FETCH="$T/bin/usage-fetch" WANT_TOKEN="$SECRET" FETCH_MODE=401
expect "P5 full login 401" '^DEAD 401$' 1
probe "$LIB" claude OAUTH_USAGE_FETCH="$T/bin/usage-fetch" WANT_TOKEN="$SECRET" FETCH_MODE=url
expect "P5 full login URLError" '^INCONCLUSIVE' 2
[ "$(wc -l < "$T/fetch-argv.log")" -eq 3 ] && ok || bad "P5 the fetcher should have run 3 times: $(wc -l < "$T/fetch-argv.log")"
grep -qF "$SECRET" "$T/fetch-argv.log" && bad "P5 the token reached the fetcher's argv" || ok
[[ "$OUT$ERR" == *"$SECRET"* ]] && bad "P5 the token reached stdout/stderr" || ok
rm -rf "$T/home/.claude"
probe "$LIB" claude
expect "P5 claude with no credential at all" '^INCONCLUSIVE no credential$' 2

# L1-L5 --------------------------------------------------------------------------
FP=fp0123456789abcd
DAY=$(date -u +%F)
KEY="claude:$FP:$DAY"
lrun() {  # lrun <shell snippet> [VAR=val ...] -> OUT, RC
  local snip="$1"; shift
  OUT=$("${CLEAN[@]}" JOBS_URL="$JURL" HARNESS_SECRET=fixture-hs JOBS_RETRIES=0 "$@" \
        bash -c 'set -euo pipefail; . "$1"; '"$snip" _ "$LIB" 2>"$T/err")
  RC=$?; ERR=$(cat "$T/err")
}
row() { cat "$T/ledger/$(printf '%s' "$1" | sha256sum | cut -c1-16)" 2>/dev/null; }
: > "$T/puts.log"
lrun "cred_inference_claim claude $FP"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "L1 claim on an empty ledger -> rc=$RC out='$OUT' err='$ERR'"
[ "$(row "$KEY" | jq -r '[.kind,.status,.detail]|join("|")')" = "canary-inference|claimed|box=$(hostname)" ] \
  && ok || bad "L1 ledger row for $KEY: '$(row "$KEY")'"
lrun "cred_inference_claim claude $FP"
[ "$RC" -eq 1 ] && ok || bad "L2 second claim the same day -> rc=$RC (want 1)"
[ "$(wc -l < "$T/puts.log")" -eq 1 ] && ok || bad "L2 the second claim must not PUT: $(wc -l < "$T/puts.log") PUTs"
lrun "cred_inference_claim codex $FP" STUB_WORKER=down
[ "$RC" -eq 2 ] && ok || bad "L3 unreachable worker -> rc=$RC (want 2)"
lrun "cred_inference_claim codex $FP" STUB_WORKER=500
[ "$RC" -eq 2 ] && ok || bad "L4 worker 500 -> rc=$RC (want 2)"
lrun "cred_inference_claim codex $FP" STUB_WORKER=putfail
[ "$RC" -eq 2 ] && ok || bad "L4 PUT failing after a 404 -> rc=$RC (want 2)"
lrun "cred_inference_claim codex $FP" JOBS_URL=
[ "$RC" -eq 2 ] && ok || bad "L4 no coordination DB configured -> rc=$RC (want 2)"
lrun "cred_inference_claim claude"
[ "$RC" -eq 2 ] && ok || bad "L4 claim with no fp -> rc=$RC (want 2)"
K2="grok:$FP:$DAY"
lrun "cred_inference_record grok $FP empty"
[ "$RC" -eq 0 ] && [ "$(row "$K2" | jq -r .status)" = empty ] && ok || bad "L5 record empty -> rc=$RC row='$(row "$K2")'"
lrun "cred_inference_claim grok $FP"
[ "$RC" -eq 1 ] && ok || bad "L5 an 'empty' record is billed: a claim after it -> rc=$RC (want 1)"
lrun "cred_inference_record claude $FP ok"
[ "$RC" -eq 0 ] && [ "$(row "$KEY" | jq -r .status)" = ok ] && ok || bad "L5 record ok on the claimed row -> rc=$RC row='$(row "$KEY")'"
lrun "cred_inference_record claude $FP bogus"
[ "$RC" -eq 1 ] && [ "$(row "$KEY" | jq -r .status)" = ok ] && ok || bad "L5 bad status -> rc=$RC (want 1, row untouched)"
lrun "cred_inference_record claude $FP down" STUB_WORKER=500
[ "$RC" -eq 1 ] && ok || bad "L5 record against a failing worker -> rc=$RC (want 1)"
# a record in the same process lands on the CLAIMED day's row, even past UTC midnight
lrun "cred_inference_claim fireworks $FP; _CP_CLAIM=\"fireworks:$FP:1999-01-01\"; cred_inference_record fireworks $FP degraded"
[ "$(row "fireworks:$FP:1999-01-01" | jq -r .status)" = degraded ] && ok || bad "L5 record must reuse the claimed day's key"

# M1 -----------------------------------------------------------------------------
sed 's/^\(\s*\)429) /\1429) _cp_mutant=1; echo "DEAD 429"; return 1 ;; 4290) /' "$LIB" > "$T/h/mutant.sh"
grep -q '_cp_mutant' "$T/h/mutant.sh" || bad "M1 the mutation did not apply: no '429)' arm found in the lib"
cp "$DIR/bin/lib/endpoints.sh" "$DIR/bin/lib/lane-gate.sh" "$T/h/" 2>/dev/null
if p1_429 "$T/h/mutant.sh" claude; then bad "M1 a lib mapping 429 to DEAD passed P1's 429 case"; else ok; fi

echo "cred-probe.bh-2549: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
