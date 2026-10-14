#!/bin/bash
# tests/dequeue-watch-contract.bh-3719-test.sh — BH-3727 (BH-3719.1): the real
# dqw_* client bodies in bin/lib/jobs/dequeue-watch.sh. The REAL lib is sourced
# and _jobs_req is redefined after it to log `METHOD PATH BODY` and answer from
# $STUB_RC / $STUB_OUT, the way bin/lib/jobs/req.sh does (rc 0 prints the body,
# rc 9 is a 409 that prints it, rc 2 is a 404, rc 1 anything else).
#   W1      the worker route module exists, parses, and index.js spreads it into ROUTES
#   C-PATH  each of the 8 verbs sends the right method, path and body
#   C-OK    a good answer prints the compact shape, rc 0
#   C-FAIL  stub rc 1 / 2 / 9 and a shape-wrong 2xx -> rc 1, 0 bytes, every verb
#   C-ARG   bad head/class/action/status/json/arity -> rc 1, 0 bytes, no request
#   C-RC    dqw_rounds_count never prints 0 on an unreadable answer
# Run: HARNESS_TEST_SANDBOX=1 bash tests/dequeue-watch-contract.bh-3719-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

LIB="$DIR/bin/lib/jobs/dequeue-watch.sh"
ROUTE="$DIR/worker/jobs/src/routes/dequeue-watch.js"
[ -f "$LIB" ] && bash -n "$LIB" 2>/dev/null && ok || bad "missing or unparseable $LIB"
grep -q '/root/harness' "$LIB" && bad "$LIB carries a /root/harness literal (D43)" || ok

# --- W1 ------------------------------------------------------------------------
if [ -f "$ROUTE" ] && node --check "$ROUTE" 2>/dev/null; then ok; else bad "W1 missing or unparseable $ROUTE"; fi
# TEST-CHANGE (BH-4607): a family is registered by its route-table.d fragment; index.js no longer lists gated families.
[ "$(ls "$DIR"/worker/jobs/test/route-table.d/[0-9][0-9][0-9]-dequeue-watch.txt 2>/dev/null | wc -l)" = 1 ] && ok \
  || bad "dequeue-watch has no route-table.d fragment (BH-4607: the fragment IS the registration)"
W1=$(cd "$DIR/worker/jobs" && node --input-type=module -e '
  const { ROUTES } = (await import("./src/index.js")).default;
  console.log(ROUTES.filter(([, m]) => typeof m === "string" && m.startsWith("/api/dequeue-watch/")).map(([v, m]) => v + " " + m).join("|"));
' 2>&1)
[ "$W1" = "POST /api/dequeue-watch/events|PUT /api/dequeue-watch/events/state|GET /api/dequeue-watch/events|POST /api/dequeue-watch/actions/claim|PUT /api/dequeue-watch/actions/state|GET /api/dequeue-watch/actions|GET /api/dequeue-watch/summary" ] \
  && ok || bad "W1 ROUTES dequeue-watch entries: $W1"

CALLS="$T/calls.log"
export CALLS LIB
STUBS='_jobs_req() { printf "%s %s %s\n" "$1" "$2" "${3:-}" >> "$CALLS"; case "$STUB_RC" in 0) printf "%s" "$STUB_OUT"; return 0 ;; 9) printf "%s" "$STUB_OUT"; return 9 ;; *) return "$STUB_RC" ;; esac; }'
export STUBS

# dq <stub rc> <stub out> <fn> <args...> — one verb from the real lib, stubbed transport.
dq() {
  local rc="$1" sout="$2"; shift 2; : > "$CALLS"
  STUB_RC="$rc" STUB_OUT="$sout" bash -c '
    . "$LIB" || exit 99
    eval "$STUBS"
    "$@"' _ "$@" > "$T/out" 2> "$T/err"
  echo $? > "$T/vrc"
}
out() { cat "$T/out"; }
vrc() { cat "$T/vrc"; }
bytes() { wc -c < "$T/out" | tr -d ' '; }
ncalls() { grep -c . "$CALLS"; }
mp() { cut -d' ' -f1-2 "$CALLS"; }
body() { sed -n "1s/^[A-Z]* [^ ]* //p" "$CALLS"; }

HEAD=0123456789abcdef0123456789abcdef01234567
UHEAD=0123456789ABCDEF0123456789ABCDEF01234567
SINCE=2026-09-30T00:00:00Z
ROW='{"repo":"o/r","pr":12}'

# --- C-PATH + C-OK ---------------------------------------------------------------
dq 0 "{\"recorded\":true,\"first\":true,\"row\":$ROW,\"x\":1}" dqw_event_record O/R 12 "$UHEAD" 99 bh '{"run_url":"u","members":[12]}'
[ "$(vrc)" = 0 ] && [ "$(out)" = "{\"recorded\":true,\"first\":true,\"row\":$ROW}" ] && ok || bad "C-OK event_record rc=$(vrc) out=$(out)"
[ "$(mp)" = "POST /api/dequeue-watch/events" ] && ok || bad "C-PATH event_record: $(cat "$CALLS")"
[ "$(body | jq -c '[.repo,.pr,.head,.run_id,.project,.extra]')" = "[\"o/r\",12,\"$HEAD\",\"99\",\"bh\",{\"run_url\":\"u\",\"members\":[12]}]" ] \
  && ok || bad "C-PATH event_record body: $(body)"

dq 0 "{\"row\":$ROW,\"fail_lines_truncated\":true}" dqw_event_state o/r 12 "$HEAD" 99 '{"class":"flake","rule_id":"x"}'
[ "$(vrc)" = 0 ] && [ "$(out)" = "{\"row\":$ROW,\"fail_lines_truncated\":true}" ] && ok || bad "C-OK event_state rc=$(vrc) out=$(out)"
[ "$(mp)" = "PUT /api/dequeue-watch/events/state" ] && ok || bad "C-PATH event_state: $(cat "$CALLS")"
[ "$(body | jq -c '[.repo,.pr,.head,.run_id,.class,.rule_id]')" = "[\"o/r\",12,\"$HEAD\",\"99\",\"flake\",\"x\"]" ] && ok || bad "C-PATH event_state body: $(body)"

dq 0 '{"rows":[],"truncated":false,"as_of":"x"}' dqw_events_list o/r 12 "$SINCE" fp
[ "$(vrc)" = 0 ] && [ "$(out)" = '{"rows":[],"truncated":false}' ] && ok || bad "C-OK events_list rc=$(vrc) out=$(out)"
[ "$(mp)" = "GET /api/dequeue-watch/events?repo=o%2Fr&pr=12&since=2026-09-30T00%3A00%3A00Z&llm_fp=fp" ] && ok || bad "C-PATH events_list: $(cat "$CALLS")"
dq 0 '{"rows":[],"truncated":false}' dqw_events_list o/r "" "" fp
[ "$(mp)" = "GET /api/dequeue-watch/events?repo=o%2Fr&llm_fp=fp" ] && ok || bad "C-PATH events_list empty positionals: $(cat "$CALLS")"

dq 0 "{\"claimed\":false,\"row\":$ROW}" dqw_action_claim o/r 12 "$HEAD" flake requeue bh
[ "$(vrc)" = 0 ] && [ "$(out)" = "{\"claimed\":false,\"row\":$ROW}" ] && ok || bad "C-OK action_claim rc=$(vrc) out=$(out)"
[ "$(mp)" = "POST /api/dequeue-watch/actions/claim" ] && ok || bad "C-PATH action_claim: $(cat "$CALLS")"
[ "$(body | jq -c '[.repo,.pr,.head,.class,.action,.project]')" = "[\"o/r\",12,\"$HEAD\",\"flake\",\"requeue\",\"bh\"]" ] && ok || bad "C-PATH action_claim body: $(body)"

dq 0 "{\"row\":$ROW}" dqw_action_set o/r 12 "$HEAD" flake done ref1 note1 requeue
[ "$(vrc)" = 0 ] && [ "$(out)" = "$ROW" ] && ok || bad "C-OK action_set rc=$(vrc) out=$(out)"
[ "$(mp)" = "PUT /api/dequeue-watch/actions/state" ] && ok || bad "C-PATH action_set: $(cat "$CALLS")"
[ "$(body | jq -c '[.repo,.pr,.head,.class,.status,.ref,.note,.action]')" = "[\"o/r\",12,\"$HEAD\",\"flake\",\"done\",\"ref1\",\"note1\",\"requeue\"]" ] \
  && ok || bad "C-PATH action_set body: $(body)"
dq 0 "{\"row\":$ROW}" dqw_action_set o/r 12 "$HEAD" flake failed
[ "$(body | jq -c 'keys')" = '["class","head","pr","repo","status"]' ] && ok || bad "C-PATH action_set omits absent optionals: $(body)"

dq 0 '{"rows":[{"a":1}],"truncated":true}' dqw_actions_list o/r 12 "$HEAD" flake requeue claimed
[ "$(vrc)" = 0 ] && [ "$(out)" = '{"rows":[{"a":1}],"truncated":true}' ] && ok || bad "C-OK actions_list rc=$(vrc) out=$(out)"
[ "$(mp)" = "GET /api/dequeue-watch/actions?repo=o%2Fr&pr=12&head=$HEAD&class=flake&action=requeue&status=claimed" ] && ok || bad "C-PATH actions_list: $(cat "$CALLS")"
dq 0 '{"rows":[],"truncated":false}' dqw_actions_list "" "" "" "" main-red-wait waiting
[ "$(mp)" = "GET /api/dequeue-watch/actions?action=main-red-wait&status=waiting" ] && ok || bad "C-PATH actions_list across repos: $(cat "$CALLS")"

dq 0 '{"rows":[{},{},{}],"truncated":false}' dqw_rounds_count o/r 12 flake
[ "$(vrc)" = 0 ] && [ "$(out)" = 3 ] && ok || bad "C-OK rounds_count rc=$(vrc) out=$(out)"
[ "$(mp)" = "GET /api/dequeue-watch/actions?repo=o%2Fr&pr=12&class=flake&action=fix-round&limit=500" ] && ok || bad "C-PATH rounds_count: $(cat "$CALLS")"

SUM='{"by_class":{"flake":2},"requeues":1,"mean_requeue_s":null,"fix_rounds":{"claimed":0,"done":0,"failed":0},"holds":0,"unowned_now":null}'
dq 0 "$SUM" dqw_summary "$SINCE"
[ "$(vrc)" = 0 ] && [ "$(out)" = "$SUM" ] && ok || bad "C-OK summary rc=$(vrc) out=$(out)"
[ "$(mp)" = "GET /api/dequeue-watch/summary?since=2026-09-30T00%3A00%3A00Z" ] && ok || bad "C-PATH summary: $(cat "$CALLS")"
dq 0 "$SUM" dqw_summary
[ "$(mp)" = "GET /api/dequeue-watch/summary" ] && ok || bad "C-PATH summary without since: $(cat "$CALLS")"

# --- C-FAIL ----------------------------------------------------------------------
# verb args, one per line: every verb with arguments that pass the client checks.
VERBS=(
  "dqw_event_record o/r 12 $HEAD 99 bh {}"
  "dqw_event_state o/r 12 $HEAD 99 {\"class\":\"flake\"}"
  "dqw_events_list o/r 12 $SINCE fp"
  "dqw_action_claim o/r 12 $HEAD flake requeue bh"
  "dqw_action_set o/r 12 $HEAD flake done ref note requeue"
  "dqw_actions_list o/r 12 $HEAD flake requeue claimed"
  "dqw_rounds_count o/r 12 flake"
  "dqw_summary $SINCE"
)
for v in "${VERBS[@]}"; do
  read -r -a argv <<< "$v"
  for case in "1|" "2|" "9|{\"error\":\"conflict\",\"rows\":[],\"truncated\":false,\"row\":{}}" "0|{}" "0|not json"; do
    dq "${case%%|*}" "${case#*|}" "${argv[@]}"
    [ "$(vrc)" = 1 ] && [ "$(bytes)" = 0 ] && ok || bad "C-FAIL ${argv[0]} stub '${case}' -> rc=$(vrc) out=$(out)"
    [ "$(ncalls)" = 1 ] && ok || bad "C-FAIL ${argv[0]} stub '${case}' made $(ncalls) requests"
  done
done

# --- C-ARG -----------------------------------------------------------------------
ARGS=(
  "dqw_event_record o/r 12 ${HEAD:1} 99 bh {}"
  "dqw_event_record o/r 12 ${HEAD:1}g 99 bh {}"
  "dqw_event_record o/r x12 $HEAD 99 bh {}"
  "dqw_event_record o/r 12 $HEAD 99 bh []"
  "dqw_event_record o/r 12 $HEAD 99 bh notjson"
  "dqw_event_record o/r 12 $HEAD 99 bh"
  "dqw_event_state o/r 12 $HEAD 99 [1]"
  "dqw_event_state o/r 12 $HEAD 99"
  "dqw_events_list"
  "dqw_events_list o/r x"
  "dqw_events_list o/r 1 2 3 4"
  "dqw_action_claim o/r 12 $HEAD oops requeue bh"
  "dqw_action_claim o/r 12 $HEAD flake merge bh"
  "dqw_action_claim o/r 12 $HEAD flake requeue"
  "dqw_action_set o/r 12 $HEAD flake ok"
  "dqw_action_set o/r 12 $HEAD flake done r n merge"
  "dqw_action_set o/r 12 $HEAD oops done"
  "dqw_action_set o/r 12 $HEAD flake"
  "dqw_actions_list o/r 12 zz"
  "dqw_actions_list o/r 12 $HEAD oops"
  "dqw_actions_list o/r 12 $HEAD flake merge"
  "dqw_actions_list o/r 12 $HEAD flake requeue ok"
  "dqw_rounds_count o/r 12 oops"
  "dqw_rounds_count o/r x flake"
  "dqw_rounds_count o/r 12"
  "dqw_summary a b"
)
for v in "${ARGS[@]}"; do
  read -r -a argv <<< "$v"
  dq 0 '{"recorded":true,"first":true,"row":{},"claimed":true,"rows":[],"truncated":false,"by_class":{},"requeues":0}' "${argv[@]}"
  [ "$(vrc)" = 1 ] && [ "$(bytes)" = 0 ] && [ "$(ncalls)" = 0 ] && ok || bad "C-ARG '$v' -> rc=$(vrc) out=$(out) calls=$(ncalls)"
done

# --- C-RC1..5 --------------------------------------------------------------------
for case in "1|" "2|" "0|x" "0|{}" '0|{"rows":[],"truncated":true}' '0|{"rows":{},"truncated":false}' '0|{"rows":[]}'; do
  dq "${case%%|*}" "${case#*|}" dqw_rounds_count o/r 12 flake
  [ "$(vrc)" = 1 ] && [ "$(bytes)" = 0 ] && ok || bad "C-RC stub '${case}' -> rc=$(vrc) out='$(out)' (never a 0)"
done
dq 0 '{"rows":[],"truncated":false}' dqw_rounds_count o/r 12 flake
[ "$(vrc)" = 0 ] && [ "$(out)" = 0 ] && ok || bad "C-RC a measured empty list -> rc=$(vrc) out='$(out)', want 0"

echo "dequeue-watch-contract: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
