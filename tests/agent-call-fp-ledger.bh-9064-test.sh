#!/bin/bash
# tests/agent-call-fp-ledger.bh-9064-test.sh — BH-9064 (slice C0), DEDUP BEFORE
# SPEND at bin/agent-call.sh.
#
# bin/agent-call.sh asks the persisted agent-call ledger (D1 table
# agent_call_ledger, routes worker/jobs/src/routes/agent-call-ledger.js) on the
# call's fingerprint BEFORE the model call:
#   * an `ok` row of a replay stage inside the window replays the stored answer
#     and makes no vendor call;
#   * an `empty` row, or a `failed` row at the attempt cap, is terminal: the
#     stored rc comes back, one LEDGER TERMINAL log line, no vendor call;
#   * a fresh fingerprint runs.
# A call with no AGENT_CALL_FP is keyed on call_guard_fp "$PROMPT_SHA" (K3's own
# fallback) and is never replayed.
#
# Everything here DRIVES the real bin/agent-call.sh against a fake claude on
# PATH and the REAL jobs worker on a node:sqlite file
# (tests/lib/ledger-worker-fake.bh-9064.sh): no network, no vendor. Each case
# uses its own fingerprint and the suite its own scratch DB, so the cases do
# not depend on order and parallel runs share nothing.
#
#   L1  two calls, one fp, stage review: 1 vendor call
#   L2  the two answers are byte-identical; 1 row ok attempts=1; 1 LEDGER
#       REPLAY line; the replay's cost row is zero-cost, note agent-call-ledger:replay
#   L3  a failed row at attempts=3, K3 review=3: 0 vendor calls, the stored rc
#       124, 1 LEDGER TERMINAL failed line, a zero-cost row, and the same fp on
#       another stage runs. L3h: the same row with K3 review=6 runs (the
#       ledger cap is never below the stage's K3 ceiling)
#   L4  an rc-0 is_error envelope settles failed, never ok
#   L5  a blank answer at rc 0 settles empty; the next call is 0 calls, rc 0, empty $OUT
#   L6  stage execute with an ok row runs again (not a replay stage)
#   L7  no JOBS_URL: 2 calls are 2 vendor calls, no ledger line
#   L8  no AGENT_CALL_FP: the row's fp is call_guard_fp "$PROMPT_SHA"; no replay
#   L9  the decision rows the shell path reaches: failed attempts=2 runs (3rd
#       attempt); a row past the window restarts; running inside the TTL is
#       rc 74; another project's row is another key; a 404 ledger fails open
#   L10 an answer over AGENT_LEDGER_ANSWER_MAX_BYTES settles ok with no body and
#       its size, and the next call runs (never a replay)
#   L11 AGENT_LEDGER=0: no row, no ledger line, every call runs
#
# Run from anywhere: tests/agent-call-fp-ledger.bh-9064-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
. "$DIR/tests/lib/ledger-worker-fake.bh-9064.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v node >/dev/null || { echo "node missing — skipping"; exit 0; }
node -e 'require("node:sqlite")' 2>/dev/null || { echo "node:sqlite missing — skipping"; exit 0; }

mkdir -p "$T/bin/lib/jobs" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state"
mrs_fixture "$T" testproj otherproj
( cd "$DIR" && scratch_install_closure bin/jobs-client.sh "$T" ) >/dev/null || { echo "FAIL: closure of bin/jobs-client.sh"; exit 1; }
cp "$DIR/bin/billing-mode.sh" "$T/bin/billing-mode.sh"
lwf_install "$T/fakebin" "$T/jobs.db"

# The fake vendor. It counts its calls and answers with the count, so two real
# calls in one case give two different answers. An argv it does not know is
# exit 99 (no real vendor is ever reached).
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$ORDER_SINK"
case " $* " in *" -p "*|*" --print "*) ;; *) echo "fake claude: unknown argv $*" >&2; exit 99 ;; esac
case "${CLAUDE_RESULT:-ok}" in
  empty)  echo '{"result":"","usage":{"input_tokens":10,"output_tokens":0},"total_cost_usd":0.01}'; exit 0 ;;
  errenv) echo '{"is_error":true,"api_error_status":500,"result":"API Error: overloaded"}'; exit 0 ;;
  *)      echo "{\"result\":\"answer $(grep -c . "$ORDER_SINK")\",\"usage\":{\"input_tokens\":10,\"output_tokens\":2},\"total_cost_usd\":0.01}"; exit 0 ;;
esac
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh

LOG="$T/logs/agent-call-ledger.log"
# call <out-name> <stage> <prompt> [VAR=VAL ...] -> prints the rc.
call() {
  local out="$1" stage="$2" prompt="$3"; shift 3
  ( unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE AGENT_CALL_TICKET HARNESS_TICKET AGENT_LEDGER \
          AGENT_LEDGER_STAGES AGENT_LEDGER_REPLAY_STAGES AGENT_LEDGER_WINDOW_S
    export ORDER_SINK="$T/order" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           JOBS_URL="https://jobs.test" HARNESS_SECRET="tok-fixture-bh9064" LWF_SECRET="tok-fixture-bh9064" \
           JOBS_RETRIES=0 JOBS_BOX=testbox \
           CLAUDE_CODE_OAUTH_TOKEN=tok-fixture ANTHROPIC_API_KEY= \
           OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= OPENAI_API_KEY= ACCOUNT_ROUTING=0 \
           LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 CLAUDE_RESULT=ok \
           AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 RUNNER_REVIEW=claude RUNNER_REVIEW_FALLBACK= \
           RUNNER_EXECUTE=claude RUNNER_EXECUTE_FALLBACK= RUNNER_PLAN=claude RUNNER_PLAN_FALLBACK= \
           CALL_GUARD_MAX_MAP="default=50" \
           LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" "$@"
    cd "$T" && bash "$DIR/bin/agent-call.sh" "$stage" "${CALL_PROJECT:-testproj}" claude-fable-5-1 60 "$T/$out" "$prompt" \
      >/dev/null 2>&1 )
  echo $?
}
reset() { : > "$T/order"; : > "$LOG"; }
vendor_calls() { grep -c . "$T/order" 2>/dev/null || true; }
row() { # row <project> <stage> <fp> -> "status attempts rc"
  lwf_sql "SELECT status, attempts, rc FROM agent_call_ledger WHERE project=? AND stage=? AND fp=?" "$1" "$2" "$3" \
    | jq -r '"\(.status) \(.attempts) \(.rc)"'
}
nrows() { lwf_sql "SELECT COUNT(*) AS n FROM agent_call_ledger WHERE fp=?" "$1" | jq -r .n; }
seed() { # seed <project> <stage> <fp> <status> <attempts> <rc|null> [body]
  local rcv="$6" body="${7:-}"
  lwf_sql "INSERT OR REPLACE INTO agent_call_ledger (project,stage,fp,status,attempts,rc,answer_body,answer_bytes,first_at,last_at)
           VALUES (?,?,?,?,?,${rcv},?,?,strftime('%Y-%m-%dT%H:%M:%SZ','now'),strftime('%Y-%m-%dT%H:%M:%SZ','now'))" \
    "$1" "$2" "$3" "$4" "$5" "$body" "${#body}"
}
lines() { grep -c "$1" "$LOG" 2>/dev/null || true; }
# cost_rows <fp> — the cost rows that name this fp (guard_fp is the last column).
cost_rows() { grep -F ",$1" "$T/logs/cost.csv" 2>/dev/null || true; }

# --- L1/L2. two calls, one fingerprint, inside the hour: 1 vendor call -------
reset
FP1="review-prs:acme/app#901@aaaa111"
r1=$(call o1a review "review 901 at aaaa111" AGENT_CALL_FP="$FP1")
r2=$(call o1b review "review 901 at aaaa111" AGENT_CALL_FP="$FP1")
[ "$r1" = 0 ] && [ "$r2" = 0 ] && ok || bad "L1a rcs $r1 $r2, want 0 0"
[ "$(vendor_calls)" = 1 ] && ok || bad "L1b the vendor was called $(vendor_calls) times, want 1"
if [ -s "$T/o1a" ] && cmp -s "$T/o1a" "$T/o1b"; then ok; else bad "L2a the two answers differ: '$(cat "$T/o1a" 2>/dev/null)' vs '$(cat "$T/o1b" 2>/dev/null)'"; fi
[ "$(nrows "$FP1")" = 1 ] && ok || bad "L2b ledger rows for the fp: $(nrows "$FP1"), want 1"
[ "$(row testproj review "$FP1")" = "ok 1 0" ] && ok || bad "L2c ledger row '$(row testproj review "$FP1")', want 'ok 1 0'"
[ "$(lines 'LEDGER REPLAY')" = 1 ] && ok || bad "L2d LEDGER REPLAY lines: $(lines 'LEDGER REPLAY'), want 1 ($(cat "$LOG"))"
[ -f "$T/o1b.replay" ] && ok || bad "L2e the replay left no .replay marker"
rr=$(cost_rows "$FP1" | grep 'agent-call-ledger:replay')
[ "$(grep -c . <<<"$rr")" = 1 ] && [ "$(cut -d, -f13 <<<"$rr")" = 0 ] && ok \
  || bad "L2f want 1 zero-cost row with note agent-call-ledger:replay, got: $(cost_rows "$FP1")"

# --- L3. a failed row at attempts=3: 0 vendor calls, the stored rc -----------
reset
FP3="review-prs:acme/app#903@cccc333"
seed testproj review "$FP3" failed 3 124
# K3's review ceiling is 3 here, so the stage's ledger cap is 3 (the knob's 3).
r=$(call o3 review "review 903" AGENT_CALL_FP="$FP3" CALL_GUARD_MAX_MAP="review=3 default=50")
[ "$r" = 124 ] && ok || bad "L3a rc $r, want the stored rc 124"
[ "$(vendor_calls)" = 0 ] && ok || bad "L3b the vendor was called $(vendor_calls) times, want 0"
[ "$(lines 'LEDGER TERMINAL failed')" = 1 ] && ok || bad "L3c LEDGER TERMINAL failed lines: $(lines 'LEDGER TERMINAL failed'), want 1"
grep -q "^AGENT_CALL_REFUSED call-guard repeat ledger-failed attempts=3 fp=" "$T/o3.err" 2>/dev/null && ok \
  || bad "L3d refusal marker in \$OUT.err: '$(head -1 "$T/o3.err" 2>/dev/null)'"
[ "$(row testproj review "$FP3")" = "failed 3 124" ] && ok || bad "L3e the terminal read changed the row: '$(row testproj review "$FP3")'"
rr=$(cost_rows "$FP3" | grep 'agent-call-ledger:terminal')
[ "$(grep -c . <<<"$rr")" = 1 ] && [ "$(cut -d, -f13 <<<"$rr")" = 0 ] && ok \
  || bad "L3f want 1 zero-cost row with note agent-call-ledger:terminal, got: $(cost_rows "$FP3")"
r=$(call o3x lead-review "review 903" AGENT_CALL_FP="$FP3")
[ "$r" = 0 ] && [ "$(vendor_calls)" = 1 ] && ok || bad "L3g the same fp on another stage was refused (rc $r calls $(vendor_calls))"
reset
seed testproj review "$FP3" failed 3 124
r=$(call o3h review "review 903" AGENT_CALL_FP="$FP3" CALL_GUARD_MAX_MAP="review=6 default=50")
[ "$r" = 0 ] && [ "$(vendor_calls)" = 1 ] && [ "$(row testproj review "$FP3" | cut -d' ' -f1-2)" = "ok 4" ] && ok \
  || bad "L3h K3 review=6: rc $r calls $(vendor_calls) row '$(row testproj review "$FP3")', want 0 1 'ok 4' (the ledger cut a rung K3 allowed)"

# --- L4. an rc-0 error envelope is failed, never ok --------------------------
reset
FP4="review-prs:acme/app#904@dddd444"
r=$(call o4a review "review 904" AGENT_CALL_FP="$FP4" CLAUDE_RESULT=errenv)
st=$(row testproj review "$FP4")
[ "${st%% *}" = failed ] && ok || bad "L4a an error envelope settled '$st', want failed"
r=$(call o4b review "review 904" AGENT_CALL_FP="$FP4")
[ "$(vendor_calls)" = 2 ] && [ "$(lines 'LEDGER REPLAY')" = 0 ] && ok || bad "L4b an error envelope was replayed (calls $(vendor_calls))"

# --- L5. a blank answer settles empty, and empty is terminal -----------------
reset
FP5="review-prs:acme/app#905@eeee555"
r=$(call o5a review "review 905" AGENT_CALL_FP="$FP5" CLAUDE_RESULT=empty)
[ "$(row testproj review "$FP5")" = "empty 1 0" ] && ok || bad "L5a a blank answer settled '$(row testproj review "$FP5")', want 'empty 1 0'"
r=$(call o5b review "review 905" AGENT_CALL_FP="$FP5")
[ "$r" = 0 ] && [ "$(vendor_calls)" = 1 ] && ok || bad "L5b empty row: rc $r calls $(vendor_calls), want 0 and still 1"
grep -q '[^[:space:]]' "$T/o5b" 2>/dev/null && bad "L5c an empty terminal handed back text: '$(head -1 "$T/o5b")'" || ok
[ "$(lines 'LEDGER TERMINAL empty')" = 1 ] && ok || bad "L5d no LEDGER TERMINAL empty line: $(cat "$LOG")"

# --- L6. an execute ok row is never replayed: the call runs ------------------
reset
FP6="BH-906:thfeedfacefeedface:m0123456789ab"
seed testproj execute "$FP6" ok 1 0 "the execute transcript"
r=$(call o6 execute "execute the plan" AGENT_CALL_FP="$FP6")
[ "$r" = 0 ] && [ "$(vendor_calls)" = 1 ] && ok || bad "L6a execute ok row: rc $r calls $(vendor_calls), want 0 1 (no replay)"
[ "$(row testproj execute "$FP6")" = "ok 2 0" ] && ok || bad "L6b row '$(row testproj execute "$FP6")', want 'ok 2 0' (the attempt counts)"
[ "$(lines 'LEDGER REPLAY')" = 0 ] && ok || bad "L6c an execute row was replayed"

# --- L7. no JOBS_URL: fail open ----------------------------------------------
reset
FP7="review-prs:acme/app#907@ffff777"
r1=$(call o7a review "review 907" AGENT_CALL_FP="$FP7" JOBS_URL=)
r2=$(call o7b review "review 907" AGENT_CALL_FP="$FP7" JOBS_URL=)
[ "$r1" = 0 ] && [ "$r2" = 0 ] && [ "$(vendor_calls)" = 2 ] && ok || bad "L7a no JOBS_URL: rcs $r1 $r2 calls $(vendor_calls), want 0 0 2"
[ -s "$LOG" ] && bad "L7b a ledger line was written with no JOBS_URL: $(cat "$LOG")" || ok
[ "$(nrows "$FP7")" = 0 ] && ok || bad "L7c a row was written with no JOBS_URL"

# --- L8. no AGENT_CALL_FP: the fp is call_guard_fp "$PROMPT_SHA" -------------
reset
P8="review the BH-908 lens"
r=$(call o8a review "$P8" AGENT_CALL_TICKET=BH-908)
psha=$(printf '%s' "$P8" | sha256sum | cut -d' ' -f1)
want8=$(cd "$T" && unset AGENT_CALL_FP HARNESS_TICKET; AGENT_CALL_TICKET=BH-908; . "$DIR/bin/lib/call-guard.sh" && call_guard_fp "$psha")
[ "$(row testproj review "$want8")" = "ok 1 0" ] && ok \
  || bad "L8a no row on call_guard_fp '$want8': $(lwf_sql "SELECT fp, status FROM agent_call_ledger WHERE fp LIKE 'BH-908:%'")"
r=$(call o8b review "$P8" AGENT_CALL_TICKET=BH-908)
[ "$(vendor_calls)" = 2 ] && ok || bad "L8b a computed fingerprint was replayed ($(vendor_calls) vendor calls, want 2)"
[ "$(row testproj review "$want8")" = "ok 2 0" ] && ok || bad "L8c row '$(row testproj review "$want8")', want 'ok 2 0'"

# --- L9. the decision rows the shell path reaches ----------------------------
reset
FP9a="review-prs:acme/app#909@a"
seed testproj review "$FP9a" failed 2 1
r=$(call o9a review "review 909a" AGENT_CALL_FP="$FP9a")
[ "$r" = 0 ] && [ "$(vendor_calls)" = 1 ] && [ "$(row testproj review "$FP9a")" = "ok 3 0" ] && ok \
  || bad "L9a failed attempts=2 did not run as attempt 3 (rc $r, calls $(vendor_calls), row '$(row testproj review "$FP9a")')"
reset
FP9b="review-prs:acme/app#909@b"
seed testproj review "$FP9b" failed 3 1
lwf_sql "UPDATE agent_call_ledger SET last_at=strftime('%Y-%m-%dT%H:%M:%SZ','now','-3601 seconds') WHERE fp=?" "$FP9b"
r=$(call o9b review "review 909b" AGENT_CALL_FP="$FP9b")
[ "$r" = 0 ] && [ "$(vendor_calls)" = 1 ] && [ "$(row testproj review "$FP9b")" = "ok 1 0" ] && ok \
  || bad "L9b a row past the window did not restart (rc $r, calls $(vendor_calls), row '$(row testproj review "$FP9b")')"
reset
FP9c="review-prs:acme/app#909@c"
seed testproj review "$FP9c" running 1 null
r=$(call o9c review "review 909c" AGENT_CALL_FP="$FP9c")
[ "$r" = 74 ] && [ "$(vendor_calls)" = 0 ] && ok || bad "L9c running row: rc $r calls $(vendor_calls), want 74 0"
reset
FP9d="review-prs:acme/app#909@d"
seed otherproj review "$FP9d" failed 3 1
r=$(call o9d review "review 909d" AGENT_CALL_FP="$FP9d")
[ "$r" = 0 ] && [ "$(vendor_calls)" = 1 ] && ok || bad "L9d another project's row refused this one (rc $r calls $(vendor_calls))"
reset
FP9e="review-prs:acme/app#909@e"
r=$(call o9e review "review 909e" AGENT_CALL_FP="$FP9e" LWF_MODE=404)
[ "$r" = 0 ] && [ "$(vendor_calls)" = 1 ] && ok || bad "L9e a 404 ledger did not fail open (rc $r calls $(vendor_calls))"

# --- L10. an answer over the byte cap is ok with no body, never replayed ----
reset
FP10="review-prs:acme/app#910@1010101"
r=$(call o10a review "review 910" AGENT_CALL_FP="$FP10" AGENT_LEDGER_ANSWER_MAX_BYTES=3)
bb=$(lwf_sql "SELECT status, answer_body, answer_bytes FROM agent_call_ledger WHERE fp=?" "$FP10" | jq -r '"\(.status) \(.answer_body) \(.answer_bytes)"')
[ "$bb" = "ok null $(stat -c %s "$T/o10a")" ] && ok || bad "L10a an over-cap answer settled '$bb', want 'ok null $(stat -c %s "$T/o10a" 2>/dev/null)'"
r=$(call o10b review "review 910" AGENT_CALL_FP="$FP10" AGENT_LEDGER_ANSWER_MAX_BYTES=3)
[ "$r" = 0 ] && [ "$(vendor_calls)" = 2 ] && [ "$(lines 'LEDGER REPLAY')" = 0 ] && ok \
  || bad "L10b an answer with no body was replayed (rc $r calls $(vendor_calls))"
grep -q 'over AGENT_LEDGER_ANSWER_MAX_BYTES=3' "$LOG" && ok || bad "L10c no over-cap log line: $(cat "$LOG")"

# --- L11. the switch: AGENT_LEDGER=0 ---------------------------------------
reset
FP11="review-prs:acme/app#911@1111111"
r1=$(call o11a review "review 911" AGENT_CALL_FP="$FP11" AGENT_LEDGER=0)
r2=$(call o11b review "review 911" AGENT_CALL_FP="$FP11" AGENT_LEDGER=0)
[ "$r1" = 0 ] && [ "$r2" = 0 ] && [ "$(vendor_calls)" = 2 ] && [ "$(nrows "$FP11")" = 0 ] && [ ! -s "$LOG" ] && ok \
  || bad "L11 AGENT_LEDGER=0: rcs $r1 $r2 calls $(vendor_calls) rows $(nrows "$FP11") log '$(cat "$LOG")', want 0 0 2 0 ''"

echo "agent-call-fp-ledger.bh-9064: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
