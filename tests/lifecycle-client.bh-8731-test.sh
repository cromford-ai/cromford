#!/bin/bash
# contract-test: C1 pins the exact JSON body the lib sends, the wire contract
# worker/jobs/test/ticket-lifecycle.bh-8731.test.js L11 sends to the route.
# tests/lifecycle-client.bh-8731-test.sh — BH-8731 (lifecycle 1/6): the shell
# client of the ticket lifecycle routes, driven through the REAL
# bin/jobs-client.sh and its bin/jobs-client.d/ fragments, with a stub `curl`
# on PATH that records the request and answers a scripted status. 0 network.
#
#   C1  lifecycle-transition sends POST /api/lifecycle/transition with
#       {project, ticket_key, to_phase, actor, reason, pr:<number>}; question
#       only when given (an empty question is still sent); pr only when given
#   C2  the rc map: 200 -> 0 + body, 409 -> 9 + body, 404 -> 2, 500 -> 1,
#       bad args -> 3 + one usage line + no curl call, no JOBS_URL -> 1 + no curl
#   C3  lifecycle-stuck asks /api/lifecycle/stuck and ?project=<p>; both verbs
#       are in the client's usage line
# The route side is worker/jobs/test/ticket-lifecycle.bh-8731.test.js (the
# worker CI job runs it); L11 there posts the body C1 pins here.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lifecycle-client.bh-8731-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The files this suite pins (BH-2414: every new source is named by a suite).
LIB="$REPO/bin/lib/jobs/lifecycle.sh"
FRAG_T="$REPO/bin/jobs-client.d/bh-8731-lifecycle-transition.sh"
FRAG_S="$REPO/bin/jobs-client.d/bh-8731-lifecycle-stuck.sh"
WORKER_SRC=("$REPO/worker/jobs/src/lib/lifecycle.js" "$REPO/worker/jobs/src/routes/ticket-lifecycle.js"
  "$REPO/worker/jobs/src/lib/core.d/bh-8731-lifecycle.js" "$REPO/worker/jobs/src/routes/retention.d/bh-8731-ticket-events.js")
for f in "$LIB" "$FRAG_T" "$FRAG_S" "${WORKER_SRC[@]}"; do
  [ -f "$f" ] || bad "missing source ${f#"$REPO"/}"
done

# A scratch harness: the client's closure (bin/lib/jobs/*.sh, lifecycle.sh
# included) plus the two fragments, and a stub curl.
H="$T/h"
mkdir -p "$H/env" "$H/logs" "$T/stub" || exit 1
: > "$H/env/global.env"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/jobs-client.d/bh-8731-lifecycle-transition.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/jobs-client.d/bh-8731-lifecycle-stuck.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
[ -f "$H/bin/lib/jobs/lifecycle.sh" ] || bad "the closure did not install bin/lib/jobs/lifecycle.sh"

cat > "$T/stub/curl" <<'SH'
#!/bin/bash
# Records "<method> <url>" to $STUB_LOG and the body to $STUB_BODY; prints
# $STUB_ANSWER, a newline and $STUB_CODE (the -w '\n%{http_code}' shape).
m=GET body="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift 2 ;;
    --data-binary) body="$2"; shift 2 ;;
    -m|--connect-timeout|-H|-w) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s %s\n' "$m" "$url" >> "$STUB_LOG"
printf '%s' "$body" > "$STUB_BODY"
printf '%s\n%s' "$STUB_ANSWER" "$STUB_CODE"
SH
chmod +x "$T/stub/curl"

URL=https://jobs.example.test
# jc <code> <answer> <args...> — run the client; stdout $T/out, stderr $T/err, rc $RC.
jc() {
  local code=$1 answer=$2; shift 2
  : > "$T/log"; : > "$T/body"
  env -u JOBS_URL PATH="$T/stub:$PATH" HARNESS="$H" HARNESS_ENV_DIR="$H/env" JOBS_HARNESS="$H" \
    HARNESS_SECRET=tok-fixture-1 JOBS_URL="${JC_URL-$URL}" JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 \
    STUB_LOG="$T/log" STUB_BODY="$T/body" STUB_CODE="$code" STUB_ANSWER="$answer" \
    bash "$H/bin/jobs-client.sh" "$@" >"$T/out" 2>"$T/err"
  RC=$?
}
calls() { grep -c . "$T/log"; }

# ══ C1. the body ════════════════════════════════════════════════════════════
echo "C1 lifecycle-transition body"
jc 200 '{"ok":true}' lifecycle-transition project-3 TK-1 planned pool "plan ok" 12
[ "$RC" = 0 ] && [ "$(cat "$T/log")" = "POST $URL/api/lifecycle/transition" ] \
  && ok "C1 POST /api/lifecycle/transition, rc 0" || bad "C1 rc=$RC log=$(cat "$T/log")"
want='{"actor":"pool","pr":12,"project":"project-3","reason":"plan ok","ticket_key":"TK-1","to_phase":"planned"}'
[ "$(jq -cS . "$T/body")" = "$want" ] && [ "$(jq -r '.pr|type' "$T/body")" = number ] \
  && ok "C1 body = the route's fields, pr a number, no question" || bad "C1 body $(cat "$T/body")"
jc 200 '{"ok":true}' lifecycle-transition project-3 TK-2 plan_blocked pool "needs answer" "" "which fee?"
[ "$RC" = 0 ] && [ "$(jq -c '[has("pr"), .question]' "$T/body")" = '[false,"which fee?"]' ] \
  && ok "C1 question sent when given; an empty pr is not sent" || bad "C1 question rc=$RC body $(cat "$T/body")"
jc 200 '{"ok":true}' lifecycle-transition project-3 TK-3 plan_blocked pool "r" "" ""
[ "$(jq -c 'has("question")' "$T/body")" = true ] \
  && ok "C1 an empty question is sent (the route decides)" || bad "C1 empty question $(cat "$T/body")"
jc 200 '{"ok":true}' lifecycle-transition project-3 "TK-4" building pool 'a "quoted" reason; $(id)'
[ "$(jq -r .reason "$T/body")" = 'a "quoted" reason; $(id)' ] \
  && ok "C1 the reason is JSON-escaped, never evaluated" || bad "C1 reason $(cat "$T/body")"

# ══ C2. the rc map ══════════════════════════════════════════════════════════
echo "C2 rc map"
jc 200 '{"ok":true,"event_id":7}' lifecycle-transition p K-1 triaged triage r
[ "$RC" = 0 ] && [ "$(jq -r .event_id "$T/out")" = 7 ] && ok "C2 200 -> rc 0, the body on stdout" || bad "C2 200 rc=$RC out=$(cat "$T/out")"
jc 409 '{"error":"wrong_owner","owners":["lifecycle"]}' lifecycle-transition p K-1 in_queue conductor r
[ "$RC" = 9 ] && [ "$(jq -r .error "$T/out")" = wrong_owner ] && ok "C2 409 -> rc 9, the body on stdout" || bad "C2 409 rc=$RC out=$(cat "$T/out")"
jc 404 '{"error":"no_row"}' lifecycle-transition p K-1 triaged triage r
[ "$RC" = 2 ] && ok "C2 404 -> rc 2" || bad "C2 404 rc=$RC"
jc 500 '{"error":"boom"}' lifecycle-transition p K-1 triaged triage r
[ "$RC" = 1 ] && ok "C2 500 -> rc 1" || bad "C2 500 rc=$RC"
jc 400 '{"error":"actor"}' lifecycle-transition p K-1 triaged Pool r
[ "$RC" = 1 ] && ok "C2 400 -> rc 1" || bad "C2 400 rc=$RC"
for args in "p K-1 triaged triage" "p K-1 triaged triage r 0" "p K-1 triaged triage r 12x" "p '' triaged triage r" "a b c d e 1 q extra"; do
  eval "set -- $args"
  jc 200 '{}' lifecycle-transition "$@"
  [ "$RC" = 3 ] && [ "$(calls)" = 0 ] && grep -q '^usage: lifecycle-transition <project>' "$T/err" \
    && ok "C2 bad args ($args) -> rc 3, usage, no request" || bad "C2 bad args ($args) rc=$RC calls=$(calls) err=$(cat "$T/err")"
done
JC_URL='' jc 200 '{}' lifecycle-transition p K-1 triaged triage r
[ "$RC" = 1 ] && [ "$(calls)" = 0 ] && ok "C2 no JOBS_URL -> rc 1, no request" || bad "C2 no url rc=$RC calls=$(calls)"
JC_URL='' jc 200 '{}' lifecycle-stuck
[ "$RC" = 1 ] && [ "$(calls)" = 0 ] && ok "C2 lifecycle-stuck with no JOBS_URL -> rc 1, no request" || bad "C2 stuck no url rc=$RC"

# ══ C3. lifecycle-stuck and the usage ═══════════════════════════════════════
echo "C3 lifecycle-stuck"
jc 200 '{"rows":[]}' lifecycle-stuck
[ "$RC" = 0 ] && [ "$(cat "$T/log")" = "GET $URL/api/lifecycle/stuck" ] && [ "$(jq -c .rows "$T/out")" = '[]' ] \
  && ok "C3 no project -> GET /api/lifecycle/stuck" || bad "C3 rc=$RC log=$(cat "$T/log")"
jc 200 '{"rows":[]}' lifecycle-stuck project-3
[ "$RC" = 0 ] && [ "$(cat "$T/log")" = "GET $URL/api/lifecycle/stuck?project=project-3" ] \
  && ok "C3 project -> ?project=project-3" || bad "C3 project rc=$RC log=$(cat "$T/log")"
jc 200 '{}' lifecycle-stuck "a b&c"
[ "$(cat "$T/log")" = "GET $URL/api/lifecycle/stuck?project=a%20b%26c" ] \
  && ok "C3 the project is URI-encoded" || bad "C3 encode log=$(cat "$T/log")"
jc 200 '{}' lifecycle-stuck a b
[ "$RC" = 3 ] && [ "$(calls)" = 0 ] && ok "C3 two args -> rc 3, no request" || bad "C3 two args rc=$RC"
jc 200 '{}' no-such-verb-8731
u=$(cat "$T/err")
[[ $u == *"lifecycle-transition <project> <ticket_key> <to_phase> <actor> <reason> [pr] [question]"* && $u == *"lifecycle-stuck [project]"* ]] \
  && ok "C3 both verbs are in the usage line" || bad "C3 usage: ${u: -200}"

echo "lifecycle-client: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
