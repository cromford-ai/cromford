#!/bin/bash
# tests/box-console-commands-client.bh-2528-test.sh — BH-2653 (BH-2528.0): the
# client verbs in bin/lib/jobs/box-console-commands.sh.
#
# Drives the REAL bin/jobs-client.sh plus the REAL lib against a stubbed curl.
# The worker routes are a sibling slice, so this pins the client contract only:
# the routes and bodies each verb sends, rc 0 only on a 2xx with the documented
# shape, 1 on an outage, a bad answer or bad input (no request for bad input),
# 2 on a 404, 9 on a 409, and a payload over the argv cap riding a file.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/jobs/box-console-commands.sh"
SCHEMA="$DIR/worker/jobs/schema.sql"
mkdir -p "$T/logs" "$T/state" "$T/bin/lib/jobs" "$T/env" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
echo "HARNESS_SECRET=test-secret" > "$T/env/global.env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
reqs() { if [ -f "$T/req.log" ]; then wc -l < "$T/req.log"; else echo 0; fi; }

# Fake curl: one JSON line per request {method,url,file,body}, where file says
# whether --data-binary was @file. Answers per CURL_MODE.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET; FILE=0
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; case "$BODY" in @*) FILE=1; BODY=$(cat "${BODY#@}");; esac; shift 2;;
    *) shift;;
  esac
done
printf '%s' "$BODY" | jq -Rsc --arg m "$METHOD" --arg u "$URL" --arg f "$FILE" \
  '{method:$m, url:$u, file:($f=="1"), body:.}' >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down) exit 7 ;;
  500) printf '{"error":"boom"}\n500\n'; exit 0 ;;
  409) printf '{"error":"conflict"}\n409\n'; exit 0 ;;
  404) printf '{"error":"not found"}\n404\n'; exit 0 ;;
  bad) printf '{}\n200\n'; exit 0 ;;
esac
case "$METHOD $URL" in
  "POST "*/api/box-console-commands/claim) printf '[{"command_id":"c1","box":"b1"}]\n200\n' ;;
  "POST "*/api/box-console-commands/expire) printf '{"expired":["c2"],"stale_claimed":[]}\n200\n' ;;
  "POST "*/api/box-console-commands/*/result) printf '{"ok":true}\n200\n' ;;
  "POST "*/api/box-console-commands) printf '{"created":true}\n200\n' ;;
  *) printf '{}\n404\n' ;;
esac
CURL
chmod +x "$T/fakebin/curl"

# fn <function> [args...] — sources jobs-client then the lib, then runs the verb
# and echoes JOBS_HTTP on fd 3 so the caller can read it.
fn() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid REQ_SINK="$T/req.log" JOBS_RETRIES=0 ${EXTRA_ENV:-}
    # shellcheck source=/dev/null
    . "$T/bin/jobs-client.sh" >/dev/null 2>&1
    # shellcheck source=/dev/null
    . "$T/bin/lib/jobs/box-console-commands.sh" || exit 97
    case "${URL_MODE:-set}" in unset) unset JOBS_URL ;; empty) JOBS_URL= ;; esac
    "$@"; rc=$?
    echo "${JOBS_HTTP:-}" > "$T/http"
    exit "$rc" ) 2>"$T/err"
}
last() { tail -n 1 "$T/req.log"; }

# --- C1: forward happy path, and bad input makes no request -------------------
: > "$T/req.log"
OUT=$(fn box_ccmd_forward c-1 box-a run-lane proj '{"lane":"x","n":1}'); RC=$?
L=$(last)
[ "$RC" = 0 ] && [ "$OUT" = '{"created":true}' ] && [ "$(cat "$T/http")" = 200 ] \
  && [ "$(jq -r .method <<<"$L")" = POST ] \
  && [ "$(jq -r .url <<<"$L")" = "https://jobs.invalid/api/box-console-commands" ] \
  && [ "$(jq -r '.body|fromjson|[.command_id,.box,.type,.project,.payload]|@json' <<<"$L")" = '["c-1","box-a","run-lane","proj","{\"lane\":\"x\",\"n\":1}"]' ] \
  && ok || bad "C1 forward rc=$RC out='$OUT' http=$(cat "$T/http") req=$L"
: > "$T/req.log"
OUT=$(fn box_ccmd_forward c-2 box-a run-lane '' '{}'); RC=$?
[ "$RC" = 0 ] && [ "$(jq -r '.body|fromjson|.project' <<<"$(last)")" = null ] \
  && ok || bad "C1 empty project should travel as null: rc=$RC req=$(last)"
: > "$T/req.log"
for args in "c-3 box-a t p not-json" "c-3 box-a t p ''" "'' box-a t p {}" "c-3 '' t p {}" "c-3 box-a '' p {}" "c-3 box-a t p"; do
  eval "set -- $args"
  OUT=$(fn box_ccmd_forward "$@"); RC=$?
  [ "$RC" = 1 ] && [ -z "$OUT" ] || bad "C1 bad input ($args) rc=$RC out='$OUT'"
done
[ "$(reqs)" = 0 ] && ok || bad "C1 bad input made $(reqs) request(s)"

# --- C2: 500 on every verb => rc 1, no stdout, JOBS_HTTP=500 -----------------
printf 'body text' > "$T/body.txt"
for v in "box_ccmd_forward c-1 box-a t p {}" "box_ccmd_claim box-a 10" "box_ccmd_result c-1 box-a 1 done" "box_ccmd_expire 300"; do
  # shellcheck disable=SC2086
  OUT=$(EXTRA_ENV="CURL_MODE=500" fn $v); RC=$?
  [ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$(cat "$T/http")" = 500 ] && ok || bad "C2 $v rc=$RC out='$OUT' http=$(cat "$T/http")"
done

# --- C3: unset / empty JOBS_URL after sourcing => rc 1, no request ----------
for m in unset empty; do
  : > "$T/req.log"
  for v in "box_ccmd_forward c-1 box-a t p {}" "box_ccmd_claim box-a 10" "box_ccmd_result c-1 box-a 1 done" "box_ccmd_expire 300"; do
    # shellcheck disable=SC2086
    OUT=$(URL_MODE=$m fn $v); RC=$?
    [ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q '^box-console-commands: coordination DB not configured' "$T/err" \
      && ok || bad "C3 JOBS_URL $m: $v rc=$RC out='$OUT' err=$(head -c 200 "$T/err")"
  done
  [ "$(reqs)" = 0 ] && ok || bad "C3 JOBS_URL $m made $(reqs) request(s)"
done

# --- C4: a 300 KB payload rides a file and arrives whole ---------------------
BIG=$(head -c 300000 /dev/zero | tr '\0' 'a' | jq -Rsc '{blob:.}')
: > "$T/req.log"
OUT=$(fn box_ccmd_forward c-big box-a t p "$BIG"); RC=$?
L=$(last)
[ "$RC" = 0 ] && [ "$(jq -r .file <<<"$L")" = true ] \
  && [ "$(jq -r '.body|fromjson|.payload|length' <<<"$L")" = "${#BIG}" ] \
  && [ "$(jq -r '.body|fromjson|.payload' <<<"$L")" = "$BIG" ] \
  && ok || bad "C4 big payload rc=$RC file=$(jq -r .file <<<"$L") len=$(jq -r '.body|fromjson|.payload|length' <<<"$L" 2>&1 | head -c 80) want=${#BIG}"

# --- C5: 409 on forward => rc 9, JOBS_HTTP=409; 404 => rc 2 -----------------
OUT=$(EXTRA_ENV="CURL_MODE=409" fn box_ccmd_forward c-1 box-a t p '{}'); RC=$?
[ "$RC" = 9 ] && [ "$(cat "$T/http")" = 409 ] && ok || bad "C5 409 rc=$RC http=$(cat "$T/http")"
OUT=$(EXTRA_ENV="CURL_MODE=404" fn box_ccmd_forward c-1 box-a t p '{}'); RC=$?
[ "$RC" = 2 ] && [ -z "$OUT" ] && [ "$(cat "$T/http")" = 404 ] && ok || bad "C5 404 rc=$RC out='$OUT' http=$(cat "$T/http")"

# --- C6: claim ----------------------------------------------------------------
: > "$T/req.log"
OUT=$(fn box_ccmd_claim box-a 10); RC=$?
L=$(last)
[ "$RC" = 0 ] && [ "$OUT" = '[{"command_id":"c1","box":"b1"}]' ] \
  && [ "$(jq -r .url <<<"$L")" = "https://jobs.invalid/api/box-console-commands/claim" ] \
  && [ "$(jq -c '.body|fromjson' <<<"$L")" = '{"box":"box-a","limit":10}' ] \
  && ok || bad "C6 claim rc=$RC out='$OUT' req=$L"
OUT=$(EXTRA_ENV="CURL_MODE=bad" fn box_ccmd_claim box-a 10); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "C6 claim on {} rc=$RC out='$OUT'"
: > "$T/req.log"
for a in "box-a abc" "box-a 0" "box-a" "'' 10"; do
  eval "set -- $a"
  OUT=$(fn box_ccmd_claim "$@"); RC=$?
  [ "$RC" = 1 ] && [ -z "$OUT" ] || bad "C6 claim bad input ($a) rc=$RC"
done
[ "$(reqs)" = 0 ] && ok || bad "C6 claim bad input made $(reqs) request(s)"

# --- C7: result --------------------------------------------------------------
printf 'line one\nline "two"\n' > "$T/body.txt"
: > "$T/req.log"
OUT=$(fn box_ccmd_result 'c 1/x' box-a 1 done "$T/body.txt"); RC=$?
L=$(last)
[ "$RC" = 0 ] && [ "$(jq -r .url <<<"$L")" = "https://jobs.invalid/api/box-console-commands/c%201%2Fx/result" ] \
  && [ "$(jq -r '.body|fromjson|.ok|type' <<<"$L")" = number ] \
  && [ "$(jq -r '.body|fromjson|[.box,.ok,.result]|@json' <<<"$L")" = '["box-a",1,"done"]' ] \
  && [ "$(jq -j '.body|fromjson|.body' <<<"$L")" = "$(cat "$T/body.txt")" ] \
  && [ "$(jq -r '.body|fromjson|.body|length' <<<"$L")" = "$(wc -c < "$T/body.txt")" ] \
  && ok || bad "C7 result rc=$RC req=$L"
: > "$T/req.log"
OUT=$(fn box_ccmd_result c-1 box-a 0 failed); RC=$?
[ "$RC" = 0 ] && [ "$(jq -c '.body|fromjson' <<<"$(last)")" = '{"box":"box-a","ok":0,"result":"failed","body":null}' ] \
  && ok || bad "C7 result without body rc=$RC req=$(last)"
: > "$T/req.log"
for a in "c-1 box-a 2 done" "c-1 box-a yes done" "c-1 box-a 1 done $T/nope.txt" "'' box-a 1 done" "c-1 '' 1 done"; do
  eval "set -- $a"
  OUT=$(fn box_ccmd_result "$@"); RC=$?
  [ "$RC" = 1 ] && [ -z "$OUT" ] || bad "C7 result bad input ($a) rc=$RC"
done
[ "$(reqs)" = 0 ] && ok || bad "C7 result bad input made $(reqs) request(s)"

# --- C8: expire --------------------------------------------------------------
: > "$T/req.log"
OUT=$(fn box_ccmd_expire 300); RC=$?
L=$(last)
[ "$RC" = 0 ] && [ "$OUT" = '{"expired":["c2"],"stale_claimed":[]}' ] \
  && [ "$(jq -r .url <<<"$L")" = "https://jobs.invalid/api/box-console-commands/expire" ] \
  && [ "$(jq -c '.body|fromjson' <<<"$L")" = '{"ttl_s":300}' ] \
  && ok || bad "C8 expire rc=$RC out='$OUT' req=$L"
OUT=$(EXTRA_ENV="CURL_MODE=bad" fn box_ccmd_expire 300); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "C8 expire on {} rc=$RC out='$OUT'"
: > "$T/req.log"
OUT=$(fn box_ccmd_expire -5); RC=$?
[ "$RC" = 1 ] && [ "$(reqs)" = 0 ] && ok || bad "C8 expire bad ttl rc=$RC reqs=$(reqs)"

# --- C9: worker down => rc 1 on every verb -----------------------------------
for v in "box_ccmd_forward c-1 box-a t p {}" "box_ccmd_claim box-a 10" "box_ccmd_result c-1 box-a 1 done" "box_ccmd_expire 300"; do
  # shellcheck disable=SC2086
  OUT=$(EXTRA_ENV="CURL_MODE=down" fn $v); RC=$?
  [ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "C9 down: $v rc=$RC out='$OUT'"
done

# --- C10: not a JC_MODULES module --------------------------------------------
if [ -f "$LIB" ] && grep -q '^JC_MODULES=' "$DIR/bin/jobs-client.sh" \
   && ! grep -q 'box-console-commands' <<<"$(grep '^JC_MODULES=' "$DIR/bin/jobs-client.sh")"; then ok
else bad "C10 lib missing or JC_MODULES names box-console-commands"; fi

# --- C11: no model id in the lib ---------------------------------------------
if [ -f "$LIB" ] && ! grep -qE 'claude-[a-z0-9-]+' "$LIB"; then ok; else bad "C11 lib missing or carries a model id"; fi

# --- C12: schema guard: one box_console_commands, box_commands at most one ---
n_ccmd=$(grep -cE 'CREATE TABLE IF NOT EXISTS box_console_commands\b' "$SCHEMA")
n_cmd=$(grep -cE 'CREATE TABLE IF NOT EXISTS box_commands\b' "$SCHEMA")
[ "$n_ccmd" = 1 ] && [ "$n_cmd" -le 1 ] && ok || bad "C12 schema has $n_ccmd box_console_commands and $n_cmd box_commands tables"

# --- C13: none of #2518's names in the lib -----------------------------------
if [ -f "$LIB" ] && ! grep -qE '/api/box-commands|box_cmd_|box_commands' "$LIB"; then ok; else bad "C13 lib missing or uses #2518's names"; fi

echo "box-console-commands-client: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
