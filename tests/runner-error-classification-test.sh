#!/bin/bash
# tests/runner-error-classification-test.sh — STATUS BEFORE BODY on the runner
# side too (BH-642 fix 2).
#
# WHAT WENT WRONG. An account that runs out of credits answers the CLI with a
# non-2xx whose body names them ("Insufficient credits", "Credit balance is too
# low"). bin/agent-call.sh classified by regex ONLY, in the order exhaust ->
# auth -> transient, and read no status token at all. Two consequences, both
# paid for on 2026-09-15/16:
#   - a credits 403 matched \b403\b in LADDER_AUTH_REGEX first and was logged as
#     auth(credential) — the ladder rotated for the wrong reason and the log said
#     the wrong thing;
#   - a 429 whose body says "rate limit reached" matched `limit reached` in
#     LADDER_EXHAUST_REGEX first and COOLED AN ACCOUNT DOWN for six hours over a
#     blip that wanted a retry;
#   - and when the whole ladder burned, bin/run-build.sh rendered it as "plan
#     session produced no output", indistinguishable from a model that ran and
#     said nothing.
#
# So the contract this pins: an explicit vendor STATUS token is read first, and
# it decides. 429 -> RUNNER_RATE_LIMITED (retry, same account, no cooldown).
# 400/402/403 WITH credit words -> RUNNER_EXHAUSTED (cool down, next account).
# Anything else -> RUNNER_ERROR, with today's behaviour untouched. And the
# negatives matter as much as the positives: a 403 that is really a disabled
# organization, a 400 tool-use error, and a model that merely TALKS about
# insufficient credits must none of them be read as exhaustion.
#
# DRIVEN, NOT GREPPED: bin/agent-call.sh is executed for real against a temp
# HARNESS with fake CLIs (fixture shape from tests/ladder-recovery-test.sh), and
# bin/run-build.sh's own verdict block is extracted and executed verbatim.
#
# Run from anywhere: tests/runner-error-classification-test.sh (exit 0 = pass)
set -uo pipefail
# tests/lib/scratch.sh is not in git yet (#394). Until it lands this suite owns
# its own scratch tree, on ONE line so the source still precedes the first
# mktemp for checks/tests-scratch-only R1.
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || { T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; }
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin" "$T/bin/lib" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/env/accounts.d"
# The pipeline as ONE text (BH-478 seam): section 5 lifts run-build's verdict
# block by its markers, so it must read the flatten rather than the driver —
# the block moves into a stage module as the split proceeds, and the flatten
# puts every moved body back at its call site.
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ---------- fakes -----------------------------------------------------------
# Every body below is a REAL one: the Anthropic CLI's own credit wording, the
# OpenRouter 402 text, and Anthropic's rate_limit_error envelope. A fixture the
# wire never produces proves nothing (D4/D35).
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in
  *" --help "*) printf -- '  --resume <sessionId>\n  --session-id <uuid>\n'; exit 0 ;;
esac
printf 'claude cfg=%s args=%s\n' "${CLAUDE_CONFIG_DIR:-default}" "$*" >> "$ORDER_SINK"
N=$(grep -c '^claude ' "$ORDER_SINK")
if [ "$N" -gt "${CLAUDE_FAIL_TIMES:-99}" ]; then
  printf '{"result":"ok","usage":{"input_tokens":5,"output_tokens":1},"total_cost_usd":0.01}\n'
  exit 0
fi
case "${CLAUDE_MODE:-credits}" in
  credits)     echo 'API Error: 403 {"type":"error","error":{"type":"permission_error","message":"Insufficient credits: out_of_credits"}}' >&2; exit 1 ;;
  balance)     echo 'API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API."}}' >&2; exit 1 ;;
  or402)       echo 'API Error: 402 {"error":{"code":402,"message":"Insufficient credits. Add more using https://openrouter.ai/settings/credits"}}' >&2; exit 1 ;;
  ratelimit)   echo 'API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded your per-minute rate limit reached"}}' >&2; exit 1 ;;
  disabled)    echo 'API Error: 403 {"type":"error","error":{"type":"permission_error","message":"This organization has been disabled."}}' >&2; exit 1 ;;
  tooluse)     echo 'API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"duplicate tool_use ID"}}' >&2; exit 1 ;;
  fivehundred) echo 'API Error: 503 {"type":"error","error":{"type":"api_error","message":"Overloaded, please retry"}}' >&2; exit 1 ;;
  prose)       printf '{"result":"I checked and the user has insufficient credits in their account, so I stopped","usage":{"input_tokens":5,"output_tokens":1}}\n'; exit 1 ;;
esac
EOF
cat > "$T/fakebin/grok" <<'EOF'
#!/bin/bash
echo "grok cfg=- args=-" >> "$ORDER_SINK"
[ "${GROK_RESULT:-fail}" = ok ] && { echo "grok answered"; exit 0; }
echo "grok is not configured" >&2; exit 1
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
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
printf '#!/bin/bash\necho "1 2 3 4"\n' > "$T/bin/codex-usage.sh"
cp "$DIR/bin/account-pick.sh" "$T/bin/account-pick.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh

mkdir -p "$T/.claude-a" "$T/.claude-b"
cat > "$T/env/accounts.d/b.env" <<EOF
ACCOUNT_NAME=b
ACCOUNT_VENDOR=claude
ACCOUNT_PRIORITY=10
CLAUDE_CONFIG_DIR=$T/.claude-b
EOF
cat > "$T/env/accounts.d/a.env" <<EOF
ACCOUNT_NAME=a
ACCOUNT_VENDOR=claude
ACCOUNT_PRIORITY=20
CLAUDE_CONFIG_DIR=$T/.claude-a
EOF
chmod 600 "$T/env/accounts.d"/*.env
DEFAULT_CRED="sk-ant-oat01-FIXTURE-do-not-ship"

reset() { : > "$T/order"; : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"
          rm -rf "$T/state/quota"; rm -f "$T/state/model-cooldown-"* "$T/out.txt" "$T/out.txt.class"; }
run_call() { # run_call <model> <extra env…>
  local model="$1"; shift
  reset
  ( export ORDER_SINK="$T/order" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           ACCOUNTS_DIR="$T/env/accounts.d" LADDER_BACKOFF_SECS=0 LADDER_TIER2_GROK=1 \
           RUNNER_EVAL=claude CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
    env -u ACCOUNT_ROUTING -u RUNNER_EVAL_FALLBACK -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY \
      -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY \
      "$@" bash "$DIR/bin/agent-call.sh" eval testproj "$model" 600 "$T/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}
lanes() { cut -d' ' -f1 "$T/order" | paste -sd,; }
count() { grep -c "^$1 " "$T/order" 2>/dev/null || echo 0; }
cfgs()  { cut -d' ' -f2 "$T/order" | paste -sd,; }
FL="$T/logs/failovers.log"

# =============================================================================
# 1. A CREDITS 403 IS EXHAUSTION, NOT AUTH — and the ladder advances an account.
# =============================================================================
for MODE in credits balance or402; do
  RC=$(run_call claude-opus-5 env ACCOUNT_ROUTING=1 CLAUDE_MODE="$MODE" CLAUDE_FAIL_TIMES=1 \
       GROK_RESULT=ok CLAUDE_CODE_OAUTH_TOKEN="$DEFAULT_CRED")
  [ "$RC" = 0 ] && ok || bad "1/$MODE: the rotation did not recover the stage (rc=$RC)"
  grep -q 'class=account-exhausted(credits)' "$FL" \
    && ok || bad "1/$MODE: a credits status was not classified account-exhausted(credits): $(tail -2 "$FL")"
  grep -q 'token=RUNNER_EXHAUSTED' "$FL" \
    && ok || bad "1/$MODE: the failovers line carries no token=RUNNER_EXHAUSTED: $(tail -2 "$FL")"
  [ "$(cfgs)" = "cfg=$T/.claude-b,cfg=$T/.claude-a" ] \
    && ok || bad "1/$MODE: the ladder did not advance to the next account: $(cfgs)"
  # The cooldown ledger is keyed by VENDOR then account since BH-940
  # (state/quota/cooldown/<vendor>/<name>) — same assertion, current path.
  [ -f "$T/state/quota/cooldown/claude/b" ] \
    && ok || bad "1/$MODE: the out-of-credits account was not cooled down for the picker"
  grep -q '^grok ' "$T/order" \
    && bad "1/$MODE: the vendor ladder engaged while another Claude account had headroom" || ok
done

# =============================================================================
# 2. A 429 IS A RETRY, NOT AN ACCOUNT CHANGE — even when its body says "limit
#    reached", which is exactly what LADDER_EXHAUST_REGEX used to grab first.
# =============================================================================
RC=$(run_call claude-opus-5 env ACCOUNT_ROUTING=1 CLAUDE_MODE=ratelimit CLAUDE_FAIL_TIMES=1 \
     GROK_RESULT=ok CLAUDE_CODE_OAUTH_TOKEN="$DEFAULT_CRED")
[ "$RC" = 0 ] && ok || bad "2: the retry did not recover the stage (rc=$RC)"
grep -q 'class=transient(rate_limited)' "$FL" \
  && ok || bad "2: a 429 was not classified transient(rate_limited): $(tail -2 "$FL")"
grep -q 'token=RUNNER_RATE_LIMITED' "$FL" \
  && ok || bad "2: the failovers line carries no token=RUNNER_RATE_LIMITED: $(tail -2 "$FL")"
[ "$(cfgs)" = "cfg=$T/.claude-b,cfg=$T/.claude-b" ] \
  && ok || bad "2: a 429 must retry the SAME account, got $(cfgs)"
[ ! -d "$T/state/quota/cooldown" ] \
  && ok || bad "2: a 429 must not cool an account down: $(ls "$T/state/quota/cooldown")"

# =============================================================================
# 3. EVERYTHING ELSE IS RUNNER_ERROR, with today's behaviour unchanged.
#    These are the adversarial negatives: none of them may read as exhaustion.
# =============================================================================
RC=$(run_call claude-opus-5 env ACCOUNT_ROUTING=1 CLAUDE_MODE=disabled CLAUDE_FAIL_TIMES=1 \
     GROK_RESULT=ok CLAUDE_CODE_OAUTH_TOKEN="$DEFAULT_CRED")
grep -q 'class=auth(credential)' "$FL" \
  && ok || bad "3: a 403 with no credit words must stay auth(credential): $(tail -2 "$FL")"
grep -q 'class=account-exhausted' "$FL" \
  && bad "3: a disabled organization was read as out of credits" || ok
grep -q 'token=RUNNER_ERROR' "$FL" \
  && ok || bad "3: an auth failure must carry token=RUNNER_ERROR: $(tail -2 "$FL")"

RC=$(run_call claude-opus-5 env ACCOUNT_ROUTING=1 CLAUDE_MODE=tooluse GROK_RESULT=ok)
grep -qE 'class=(account-exhausted|transient\(rate_limited\))' "$FL" \
  && bad "3b: a 400 tool_use error was classified as exhaustion/rate-limit: $(tail -2 "$FL")" || ok
grep -q 'token=RUNNER_ERROR' "$FL" \
  && ok || bad "3b: a 400 tool_use error must be RUNNER_ERROR: $(tail -2 "$FL")"

RC=$(run_call claude-opus-5 env ACCOUNT_ROUTING=1 CLAUDE_MODE=prose GROK_RESULT=ok)
grep -q 'class=account-exhausted' "$FL" \
  && bad "3c: a MODEL ANSWER that talks about insufficient credits was read as exhaustion: $(tail -2 "$FL")" || ok
grep -q 'class=real-failure(agent)' "$FL" \
  && ok || bad "3c: a model answer that failed must stay real-failure(agent): $(tail -2 "$FL")"

RC=$(run_call claude-opus-5 env ACCOUNT_ROUTING=1 CLAUDE_MODE=fivehundred CLAUDE_FAIL_TIMES=1 \
     GROK_RESULT=ok CLAUDE_CODE_OAUTH_TOKEN="$DEFAULT_CRED")
grep -q 'class=transient(vendor)' "$FL" \
  && ok || bad "3d: a 503 must stay transient(vendor), not rate_limited: $(tail -2 "$FL")"
grep -q 'rate_limited' "$FL" \
  && bad "3d: a 503 was misread as a rate limit" || ok

# =============================================================================
# 4. THE STAGE'S VERDICT SURVIVES THE WHOLE LADDER BURNING.
#    Every account out of credits, then every vendor gone: the sidecar must
#    still name the exhaustion, or the run-build copy below has nothing to say.
# =============================================================================
RC=$(run_call claude-opus-5 env ACCOUNT_ROUTING=1 CLAUDE_MODE=credits GROK_RESULT=fail \
     CLAUDE_CODE_OAUTH_TOKEN="$DEFAULT_CRED")
[ "$RC" != 0 ] && ok || bad "4: the all-lanes-failed run exited 0"
[ -s "$T/out.txt.class" ] && ok || bad "4: no <outfile>.class sidecar was written on a failed stage"
[ "$(cut -d' ' -f1 "$T/out.txt.class" 2>/dev/null)" = RUNNER_EXHAUSTED ] \
  && ok || bad "4: the sidecar must lead with RUNNER_EXHAUSTED, got '$(cat "$T/out.txt.class" 2>/dev/null)'"
grep -q 'seen=' "$T/out.txt.class" \
  && ok || bad "4: the sidecar must carry every class seen: $(cat "$T/out.txt.class")"

# A stage that SUCCEEDS leaves no sidecar, so a later reader cannot render a
# stale verdict over a good run.
RC=$(run_call claude-opus-5 env ACCOUNT_ROUTING=1 CLAUDE_MODE=credits CLAUDE_FAIL_TIMES=1 \
     GROK_RESULT=ok CLAUDE_CODE_OAUTH_TOKEN="$DEFAULT_CRED")
[ ! -e "$T/out.txt.class" ] && ok || bad "5: a recovered stage left a stale .class sidecar"

# =============================================================================
# 5. bin/run-build.sh NEVER RENDERS EXHAUSTION AS "no output".
#    The shipped block is EXTRACTED and EXECUTED — not grepped.
# =============================================================================
awk '/# >>> plan empty-output verdict/{p=1;next} /# <<< plan empty-output verdict/{p=0} p' \
  "$RB_ALL" > "$T/verdict.sh"
[ -s "$T/verdict.sh" ] && ok || bad "5: the plan empty-output verdict block is not marked in the pipeline text"

verdict() { # verdict <class-file-contents|-> ; prints the RESULT line
  local cls="$1" B="$T/b"
  rm -rf "$T/b"; mkdir -p "$B"; : > "$B/plan.md"
  [ "$cls" = "-" ] || printf '%s\n' "$cls" > "$B/plan-run.txt.class"
  ( BUILD="$B"
    BB() { printf 'BB %s\n' "$*" >> "$B/calls.txt"; }
    RESULT() { printf 'RESULT %s\n' "$*" >> "$B/calls.txt"; }
    # shellcheck disable=SC1090
    . "$T/verdict.sh" ) >/dev/null 2>&1
  cat "$B/calls.txt" 2>/dev/null
}

V=$(verdict 'RUNNER_EXHAUSTED class=account-exhausted(credits) seen=account-exhausted runner=claude rc=1')
grep -q 'RESULT BUILD_DEFERRED' <<<"$V" \
  && ok || bad "5: the deferral prefix must not change (consumers route on it): $V"
grep -q 'RUNNER_EXHAUSTED' <<<"$V" \
  && ok || bad "5: an exhausted plan stage must name the token: $V"
grep -q 'produced no output' <<<"$(printf '%s' "$V")" \
  && bad "5: an exhausted plan stage still rendered as 'produced no output': $V" || ok

# D13 — with no sidecar the old copy is rendered verbatim, because that state
# still happens and the sentence is still true in it.
V=$(verdict -)
grep -q 'RESULT BUILD_DEFERRED plan session produced no output' <<<"$V" \
  && ok || bad "5: with no .class the original copy must be unchanged: $V"
grep -q 'BB plan_deferred' <<<"$V" \
  && ok || bad "5: the build-board call must still fire: $V"

echo "runner-error-classification: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
