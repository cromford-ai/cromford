#!/bin/bash
# tests/budget-stop-cost-ceiling.bh-9719-test.sh — BH-9719 (C2 of BH-9676):
# the settings row cost_ceiling.<project> is a second source for budget-stop's
# project-day cap (bin/lib/budget-stop.sh bs_pcap). The lower cap wins, and a
# refusal the row set ends with ` key=cost_ceiling.<p>`.
#
#   C1  no cost_ceiling row, budget 50          -> 50, no key (line as on main)
#   C2  cc 30 + budget 50                       -> 30, key=cost_ceiling.p
#   C3  cc 80 + budget 50                       -> 50, no key
#   C4  cc 20 only                              -> 20, key
#   C5  cc off + budget 50                      -> 50, no key
#   C6  cc 20usd                                -> rc 2 cap-unreadable:cost_ceiling.p
#   C7  budget junk + cc 20                     -> rc 2, the budget reason
#   C8  budget._default 100 + cc 40             -> 40, key
#   C9  cc 0                                    -> 0: every call refused
#   C10 cc " 25 "                               -> 25
#   C11 cc 50 = budget 50                       -> 50, no key (tie)
#   C12 cc for ANOTHER project q only           -> p is unarmed (rc 1)
#   L   bs_launch_check: cc 30, spend 31 -> rc 1 + the key line; kill switch on
#       -> allowed; the fly-pool pool_lane_failure pattern matches the new line
#   G   bs_gate (the call gate) outside a build refuses with the key; inside an
#       admitted build it allows and notes the overrun
#   AC  the REAL bin/agent-call.sh refuses rc 74 with the key line
# 0 network calls: the spend read is a stub or a fake curl, the settings cache
# is a local file. Every case seeds its own settings.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/budget-stop.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
mkdir -p "$T/state" "$T/flags" "$T/logs" "$T/builds"
settings() { jq -nc --argjson v "$1" --argjson fa "$(date -u +%s)" '{fetched_at:$fa,values:$v,seeded:{}}' > "$T/state/settings-cache.json"; }

# pc <case> <settings-json> <want-rc> <want-value> <want-key> [want-reason]
# One fresh shell per case, so nothing a lib caches leaks between cases.
pc() {
  local c="$1" want_rc="$3" want_v="$4" want_k="$5" want_r="${6:-}" got
  settings "$2"
  got=$(HARNESS="$T" JOBS_URL= bash -c '
    . "$1" || exit 99
    rc=0; bs_pcap p >/dev/null || rc=$?
    printf "%s|%s|%s|%s" "$rc" "$BS_VALUE" "$BS_PKEY" "$BS_REASON"' _ "$LIB" 2>/dev/null)
  [ "$got" = "$want_rc|$want_v|$want_k|$want_r" ] && ok \
    || bad "$c: bs_pcap p -> '$got' (want '$want_rc|$want_v|$want_k|$want_r')"
}
pc C1  '{"budget.project.p.day_usd":"50"}'                              0 50 ""
pc C2  '{"budget.project.p.day_usd":"50","cost_ceiling.p":"30"}'        0 30 cost_ceiling.p
pc C3  '{"budget.project.p.day_usd":"50","cost_ceiling.p":"80"}'        0 50 ""
pc C4  '{"cost_ceiling.p":"20"}'                                        0 20 cost_ceiling.p
pc C5  '{"budget.project.p.day_usd":"50","cost_ceiling.p":"off"}'       0 50 ""
pc C6  '{"cost_ceiling.p":"20usd"}'                                     2 "" "" cap-unreadable:cost_ceiling.p
pc C7  '{"budget.project.p.day_usd":"lots","cost_ceiling.p":"20"}'      2 "" "" cap-unreadable:budget.project.p.day_usd
pc C8  '{"budget.project._default.day_usd":"100","cost_ceiling.p":"40"}' 0 40 cost_ceiling.p
pc C9  '{"cost_ceiling.p":"0"}'                                         0 0 cost_ceiling.p
pc C10 '{"cost_ceiling.p":" 25 "}'                                      0 25 cost_ceiling.p
pc C11 '{"budget.project.p.day_usd":"50","cost_ceiling.p":"50"}'        0 50 ""
pc C12 '{"cost_ceiling.q":"5"}'                                         1 "" ""
pc C13 '{"cost_ceiling.p":"12.5","budget.project.p.day_usd":"12.75"}'   0 12.5 cost_ceiling.p

# gate <settings-json> <usd-spent> <shell-snippet> — source the lib with a
# stubbed spend read and run the snippet; prints what the snippet prints.
gate() {
  settings "$1"
  HARNESS="$T" HARNESS_SECRET=s JOBS_URL=https://jobs.invalid SPENT="$2" bash -c '
    . "$1" || exit 99
    _jobs_req() { printf "{\"usd\":%s,\"calls\":3,\"refused\":0,\"settled\":0}" "$SPENT"; }
    eval "$2"' _ "$LIB" "$3" 2>/dev/null
}

# --- L: the launch gate --------------------------------------------------------
G=$(gate '{"cost_ceiling.p":"30","budget.project.p.day_usd":"50"}' 31 'rc=0; bs_launch_check p || rc=$?; printf "%s|%s" "$rc" "$BS_REFUSE"')
[ "$G" = "1|budget-project-day project=p usd=31/30 key=cost_ceiling.p" ] && ok || bad "L1 launch gate: '$G'"
G=$(gate '{"cost_ceiling.p":"30","budget.project.p.day_usd":"50"}' 29 'rc=0; bs_launch_check p || rc=$?; printf "%s|%s" "$rc" "$BS_REFUSE"')
[ "$G" = "0|" ] && ok || bad "L2 under the ceiling: '$G'"
G=$(gate '{"budget.project.p.day_usd":"30"}' 31 'rc=0; bs_launch_check p || rc=$?; printf "%s|%s" "$rc" "$BS_REFUSE"')
[ "$G" = "1|budget-project-day project=p usd=31/30" ] && ok || bad "L3 no cost_ceiling row: line must be main's: '$G'"
touch "$T/flags/budget-stop-off"
G=$(gate '{"cost_ceiling.p":"30"}' 31 'rc=0; bs_launch_check p || rc=$?; printf "%s|%s" "$rc" "$BS_REFUSE"')
[ "$G" = "0|" ] && ok || bad "L4 kill switch on: '$G'"
rm -f "$T/flags/budget-stop-off"
# The round trip: fly-pool's pool_lane_failure must still see a deferral.
PAT=$(grep -o '\*" budget-project-day "\*' "$DIR/bin/fly-pool.sh" | head -1)
if [ -n "$PAT" ]; then
  # shellcheck disable=SC2254 # the case pattern is the one fly-pool.sh holds
  eval "case 'BUILD_DEFERRED budget-project-day project=p usd=31/30 key=cost_ceiling.p' in $PAT) true ;; *) false ;; esac" \
    && ok || bad "L5 pool_lane_failure pattern $PAT does not match the new line"
else
  bad "L5 no budget-project-day pattern found in bin/fly-pool.sh"
fi

# --- G: the call gate ---------------------------------------------------------
G=$(gate '{"cost_ceiling.p":"30"}' 31 'rc=0; bs_gate p triage "" || rc=$?; printf "%s|%s" "$rc" "$BS_REFUSE"')
[ "$G" = "2|budget-project-day triage project=p usd=31/30 key=cost_ceiling.p" ] && ok || bad "G1 call gate: '$G'"
G=$(gate '{"cost_ceiling.p":"0"}' 0 'rc=0; bs_gate p triage "" || rc=$?; printf "%s|%s" "$rc" "$BS_REFUSE"')
[ "$G" = "2|budget-project-day triage project=p usd=0/0 key=cost_ceiling.p" ] && ok || bad "G2 cc 0 refuses: '$G'"
G=$(gate '{"cost_ceiling.q":"5"}' 31 'rc=0; bs_gate p triage "" || rc=$?; printf "%s|%s" "$rc" "$BS_REFUSE"')
[ "$G" = "0|" ] && ok || bad "G3 another project's row: '$G'"
mkdir -p "$T/builds/b1"; : > "$T/builds/b1/ADMITTED"
G=$(gate '{"cost_ceiling.p":"30"}' 31 'unset AGENT_CALL_LANE; rc=0; bs_gate p execute "'"$T"'/builds/b1/execute.txt" || rc=$?; printf "%s|%s" "$rc" "$BS_REFUSE"')
[ "$G" = "0|" ] && ok || bad "G4 admitted build: '$G'"
grep -q 'call ALLOWED (BH-5526): budget-project-day execute project=p usd=31/30 key=cost_ceiling.p' "$T/builds/b1/pipeline.log" 2>/dev/null \
  && ok || bad "G4 admitted build overrun note: $(cat "$T/builds/b1/pipeline.log" 2>/dev/null)"

# --- AC: the real bin/agent-call.sh -------------------------------------------
mkdir -p "$T/ac/bin" "$T/ac/fakebin" "$T/ac/state" "$T/ac/logs" "$T/ac/flags" "$T/ac/locks" "$T/ac/lane"
scratch_install_closure bin/jobs-client.sh "$T/ac" >/dev/null || bad "AC closure copy"
cp "$DIR/bin/alert-line.sh" "$T/ac/bin/alert-line.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/ac/bin/beat.sh"
printf '#!/bin/bash\necho subscription\n' > "$T/ac/bin/billing-mode.sh"
echo '{"lanes":[]}' > "$T/ac/budgets.json"
printf '#!/bin/bash\necho claude >> "$ORDER_SINK"\necho %s\n' "'{\"result\":\"ok\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1},\"total_cost_usd\":0.01}'" > "$T/ac/fakebin/claude"
cat > "$T/ac/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
cat > "$T/ac/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/metrics/llm-spend\?*) printf '{"usd":31,"calls":3,"refused":0,"settled":0}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/ac/fakebin/"* "$T/ac/bin/"*.sh
jq -nc --argjson fa "$(date -u +%s)" '{fetched_at:$fa,values:{"cost_ceiling.acp":"30"},seeded:{}}' > "$T/ac/state/settings-cache.json"
: > "$T/ac/order"
( unset HARNESS_TICKET AGENT_CALL_TICKET AGENT_CALL_PR AGENT_CALL_FP JOB_ID COST_RUN_ID
  export ORDER_SINK="$T/ac/order" PATH="$T/ac/fakebin:$PATH" HARNESS="$T/ac" HOME="$T/ac" \
         HARNESS_SECRET=testsecret JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 \
         CALL_GUARD=0 CLAUDE_CODE_OAUTH_TOKEN=tok ANTHROPIC_API_KEY= \
         OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= OPENAI_API_KEY= ACCOUNT_ROUTING=0 \
         LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 \
         AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 \
         IRON_LAW_LANES=none COST_TRANSCRIPT_ROWS=1 CONTEXT_BUDGETS="$T/ac/budgets.json"
  cd "$T/ac" && bash "$DIR/bin/agent-call.sh" lead-review acp claude-fable-5-1 60 "$T/ac/lane/out.txt" "hello" >/dev/null 2>"$T/ac/err" )
R=$?
[ "$R" = 74 ] && ok || bad "AC agent-call rc=$R, want 74: $(head -3 "$T/ac/err")"
[ "$(grep -c . "$T/ac/order")" = 0 ] && ok || bad "AC claude ran over the ceiling"
grep -q '^AGENT_CALL_REFUSED budget-project-day lead-review project=acp usd=31/30 key=cost_ceiling.acp' "$T/ac/lane/out.txt" 2>/dev/null \
  && ok || bad "AC \$OUT: $(head -1 "$T/ac/lane/out.txt" 2>/dev/null)"

echo "budget-stop-cost-ceiling.bh-9719: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
