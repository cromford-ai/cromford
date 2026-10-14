#!/bin/bash
# tests/rule-miner-ceiling.bh-1749-test.sh — BH-1764 (BH-1749.2): the rule-miner
# lane reads the digest only, runs as its own stage `mine` on the route's runner,
# refuses before any metered call when its projected context is over the lane
# ceiling, and prices its terminal log line.
#
# Drives the REAL bin/rule-miner.sh (copied into a scratch HARNESS, so its
# siblings are the stubs below): agent-call.sh records argv/env and writes a
# draft, jobs-client.sh records the job row, gh is a fake that clones a local
# repo and opens a fake PR. The incidents are hand-filed manual notes.
#
# The root cause this pins: `agent-call.sh triage rule-miner` let the hub's
# RUNNER_TRIAGE=grok replace the fable route, and "Read every bundle" fed the
# session 8.05M input tokens on 2026-09-21.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset HARNESS_SECRET JOBS_URL RUNNER_TRIAGE AGENT_CALL_RUNNERS MINER_MODEL HUB_NO_BUILD_LANES \
      CONTEXT_BUDGETS RULE_MINER_DRY CANNED_COST_ROW STUB_DRAFT

mkdir -p "$T/bin/lib" "$T/logs" "$T/state/rule-mining/manual" "$T/env" "$T/locks" "$T/flags" \
         "$T/catalog" "$T/stub" "$T/origin"
cp "$DIR/bin/rule-miner.sh" "$DIR/bin/rule-miner-digest.sh" "$T/bin/"
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$T/bin/lib/"
# BH-3714: the PR path classifies each rule, so it needs the three libs it sources there.
cp "$DIR/bin/lib/rule-class.sh" "$DIR/bin/lib/rule-evidence.sh" "$DIR/bin/lib/gh-rest.sh" "$T/bin/lib/"
cp "$DIR/catalog/context-budgets.json" "$T/catalog/"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T" || exit 1
ROUTES_SEED=$(cat "$T/state/model-routes/rule.miner.tsv")

# ── stubs ─────────────────────────────────────────────────────────────────────
# mkrow <header> <ts> <project> <input_toks> <cache_read> <cost_usd> — one cost.csv
# row in the column order of <header>, so a permuted header is a real permutation.
# `note` is the LAST column on every real writer, so a comma inside it only
# extends NF; the fixture carries one there and nowhere else.
cat > "$T/mkrow.sh" <<'EOF'
#!/bin/bash
IFS=, read -ra H <<<"$1"; out=""
for c in "${H[@]}"; do
  case "$c" in
    ts) v="$2" ;; project) v="$3" ;; input_toks) v="$4" ;; cache_read) v="$5" ;;
    cost_usd) v="$6" ;; stage) v=mine ;; runner) v=claude ;; model) v=claude-fable-5-1 ;;
    note) v="a note" ;; *) v=0 ;;
  esac
  out="$out${out:+,}$v"
done
[ "${H[-1]}" = note ] && out="$out, with a comma"
printf '%s\n' "$out"
EOF
chmod +x "$T/mkrow.sh"

cat > "$T/bin/agent-call.sh" <<'EOF'
#!/bin/bash
H="$HARNESS"
printf 'argv1=%s argv2=%s argv3=%s AGENT_CALL_RUNNERS=%s RUNNER_TRIAGE=%s\n' \
  "$1" "$2" "$3" "${AGENT_CALL_RUNNERS:-}" "${RUNNER_TRIAGE:-}" >> "$H/calls.log"
printf '%s' "$6" > "$H/prompt.txt"
D="$H/state/rule-mining/$(date -u +%Y%m%d)"
printf '%b\n' "${STUB_DRAFT:-NO_RULE\nall weather}" > "$D/draft.md"
if [ -n "${CANNED_COST_ROW:-}" ]; then
  "$H/mkrow.sh" "$(head -1 "$H/logs/cost.csv")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" rule-miner $CANNED_COST_ROW >> "$H/logs/cost.csv"
fi
exit 0
EOF
cat > "$T/bin/jobs-client.sh" <<'EOF'
job_lane_open()  { echo "open $1 stage=$3" >> "$HARNESS/jobs.log"; export JOB_ID=job-1; }
job_event()      { echo "event $*" >> "$HARNESS/jobs.log"; }
job_lane_close() { echo "close $*" >> "$HARNESS/jobs.log"; }
EOF
printf '#!/bin/sh\n[ "$1" = --projects ] && exit 0\nexit 1\n' > "$T/bin/fleet-conf.sh"
chmod +x "$T/bin/agent-call.sh" "$T/bin/fleet-conf.sh"
cp "$T/bin/rule-miner-digest.sh" "$T/real-digest.sh"

printf '#!/bin/sh\nexit 0\n' > "$T/stub/flock"
git init -q --bare "$T/origin/h.git"
cat > "$T/stub/gh" <<EOF
#!/bin/bash
case "\$1 \$2" in
  "repo clone")
    git init -q "\$4" && cd "\$4" && mkdir -p prompts \\
      && printf '# rules\n- **D1 Mutation-check.** x\n' > prompts/build-discipline.md \\
      && git add -A && git -c user.name=t -c user.email=t@t commit -qm init \\
      && git remote add origin "$T/origin/h.git" ;;
  "pr list") exit 0 ;;
  "pr create") echo "https://github.com/example-org/cromford/pull/9999" ;;
  "api "*) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/stub/flock" "$T/stub/gh"
export PATH="$T/stub:$PATH"

printf 'the first lesson\n' > "$T/state/rule-mining/manual/alpha.md"
printf 'the second lesson\n' > "$T/state/rule-mining/manual/beta.md"
printf 'manual:zzz-old\n' > "$T/state/rule-mining/seen.txt"
SEEN0=$(cat "$T/state/rule-mining/seen.txt")
MINDIR="$T/state/rule-mining/$(date -u +%Y%m%d)"
LOG="$T/logs/rule-miner.log"; ALERTS="$T/logs/ALERTS.log"
HDR="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note"

reset() {
  scratch_rm "$MINDIR"
  printf '%s\n' "$SEEN0" > "$T/state/rule-mining/seen.txt"
  : > "$LOG"; : > "$ALERTS"; : > "$T/calls.log"; : > "$T/jobs.log"; rm -f "$T/prompt.txt" "$T/logs/cost.csv"
  printf '%s\n' "$ROUTES_SEED" > "$T/state/model-routes/rule.miner.tsv"
  cp "$T/real-digest.sh" "$T/bin/rule-miner-digest.sh"
  rm -rf "$T/origin/h.git"; git init -q --bare "$T/origin/h.git"
}
miner() { HARNESS="$T" "$@" bash "$T/bin/rule-miner.sh" 2>/dev/null; }
ncalls() { grep -c . "$T/calls.log" 2>/dev/null; }
seen_same() { [ "$(cat "$T/state/rule-mining/seen.txt")" = "$SEEN0" ]; }

refused() { # refused <label> <ceiling-text> <rc>
  local l="$1" c="$2" rc="$3"
  [ "$rc" = 1 ] && ok || bad "$l: rc $rc, want 1"
  [ "$(ncalls)" = 0 ] && ok || bad "$l: agent-call invoked $(ncalls)x, want 0"
  grep -qE "CEILING REFUSED projected=[0-9]+ ceiling=$c — no agent call made" "$LOG" && ok \
    || bad "$l: no CEILING REFUSED log line with ceiling=$c ($(cat "$LOG"))"
  grep -q '\[rule-miner\] CEILING REFUSED' "$ALERTS" && grep -q 'RULE_MINER_DIGEST_MAX_TOKENS' "$ALERTS" \
    && grep -q 'ceiling_tokens' "$ALERTS" && ok || bad "$l: ALERTS line missing or not actionable ($(cat "$ALERTS"))"
  seen_same && ok || bad "$l: seen.txt changed on a refusal"
  grep -q 'event job-1 mine CEILING_REFUSED' "$T/jobs.log" && ok || bad "$l: no CEILING_REFUSED job event ($(cat "$T/jobs.log"))"
}

# 1. over ceiling
reset
echo '{"lanes":[{"lane":"rule-miner","stage":"mine","ceiling_tokens":1000}]}' > "$T/small.json"
miner env CONTEXT_BUDGETS="$T/small.json"; refused "over ceiling" 1000 $?

# 2. missing lane
reset
echo '{"lanes":[{"lane":"other","ceiling_tokens":999999}]}' > "$T/nolane.json"
miner env CONTEXT_BUDGETS="$T/nolane.json"; refused "missing lane" unknown $?

# 3. unreadable catalog
reset
miner env CONTEXT_BUDGETS="$T/does-not-exist.json"; refused "unreadable catalog" unknown $?

# 3b. a ceiling that is not a positive integer fails closed too
reset
echo '{"lanes":[{"lane":"rule-miner","ceiling_tokens":"180000"}]}' > "$T/strceil.json"
miner env CONTEXT_BUDGETS="$T/strceil.json"; refused "string ceiling" unknown $?

# 4 + 5 + 7. under ceiling (real catalog), stage and runner, prompt
reset
miner env RUNNER_TRIAGE=grok; RC=$?
[ "$RC" = 0 ] && ok || bad "under ceiling: rc $RC, want 0 ($(cat "$LOG" "$ALERTS"))"
[ "$(ncalls)" = 1 ] && ok || bad "under ceiling: $(ncalls) agent calls, want exactly 1"
grep -q '^argv1=mine argv2=rule-miner ' "$T/calls.log" && ok \
  || bad "stage: agent-call argv is not 'mine rule-miner' ($(cat "$T/calls.log"))"
grep -q ' AGENT_CALL_RUNNERS=claude RUNNER_TRIAGE=grok$' "$T/calls.log" && ok \
  || bad "runner: AGENT_CALL_RUNNERS is not pinned to claude while RUNNER_TRIAGE=grok ($(cat "$T/calls.log"))"
grep -q '^open mine/rule-miner/claude stage=mine$' "$T/jobs.log" && ok \
  || bad "job lane is not mine/rule-miner/claude ($(cat "$T/jobs.log"))"
grep -qF "$MINDIR/digest.md" "$T/prompt.txt" 2>/dev/null && ok || bad "prompt does not name $MINDIR/digest.md"
[ -f "$T/prompt.txt" ] && ! grep -q 'Read every bundle' "$T/prompt.txt" && ok \
  || bad "prompt still says 'Read every bundle' (or no prompt captured)"
seen_same && ok || bad "NO_RULE marked incidents seen"

# 6. grok route: refused before any call
reset
printf '0\tgrok-4.6\tgrok\n' > "$T/state/model-routes/rule.miner.tsv"
miner; RC=$?
[ "$RC" = 75 ] && ok || bad "grok route: rc $RC, want 75"
[ "$(ncalls)" = 0 ] && ok || bad "grok route: agent-call invoked $(ncalls)x"
grep -q 'rule.miner routes to runner grok; only the claude runner is context-metered' "$ALERTS" && ok \
  || bad "grok route: no ALERTS line naming the runner ($(cat "$ALERTS"))"

# 8. seen = digest-ids: the digest covers 1 of the 2 incidents; after a PR only
#    that one is marked, the other comes back next week.
reset
cat > "$T/bin/rule-miner-digest.sh" <<'EOF'
#!/bin/bash
{ echo "# Rule-miner digest"; head -1 "$2" | cut -f2,4; } > "$3"
head -1 "$2" | cut -f2 > "$4"
EOF
chmod +x "$T/bin/rule-miner-digest.sh"
miner env STUB_DRAFT="## Mined 2026-09-24 (rule-miner)\n- **D2 Do the thing.** cite manual:alpha" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "seen: PR run rc $RC ($(cat "$LOG" "$ALERTS"))"
WANT=$(printf '%s\nmanual:alpha\n' "$SEEN0" | sort)
[ "$(sort "$T/state/rule-mining/seen.txt")" = "$WANT" ] && ok \
  || bad "seen.txt is not exactly the digest's ids: $(tr '\n' ' ' < "$T/state/rule-mining/seen.txt")"
grep -q 'PR awaiting the operator: https://.* context_tokens=none cost_usd=none week_spend_usd=none$' "$LOG" && ok \
  || bad "PR-opened line carries no spend figures ($(cat "$LOG"))"

# 9. spend line
AGO5=$(date -u -d '5 days ago' +%Y-%m-%dT%H:%M:%SZ)
AGO9=$(date -u -d '9 days ago' +%Y-%m-%dT%H:%M:%SZ)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
spend_fixture() { # spend_fixture <header>
  { echo "$1"
    "$T/mkrow.sh" "$1" "$AGO9" rule-miner 1 1 5.00
    "$T/mkrow.sh" "$1" "$AGO5" rule-miner 9000000 0 1.99
    "$T/mkrow.sh" "$1" "$NOW" other 5 5 7.00
    "$T/mkrow.sh" "$1" "$NOW" rule-miner-2 5 5 3.00
  } > "$T/logs/cost.csv"
}
spend_case() { # spend_case <label> <header> <cost> <want>
  reset; spend_fixture "$2"
  miner env CANNED_COST_ROW="120000 30000 $3" >/dev/null
  L=$(grep 'no prose rule worth adding' "$LOG")
  grep -q " $4\$" <<<"$L" && ok || bad "$1: want '$4' on the NO_RULE line ($(cat "$LOG"))"
}
spend_case "spend" "$HDR" 0.84 "context_tokens=150000 cost_usd=0.84 week_spend_usd=2.83"
spend_case "unpriced" "$HDR" "" "context_tokens=150000 cost_usd=UNPRICED week_spend_usd=UNPRICED"
PERM=$(tr , '\n' <<<"$HDR" | tac | paste -sd, -)
spend_case "permuted header" "$PERM" 0.84 "context_tokens=150000 cost_usd=0.84 week_spend_usd=2.83"

# 10. hub lanes: the hub runs stage mine
L=$(. "$DIR/bin/lib/hub-box.sh" && hub_no_build_lanes)
[ -n "$L" ] && ! grep -qw mine <<<"$L" && ok || bad "hub_no_build_lanes blocks mine: '$L'"

# 11. DRY prints the digest path and its token estimate, and calls nothing
reset
OUT=$(miner env RULE_MINER_DRY=1); RC=$?
[ "$RC" = 0 ] && ok || bad "dry: rc $RC"
grep -qE "^digest: $MINDIR/digest.md \(~[0-9]+ tokens\)\$" <<<"$OUT" && ok || bad "dry: no digest line ($OUT)"
[ "$(ncalls)" = 0 ] && ok || bad "dry: agent-call invoked"

echo "rule-miner-ceiling: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
