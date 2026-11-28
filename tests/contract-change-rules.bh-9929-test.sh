#!/bin/bash
# tests/contract-change-rules.bh-9929-test.sh — BH-9929 T4 (acceptance A10).
# The two rule sentences of Scope 7 reach the PLAN, REVIEW and lead-review
# prompts (prompts/iron-laws.d through bin/agent-call.sh, driven with a fake
# claude) and the fleet rules render rules/CLAUDE.md. execute and triage do not
# carry the law set (it is a plan/review rule).
# Run: HARNESS_TEST_SANDBOX=1 bash tests/contract-change-rules.bh-9929-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
. "$DIR/bin/lib/stage-iron-laws.sh" || { echo "FAIL: bin/lib/stage-iron-laws.sh missing"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LAWS_DIR="$DIR/prompts/iron-laws.d"
FRAG="$LAWS_DIR/20261124-contract-change.md"
S1='Do not clone a table or add a one-to-one side table to get around the additive-only gate. File a contract-change ticket.'
S2='Prefer a lookup table or a validated text column over a CHECK list for a set of values that grows.'

[ "$(head -1 "$FRAG" 2>/dev/null)" = "stages: plan review lead-review" ] && ok || bad "R1 stages line: '$(head -1 "$FRAG" 2>/dev/null)'"
for st in plan review lead-review; do
  got=$(sil_text "$st" "$LAWS_DIR")
  grep -qF -- "$S1" <<<"$got" && grep -qF -- "$S2" <<<"$got" && ok || bad "R2 sil_text $st lacks a sentence"
done
for st in execute triage; do
  grep -qF -- "$S1" <<<"$(sil_text "$st" "$LAWS_DIR")" && bad "R3 non-member $st carries the law" || ok
done
grep -qF -- "$S1" "$DIR/rules/CLAUDE.md" && grep -qF -- "$S2" "$DIR/rules/CLAUDE.md" && ok || bad "R4 rules/CLAUDE.md lacks a sentence"
grep -qF -- "$S1" "$DIR/rules/topics/04-building-software.md" && ok || bad "R5 the topic file lacks sentence 1"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/render-rules.sh" --check >/dev/null 2>&1 && ok || bad "R6 render-rules --check is not clean"

# Driven: the production entry point, bin/agent-call.sh, with a fake claude
# (the same scratch harness as tests/iron-law-user-flows.bh-8029-test.sh).
mrs_fixture "$T" sample-project
mkdir -p "$T/bin" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/env" "$T/wt" "$T/builds/b1"
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in *" --help "*) printf -- '  --session-id <uuid>\n'; exit 0 ;; esac
n=$(( $(wc -l < "$SINK" 2>/dev/null || echo 0) + 1 ))
printf '%q ' "$@" >> "$SINK"; printf '\n' >> "$SINK"
: > "$SINK.append.$n"; prev=""
for a in "$@"; do
  [ "$prev" = --append-system-prompt ] && printf '%s\n<<END>>\n' "$a" >> "$SINK.append.$n"
  prev="$a"
done
cat > "$SINK.stdin.$n"
printf '{"type":"result","result":"ok","num_turns":1,"usage":{"input_tokens":5,"output_tokens":1},"total_cost_usd":0.01}\n'
exit 0
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/alert-line.sh"
printf '#!/bin/bash\necho "fixture machine rules"\n' > "$T/bin/sync-agent-rules.sh"
printf '#!/bin/bash\necho "1 2 3 4"\n' > "$T/bin/codex-usage.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/iron-law-guard.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh
echo '{}' > "$T/catalog.json"
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "R0 setup: lanes-build.sh could not compose the registry"
mkdir -p "$T/prompts"; cp -R "$LAWS_DIR" "$T/prompts/"

OUTF="$T/builds/b1/out.txt"
run_call() {
  local st="$1"
  : > "$T/sink"; rm -f "$T/sink".*; rm -f "$OUTF"*; rm -rf "$T/state/lane-gate"
  rm -f "$T/state/model-cooldown-"*
  ( cd "$T/wt" || exit 1
    export SINK="$T/sink" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" LANE_REGISTRY="$REG" \
           LADDER_BACKOFF_SECS=0 HUB_BUILD_OK=1 \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" AUTH_ACCOUNTS_CATALOG="$T/catalog.json" \
           JOBS_URL=''
    for s in PREPLAN PLAN EXECUTE FIX REVIEW QA PRODQA TRIAGE LEAD_REVIEW; do export "RUNNER_$s=claude"; done
    env -u ACCOUNT_ROUTING -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN \
        -u ANTHROPIC_API_KEY -u AGENT_ADVISOR_MODEL -u AGENT_ADVISOR_STAGES -u AGENT_SYSTEM_APPEND \
        -u LANE_GATE_DISABLE -u CLAUDE_CONFIG_DIR -u AGENT_CALL_NO_TOOLS \
        bash "$DIR/bin/agent-call.sh" "$st" sample-project claude-opus-5-5 600 "$OUTF" "hello" >/dev/null 2>&1 )
  echo $?
}
append_has() { grep -qF -- "$1" "$T/sink.append.1" 2>/dev/null; }

for st in plan review lead-review; do
  RC=$(run_call "$st")
  [ -s "$T/sink" ] || { bad "R7 $st: claude never ran (rc=$RC)"; continue; }
  append_has "$S1" && append_has "$S2" && ok || bad "R7 $st: a sentence is not in --append-system-prompt"
done
RC=$(run_call execute)
[ -s "$T/sink" ] || bad "R8 execute: claude never ran (rc=$RC)"
append_has "$S1" && bad "R8 execute: a non-member stage got the law" || ok

# R9: the fragment names "additive-only" (sentence S1), so it must not also say
# "iron law": tests/iron-law-index-retention.bh-6730-test.sh treats a file with
# both as a carrier of the full iron-law list and then requires the
# index/retention law in it. This fragment carries one rule, not the list.
grep -qi 'iron law' "$FRAG" && bad "R9 $FRAG says 'iron law' and 'additive-only': BH-6730 reads it as a full iron-law list" || ok

echo "contract-change-rules.bh-9929: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
