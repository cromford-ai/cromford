#!/bin/bash
# tests/claude-cost-gate.bh-2534-test.sh — bin/claude-cost.sh consults the lane
# gate (bin/lib/llm-gate.sh) and K3 (bin/lib/call-guard.sh) BEFORE it runs
# claude, and the orchestrator's primary turn is lane orc-monitor (BH-2534).
#
# WHY. claude-cost.sh is the priced path for the callers that need raw claude
# (the orchestrator's turns, greenfield, box-chat's `-c` rung). Before this it
# priced them and gated nothing: LLM_LANE_ENABLED=0 on orc-monitor stopped the
# survival turn (agent-call) and left the primary turn running and billing.
#
# What is proved here, each case against the REAL wrapper and the REAL libs:
#   1. no knob: the call runs, rc is claude's, the priced row carries the lane
#   2. LLM_LANE_ENABLED=0 on orc-monitor: rc 74, claude never runs, one
#      zero-cost row_source=refused row stamped lane_id=orc-monitor
#   3. LLM_RUNNER_ALLOWED refuses a list without claude, allows one with it
#   4. LLM_USD_CAP_DAY refuses over the day's D1 spend, fails open on no answer
#   5. K3 refused claim: rc 74, claude never runs
#   6. K3 allowed claim: claude runs, exactly one settle `ok` with the claim id
#   7. K3 off for a stage the guard does not enforce: no claim at all
#   8. K3 with the prompt on stdin and no AGENT_CALL_FP: no claim, stdin intact
#   9. THE PRODUCTION ENTRY: bin/orchestrate.sh's real run_turn() + claude
#      ladder driving the real wrapper — refused, lane orc-monitor, no claude
#  10. AGENT_CALL_LANE / AGENT_CALL_FP never reach the claude session
#  11. the rendered registry carries the three LLM_* knobs on orc-monitor
#  12. every refusal marker classifies real-failure in orc_fail_class, so a
#      gate refusal can never cool an orchestrator account fleet-wide
# Negative triggers that must NOT refuse ride along in 1, 3 and a
# different-lane case.
#
# Run from anywhere: tests/claude-cost-gate.bh-2534-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/rendered.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
REAL_REG=$(rendered_registry)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] does not contain [$3]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: [$2] must NOT contain [$3]" ;; *) ok ;; esac; }

unset AGENT_CALL_LANE AGENT_CALL_FP AGENT_CALL_GUARD_STAGE AGENT_CALL_TICKET AGENT_CALL_GUARD_FORCE \
      CALL_GUARD CALL_GUARD_STAGES CALL_GUARD_MAX_MAP LLM_LANE_ENABLED LLM_RUNNER_ALLOWED \
      LLM_USD_CAP_DAY LLM_GATE_DISABLE LANE_GATE_DISABLE JOBS_URL COST_STAGE COST_PROJECT \
      HARNESS_TICKET JOB_ID IS_SANDBOX

mkdir -p "$T/fakebin" "$T/home"

# A fake claude: says it ran, dumps its env, echoes stdin when asked, answers.
cat > "$T/fakebin/claude" <<'FAKE'
#!/bin/bash
touch "$CLAUDE_RAN"
env > "$CLAUDE_ENV"
[ "${FAKE_ECHO_STDIN:-0}" = 1 ] && { printf 'STDIN:'; cat; }
echo ANSWER
exit "${FAKE_RC:-0}"
FAKE
chmod +x "$T/fakebin/claude"

# A fake bin/jobs-client.sh: the three functions the gate libs reach the worker
# through, each recording its argv. FAKE_SPEND is the llm-spend answer (`err` =
# the worker did not answer); FAKE_CLAIM is the claim's JSON. Settings reads
# fail, so the only settings rows are the cache file a case writes itself.
cat > "$T/fake-jobs-client.sh" <<'JC'
_jobs_req() {
  echo "$*" >> "$FAKE_LOG/req.log"
  case "$2" in
    /api/metrics/llm-spend*)
      [ "${FAKE_SPEND:-err}" = err ] && return 1
      printf '{"usd":%s}' "$FAKE_SPEND"; return 0 ;;
  esac
  return 1
}
call_guard_claim() {
  printf '%s\n' "$*" >> "$FAKE_LOG/claim.log"
  printf '%s' "${FAKE_CLAIM:-{\"allowed\":true,\"count\":1}}"
  return 0
}
call_guard_settle() { printf '%s\n' "$*" >> "$FAKE_LOG/settle.log"; return 0; }
JC

# scen — a fresh harness tree: the wrapper and the REAL libs it sources.
scen() {
  rm -rf "$T/h" "$T/log"; mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/log"
  cp "$DIR/bin/claude-cost.sh" "$DIR/bin/transcript-cost.sh" "$T/h/bin/"
  cp "$DIR/bin/lib/cost-row.sh" "$DIR/bin/lib/llm-gate.sh" "$DIR/bin/lib/lane-gate.sh" \
     "$DIR/bin/lib/call-guard.sh" "$T/h/bin/lib/"
  printf '#!/bin/bash\necho "${FAKE_BILLING:-subscription}"\n' > "$T/h/bin/billing-mode.sh"
  printf 'auth_fp_for_runner() { echo fp-test; }\nauth_account_for_fp() { echo acct-test; }\n' \
    > "$T/h/bin/auth-fingerprint.sh"
  chmod +x "$T/h/bin/"*.sh
  rm -f "$T/claude.ran" "$T/claude.env"
  : > "$T/log/claim.log"; : > "$T/log/settle.log"; : > "$T/log/req.log"
  SCEN="$1"
}
with_jobs() { cp "$T/fake-jobs-client.sh" "$T/h/bin/jobs-client.sh"; }
# setting <key> <value> — one settings row, as the worker's cache holds it.
setting() {
  local f="$T/h/state/settings-cache.json"
  [ -s "$f" ] || printf '{"fetched_at":%s,"values":{},"seeded":{}}' "$(date -u +%s)" > "$f"
  jq --arg k "$1" --arg v "$2" '.values[$k]=$v' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
# cc [KEY=VAL ...] -- <claude args> — run the wrapper; stdin is /dev/null
# unless STDIN_TEXT is set, in which case it is a pipe.
cc() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  if [ -n "${STDIN_TEXT:-}" ]; then
    printf '%s' "$STDIN_TEXT" | ( cd "$T" && env PATH="$T/fakebin:$PATH" HOME="$T/home" HARNESS="$T/h" \
      LANE_REGISTRY="$REAL_REG" CLAUDE_RAN="$T/claude.ran" CLAUDE_ENV="$T/claude.env" FAKE_LOG="$T/log" \
      ${envs[@]+"${envs[@]}"} "$T/h/bin/claude-cost.sh" "$@" ) > "$T/out" 2> "$T/err"
  else
    ( cd "$T" && env PATH="$T/fakebin:$PATH" HOME="$T/home" HARNESS="$T/h" \
      LANE_REGISTRY="$REAL_REG" CLAUDE_RAN="$T/claude.ran" CLAUDE_ENV="$T/claude.env" FAKE_LOG="$T/log" \
      ${envs[@]+"${envs[@]}"} "$T/h/bin/claude-cost.sh" "$@" ) < /dev/null > "$T/out" 2> "$T/err"
  fi
  RC=$?
}
rows()    { tail -n +2 "$T/h/logs/cost.csv" 2>/dev/null; }
nrows()   { rows | grep -c . ; }
refused() { rows | awk -F, '$18=="refused"' ; }
col()     { printf '%s\n' "$1" | awk -F, -v c="$2" '{print $c}'; }
ran()     { [ -e "$T/claude.ran" ] && echo yes || echo no; }

# ---------------------------------------------------------------------------
# 1. No knobs: transparent, and the priced row carries the lane
# ---------------------------------------------------------------------------
scen no-knobs
cc AGENT_CALL_LANE=orc-monitor COST_STAGE=orchestrator FAKE_RC=3 -- -p --model m-x hi
eq  "1 rc is claude's"        "$RC" 3
eq  "1 claude ran"            "$(ran)" yes
eq  "1 stdout"                "$(cat "$T/out")" ANSWER
eq  "1 no refused row"        "$(refused | grep -c .)" 0
eq  "1 one row"               "$(nrows)" 1
eq  "1 row lane_id"           "$(col "$(rows)" 25)" orc-monitor

# ---------------------------------------------------------------------------
# 2. LLM_LANE_ENABLED=0 on orc-monitor refuses the turn with a refused row
# ---------------------------------------------------------------------------
scen lane-disabled
setting lane.orc-monitor.llm_lane_enabled 0
cc AGENT_CALL_LANE=orc-monitor COST_STAGE=orchestrator -- -p --model m-x hi
eq  "2 rc 74"                 "$RC" 74
eq  "2 claude never ran"      "$(ran)" no
has "2 stderr marker"         "$(cat "$T/err")" "AGENT_CALL_REFUSED llm-gate lane-disabled orc-monitor"
eq  "2 exactly one row"       "$(nrows)" 1
R=$(refused)
eq  "2 row_source refused"    "$(col "$R" 18)" refused
eq  "2 cost_usd literal 0"    "$(col "$R" 13)" 0
eq  "2 note"                  "$(col "$R" 24)" "refused:lane-disabled orc-monitor"
eq  "2 stage"                 "$(col "$R" 4)" orchestrator
eq  "2 model from argv"       "$(col "$R" 6)" m-x
eq  "2 lane_id"               "$(col "$R" 25)" orc-monitor
eq  "2 rc column"             "$(col "$R" 7)" 74
has "2 failovers line"        "$(cat "$T/h/logs/failovers.log" 2>/dev/null)" "nothing was called and nothing was billed"

# 2b. The row says 0 for a DIFFERENT lane: this lane still runs.
scen other-lane-disabled
setting lane.review-prs.llm_lane_enabled 0
cc AGENT_CALL_LANE=orc-monitor COST_STAGE=orchestrator -- -p hi
eq  "2b rc 0"                 "$RC" 0
eq  "2b claude ran"           "$(ran)" yes
# 2c. LLM_LANE_ENABLED=1 written explicitly runs.
scen lane-enabled
setting lane.orc-monitor.llm_lane_enabled 1
cc AGENT_CALL_LANE=orc-monitor COST_STAGE=orchestrator -- -p hi
eq  "2c rc 0"                 "$RC" 0
eq  "2c claude ran"           "$(ran)" yes

# ---------------------------------------------------------------------------
# 3. LLM_RUNNER_ALLOWED
# ---------------------------------------------------------------------------
scen runner-not-allowed
setting lane.orc-monitor.llm_runner_allowed codex
cc AGENT_CALL_LANE=orc-monitor COST_STAGE=orchestrator -- -p hi
eq  "3 rc 74"                 "$RC" 74
eq  "3 claude never ran"      "$(ran)" no
has "3 note"                  "$(col "$(refused)" 24)" "refused:runner-not-allowed"
scen runner-allowed-spaces
setting lane.orc-monitor.llm_runner_allowed "claude, codex"
cc AGENT_CALL_LANE=orc-monitor COST_STAGE=orchestrator -- -p hi
eq  "3b rc 0"                 "$RC" 0
eq  "3b claude ran"           "$(ran)" yes

# ---------------------------------------------------------------------------
# 4. LLM_USD_CAP_DAY against the day's D1 spend
# ---------------------------------------------------------------------------
scen cap-over
with_jobs
setting lane.orc-monitor.llm_usd_cap_day 10
cc AGENT_CALL_LANE=orc-monitor COST_STAGE=orchestrator FAKE_SPEND=12.5 -- -p hi
eq  "4 rc 74"                 "$RC" 74
eq  "4 claude never ran"      "$(ran)" no
has "4 note"                  "$(col "$(refused)" 24)" "refused:usd-cap-day"
has "4 spend asked for the lane" "$(cat "$T/log/req.log")" "lane=orc-monitor"
scen cap-unreadable
with_jobs
setting lane.orc-monitor.llm_usd_cap_day 10
cc AGENT_CALL_LANE=orc-monitor COST_STAGE=orchestrator FAKE_SPEND=err -- -p hi
eq  "4b rc 0 (fail open)"     "$RC" 0
eq  "4b claude ran"           "$(ran)" yes

# ---------------------------------------------------------------------------
# 5-8. K3
# ---------------------------------------------------------------------------
scen k3-refused
with_jobs
cc AGENT_CALL_LANE=orc-monitor COST_STAGE=orchestrator JOBS_URL=http://fake CALL_GUARD_STAGES=orchestrator \
   'FAKE_CLAIM={"allowed":false,"count":2}' -- -p --model m-x hi
eq  "5 rc 74"                 "$RC" 74
eq  "5 claude never ran"      "$(ran)" no
# K is the orchestrator family's own default, 6 since BH-2603 (two models on up
# to three account rungs); the operator row above only names the stage.
has "5 stderr marker"         "$(cat "$T/err")" "AGENT_CALL_REFUSED call-guard repeat orchestrator paid=2/6"
has "5 note"                  "$(col "$(refused)" 24)" "refused:call-guard:repeat"
eq  "5 no settle"             "$(grep -c . "$T/log/settle.log")" 0

scen k3-allowed
with_jobs
cc AGENT_CALL_LANE=orc-monitor COST_STAGE=orchestrator JOBS_URL=http://fake CALL_GUARD_STAGES=orchestrator \
   -- -p --model m-x hi
eq  "6 rc 0"                  "$RC" 0
eq  "6 claude ran"            "$(ran)" yes
eq  "6 one claim"             "$(grep -c . "$T/log/claim.log")" 1
read -r c_proj c_stage c_fp c_id _max _win c_runner _force < "$T/log/claim.log"
eq  "6 claim project"         "$c_proj" fleet
eq  "6 claim stage"           "$c_stage" orchestrator
eq  "6 claim runner"          "$c_runner" claude
PSHA=$(printf '%s\0' -p --model m-x hi | sha256sum | cut -c1-16)
case "$c_fp" in *":p$PSHA") ok ;; *) bad "6 fp [$c_fp] must end with :p$PSHA (the caller's argv)" ;; esac
eq  "6 one settle"            "$(grep -c . "$T/log/settle.log")" 1
eq  "6 settle id + outcome"   "$(cat "$T/log/settle.log")" "$c_id ok"

# `orchestrator` is enforced by default since BH-2603; `chat` stays unguarded on
# purpose (bin/product-cmd.sh shares it), so it is this case's stage.
scen k3-stage-not-enforced
with_jobs
cc AGENT_CALL_LANE=orc-monitor COST_STAGE=chat JOBS_URL=http://fake -- -p hi
eq  "7 rc 0"                  "$RC" 0
eq  "7 no claim"              "$(grep -c . "$T/log/claim.log")" 0
eq  "7 no settle"             "$(grep -c . "$T/log/settle.log")" 0

scen k3-stdin
with_jobs
STDIN_TEXT="the prompt" cc AGENT_CALL_LANE=orc-monitor COST_STAGE=orchestrator JOBS_URL=http://fake \
   CALL_GUARD_STAGES=orchestrator FAKE_ECHO_STDIN=1 -- -p
# BH-9064 reversed this case's premise: a stdin prompt is claimed too, on a fp
# computed from the argv AND the stdin text ("K3 not claimed" no longer exists).
eq  "8 rc 0"                  "$RC" 0
eq  "8 one claim"             "$(grep -c . "$T/log/claim.log")" 1
read -r _p _s s_fp _rest < "$T/log/claim.log"
SPSHA=$( { printf '%s\0' -p; printf '%s' "the prompt"; } | sha256sum | cut -c1-16)
case "$s_fp" in *":p$SPSHA") ok ;; *) bad "8 stdin fp [$s_fp] must end with :p$SPSHA (argv + stdin)" ;; esac
has "8 stdin reached claude"  "$(cat "$T/out")" "STDIN:the prompt"
case "$(cat "$T/h/logs/claude-cost.log" 2>/dev/null)" in *"K3 not claimed"*) bad "8 a stdin call still logs K3 not claimed" ;; *) ok ;; esac

# ---------------------------------------------------------------------------
# 9. The production entry: bin/orchestrate.sh's run_turn + claude ladder
# ---------------------------------------------------------------------------
SRC="$DIR/bin/orchestrate.sh"
sed -n '/^# >>> claude ladder/,/^# <<< claude ladder/p' "$SRC" > "$T/ladder.sh"
awk '/^run_turn\(\) \{/,/^}/' "$SRC" > "$T/runturn.sh"
# run_turn reads the turn's K3 fp (BH-2603), set by its own block.
sed -n '/^# >>> turn fp/,/^# <<< turn fp/p' "$SRC" > "$T/turnfp.sh"
grep -q 'CANDIDATES=(' "$T/ladder.sh" && ok || bad "9 the claude-ladder lift is empty or stale"
grep -q 'ORC_CLAUDE' "$T/runturn.sh"  && ok || bad "9 the run_turn() lift is empty or stale"
cat > "$T/drive.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
. "$LIB"
orc_fresh() { [ "${FRESH:-1}" = 1 ]; }
compose_v2_prompt() { printf 'the message\n'; }
budget_check() { :; }
note() { echo "$1" >> "$HARNESS/logs/failovers.log"; }
IRON_LAW_ARM=()
RC=0; OUT=""; SERVED_BY=""
. "$BLOCK_TURNFP"
. "$BLOCK_RUNTURN"
. "$BLOCK_LADDER"
printf '%s' "$OUT" > "$OUTF"
echo "RC=$RC" > "$STATEF"
DRIVE
drive() {
  ( cd "$T" && env PATH="$T/fakebin:$PATH" HOME="$T/home" HARNESS="$T/h" ORC="$T/orc" \
      LIB="$DIR/bin/lib/orc-account.sh" BLOCK_TURNFP="$T/turnfp.sh" CMD_ID=9 _DKEY=fixture-dkey BLOCK_RUNTURN="$T/runturn.sh" BLOCK_LADDER="$T/ladder.sh" \
      OUTF="$T/orc.out" STATEF="$T/orc.state" LANE_REGISTRY="$REAL_REG" \
      CLAUDE_RAN="$T/claude.ran" CLAUDE_ENV="$T/claude.env" FAKE_LOG="$T/log" \
      ORC_MODEL=model-a ORC_FALLBACK=model-b ORC_SURVIVAL="" ORC_BUDGET=2 TEXT=hi \
      ORC_CLAUDE="$T/h/bin/claude-cost.sh" ORC_TOKEN="" ORC_TOKEN_DEFAULT="" \
      ORC_ACCOUNT=default ORC_ACCOUNT_REASON=test COST_PROJECT=fleet COST_STAGE=orchestrator \
      "$@" timeout 60 bash "$T/drive.sh" ) > "$T/drive.log" 2>&1
}
for fresh in 1 0; do
  scen "orchestrator-fresh=$fresh"
  mkdir -p "$T/orc"
  setting lane.orc-monitor.llm_lane_enabled 0
  drive FRESH=$fresh
  eq  "9[$fresh] claude never ran"   "$(ran)" no
  eq  "9[$fresh] turn rc 74"         "$(sed -n 's/^RC=//p' "$T/orc.state")" 74
  has "9[$fresh] refusal is the turn's output" "$(cat "$T/orc.out")" "AGENT_CALL_REFUSED llm-gate lane-disabled orc-monitor"
  # ONE refused row per refused turn (BH-2603): the ladder stops at the gate's
  # refusal instead of asking model-b, which the same gate would refuse again.
  eq  "9[$fresh] one refused row per turn" "$(refused | grep -c .)" 1
  eq  "9[$fresh] every row is refused" "$(nrows)" 1
  eq  "9[$fresh] lane_id"            "$(refused | awk -F, '{print $25}' | sort -u)" orc-monitor
  eq  "9[$fresh] stage"              "$(refused | awk -F, '{print $4}' | sort -u)" orchestrator
  eq  "9[$fresh] models"             "$(refused | awk -F, '{print $6}' | sort | tr '\n' ' ')" "model-a "
done
# ...and with no knob the same entry runs the turn, tagged orc-monitor.
scen orchestrator-open
mkdir -p "$T/orc"
drive FRESH=1
eq  "9 open: claude ran"            "$(ran)" yes
eq  "9 open: turn rc 0"             "$(sed -n 's/^RC=//p' "$T/orc.state")" 0
eq  "9 open: priced row lane_id"    "$(rows | awk -F, '{print $25}')" orc-monitor

# ---------------------------------------------------------------------------
# 10. The lane and the per-call guard env stop at the claude boundary
# ---------------------------------------------------------------------------
scen leak
cc AGENT_CALL_LANE=orc-monitor AGENT_CALL_FP=x AGENT_CALL_GUARD_STAGE=g AGENT_CALL_TICKET=t \
   COST_STAGE=orchestrator -- -p hi
eq  "10 claude ran"           "$(ran)" yes
# Only NAMES are compared: the dump is the whole session env, and a failure
# message must never print a token that rides in it.
[ -s "$T/claude.env" ] && ok || bad "10 claude env dump is empty"
for v in AGENT_CALL_LANE AGENT_CALL_FP AGENT_CALL_GUARD_STAGE AGENT_CALL_TICKET; do
  grep -q "^$v=" "$T/claude.env" 2>/dev/null && bad "10 $v reached the claude session" || ok
done

# ---------------------------------------------------------------------------
# 11. The registry: orc-monitor carries the three LLM_* knobs (and, since
#     BH-4995.0, the four reply-ledger knobs bin/lib/orc-reply-ledger.sh reads,
#     and since BH-5336, the three turn-gate knobs bin/lib/orc-turns.sh reads)
# ---------------------------------------------------------------------------
K=$(jq -r '.lanes[] | select(.id=="orc-monitor") | .knobs[] | "\(.env)@\(.read_in)"' "$REAL_REG" 2>/dev/null | sort | tr '\n' ' ')
eq  "11 orc-monitor knobs" "$K" "LLM_LANE_ENABLED@bin/lib/llm-gate.sh LLM_RUNNER_ALLOWED@bin/lib/llm-gate.sh LLM_USD_CAP_DAY@bin/lib/llm-gate.sh ORC_CMD_STATUS@bin/lib/orc-reply-ledger.sh ORC_REPLY_LEDGER_BACKOFF_S@bin/lib/orc-reply-ledger.sh ORC_REPLY_LEDGER_MAX_CHARS@bin/lib/orc-reply-ledger.sh ORC_REPLY_LEDGER_TRIES@bin/lib/orc-reply-ledger.sh ORC_TURN_CONCURRENCY@bin/lib/orc-turns.sh ORC_TURN_STALE_S@bin/lib/orc-turns.sh ORC_TURN_WORKER_MEM_MB@bin/lib/orc-turns.sh "

# ---------------------------------------------------------------------------
# 12. A refusal never reads as an account refusal to the orchestrator
# ---------------------------------------------------------------------------
( export HARNESS="$T/h"
  . "$DIR/bin/lib/orc-account.sh" || exit 1
  for m in \
    'AGENT_CALL_REFUSED llm-gate lane-disabled orc-monitor' \
    'AGENT_CALL_REFUSED llm-gate usd-cap-day lane spent=$12.5 cap=$10 lane=orc-monitor' \
    'AGENT_CALL_REFUSED llm-gate runner-not-allowed claude not in [codex] lane=orc-monitor' \
    'AGENT_CALL_REFUSED call-guard repeat orchestrator paid=2/2 fp=-:abc:p0123' \
    'AGENT_CALL_REFUSED call-guard counter-unreadable metered claude'; do
    orc_fail_class 74 "$m"
    echo "$ORC_FAIL_CLASS|$m"
  done ) > "$T/cls.txt" 2>&1
eq "12 five markers classified" "$(grep -c '^real-failure|' "$T/cls.txt")" 5
grep -v '^real-failure|' "$T/cls.txt" | while read -r l; do echo "FAIL: 12 misclassified: $l"; done

echo "claude-cost-gate.bh-2534: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
