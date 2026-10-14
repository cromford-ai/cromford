#!/bin/bash
# tests/account-routing-test.sh — quota-aware account routing, driven end to end.
#
# WHY DRIVEN AND NOT GREPPED (same rule as agent-call-notools-test.sh and
# cost-account-attrib-test.sh): the whole feature is a claim about the
# ENVIRONMENT a child process runs with, and about a code path that is supposed
# to be invisible when the flag is off. A grep can show that the guard exists; it
# cannot show that the guard holds. So bin/agent-call.sh is executed for real
# against a temp HARNESS with fake CLIs on PATH, and the fake claude reports back
# WHICH credentials it was handed.
#
# It needs no network and no live lane: the OAuth usage endpoint is behind a stub
# fetcher (OAUTH_USAGE_FETCH), every provider is a fake on PATH.
#
# Covered, in order:
#   1  off is off — ACCOUNT_ROUTING unset/0 never invokes the picker at all
#   2  no registry -> `default`, zero export/unset lines
#   3  priority order, ACCOUNT_ENABLED
#   4  the 5h / weekly / per-model thresholds and their env overrides
#   5  a stale or unreadable poll counts as AVAILABLE, never as exhausted
#   6  cooldown excludes, and expires
#   7  the sticky per-build pin, honoured and dropped when ineligible
#   8  the ACCOUNT_MODELS allowlist
#   9  exit 2 -> rc 76 -> the ladder steps down without buying a call
#   10 exports/unsets reach the CHILD and never the parent
#   11 exhaustion -> account cooldown -> exactly one retry, per-account model cooldown
#   12 cost-row attribution (acct:<name> as a fallback, never over a real label)
#   13 quota-poll writes valid json and leaks no token
#   14 quota-status renders at phone width with no secret in it
#   15 registry validation refuses bad files instead of crashing
#   16 the cron line is installed on every live box, or its absence is declared
#   17 the exhaustion scan reads the CLI's OWN error stream on the codex lane
# Run from anywhere: tests/account-routing-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1510.1: agent-call reads its ladders from model_routes; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" testproj
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
# TEST-CHANGE (BH-5651): the crontabs render from this repo's registry, as a
# cache under $T/rh read in db mode (render-cron.sh takes .lane_boxes and the
# project rows from it), not from $DIR/fleet.conf. The render runs once, in a
# subshell that holds HARNESS and db mode; rendered_cron_dir reuses its files.
. "$DIR/tests/lib/registry-cache.bh-5651.sh" || exit 1
( rcache_install "$T/rh" "$DIR" && export HARNESS="$T/rh" && rendered_cron_dir >/dev/null ) \
  || { echo "FAIL: could not build this repo's registry cache or render the fleet from it"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Recognisable fake secrets. If any of these ever appears under state/ or logs/,
# the feature is leaking.
TOKB="sk-ant-oat01-FIXTURE-ACCESS-do-not-ship-b"
TOKC="sk-ant-oat01-FIXTURE2-do-not-ship-c"
KEYE="or-FIXTURE3-do-not-ship-e"
PARENT_TOKEN="sk-ant-oat01-FIXTURE-PARENT-token"

mkdir -p "$T/bin" "$T/lib" "$T/fakebin" "$T/env/accounts.d" "$T/state" "$T/logs" "$T/flags" "$T/locks"

# ---------- the harness under test ------------------------------------------
for f in account-pick.sh quota-poll.sh quota-status.sh; do
  cp "$DIR/bin/$f" "$T/bin/$f"; chmod +x "$T/bin/$f"
done
mkdir -p "$T/bin/lib"
cp "$DIR/bin/lib/oauth-usage-fetch.py" "$T/bin/lib/"
cp "$DIR/bin/lib/pool-account.sh" "$T/bin/lib/pool-account.sh"
cp "$DIR/bin/auth-fingerprint.sh" "$T/bin/auth-fingerprint.sh"

# ---------- fakes ------------------------------------------------------------
# The fake claude REPORTS ITS CREDENTIAL ENV rather than using it — that report
# is the only way to prove the export/unset contract actually reached the child.
# The token's VALUE is never written to the sink, only set/unset, because a test
# that prints secrets to prove secrets are handled is its own bug.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
M=""
for a in "$@"; do case "$a" in claude-*) M="$a" ;; esac; done
printf 'claude|%s|%s|%s|%s\n' "${CLAUDE_CONFIG_DIR:-NONE}" \
  "$([ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo set || echo unset)" \
  "$([ -n "${ANTHROPIC_API_KEY:-}" ] && echo set || echo unset)" "$M" >> "$ORDER_SINK"
if [ -n "${CREDITS_LIST:-}" ] && grep -qxF "${CLAUDE_CONFIG_DIR:-default}" "$CREDITS_LIST" 2>/dev/null; then
  echo "${CREDITS_TEXT:-Claude AI: out of usage credits for this account}" >&2
  exit 1
fi
printf '{"result":"ok","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}\n'
EOF
cat > "$T/fakebin/grok" <<'EOF'
#!/bin/bash
echo 'grok|-|-|-|-' >> "$ORDER_SINK"
echo "grok answered"
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
cat > "$T/bin/billing-mode.sh" <<'EOF'
#!/bin/bash
echo subscription
EOF
cat > "$T/bin/beat.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$T/bin/sync-agent-rules.sh" <<'EOF'
#!/bin/bash
echo "test rules"
EOF
# The picker the LADDER sees: a tripwire that records every invocation and then
# hands over to the real one. Test 1 asserts this file is never touched with the
# flag off — "the hook did not run" has to be observed, not assumed.
mv "$T/bin/account-pick.sh" "$T/bin/account-pick-real.sh"
cat > "$T/bin/account-pick.sh" <<'EOF'
#!/bin/bash
# Records every EXECUTION and hands over to the real picker. quota-poll.sh and
# quota-status.sh SOURCE this file as a library, so the tripwire is fenced on
# "am I being run" — otherwise sourcing it would exec the picker with no args.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "invoked $*" >> "$PICK_SINK"
  exec "$(dirname "${BASH_SOURCE[0]}")/account-pick-real.sh" "$@"
fi
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/account-pick-real.sh"
EOF
chmod +x "$T/fakebin/"* "$T/bin/"*.sh
export PICK_SINK="$T/pick.log"; : > "$PICK_SINK"

# ---------- fixtures ---------------------------------------------------------
reg() { # reg <name> <<'EOF' ... EOF   — write one registry file
  cat > "$T/env/accounts.d/$1.env"; chmod 600 "$T/env/accounts.d/$1.env"
}
clear_reg() { rm -f "$T/env/accounts.d"/*.env 2>/dev/null; }
clear_state() { rm -rf "$T/state/quota"; }
mkdir -p "$T/.claude-a" "$T/.claude-b"

two_claude_accounts() {
  clear_reg
  reg a <<EOF
ACCOUNT_NAME=a
ACCOUNT_VENDOR=claude
ACCOUNT_PRIORITY=20
ACCOUNT_LABEL=a@example.test
CLAUDE_CONFIG_DIR=$T/.claude-a
EOF
  reg b <<EOF
ACCOUNT_NAME=b
ACCOUNT_VENDOR=claude
ACCOUNT_PRIORITY=10
CLAUDE_CONFIG_DIR=$T/.claude-b
EOF
}

pick() { # pick <extra-env...> -- <stage> <vendor> <model> ; echoes stdout, sets PRC
  local envs=() ; while [ "${1:-}" != "--" ]; do envs+=("$1"); shift; done; shift
  PICK_OUT=$(env HARNESS="$T" HOME="$T" ACCOUNTS_DIR="$T/env/accounts.d" \
    "${envs[@]}" bash "$T/bin/account-pick-real.sh" "$@" 2>/dev/null); PRC=$?
  printf '%s\n' "$PICK_OUT"
}
pname() { pick "$@" | sed -n 's/^name=//p'; }
preason() { pick "$@" | sed -n 's/^reason=//p'; }

quota() { # quota <account> <status> <age-secs> <5h> <week> [family] [model-pct]
  mkdir -p "$T/state/quota"
  local ts; ts=$(date -u -d "@$(( $(date -u +%s) - $3 ))" '+%Y-%m-%dT%H:%M:%SZ')
  jq -n --arg a "$1" --arg s "$2" --arg t "$ts" --arg f "${6:-}" \
        --argjson five "${4:-null}" --argjson week "${5:-null}" --argjson mp "${7:-null}" \
    '{account:$a,vendor:"claude",status:$s,source:"oauth-usage",polled_at:$t,
      five_hour:(if $five==null then null else {pct:$five,resets_at:"2026-09-07T01:00:00Z"} end),
      seven_day:(if $week==null then null else {pct:$week,resets_at:"2026-09-10T17:00:00Z"} end),
      per_model:(if $f=="" or $mp==null then {} else {($f):{pct:$mp}} end)}' \
    > "$T/state/quota/$1.json"
}

# run_call <extra-env...> — drives bin/agent-call.sh for real. `eval` stage so
# CONTEXT_BUDGETS resolves the same way the other agent-call suites drive it.
run_call() {
  : > "$T/order"
  ( export ORDER_SINK="$T/order" PICK_SINK="$T/pick.log" PATH="$T/fakebin:$PATH" \
           HARNESS="$T" HOME="$T" ACCOUNTS_DIR="$T/env/accounts.d" \
           LADDER_BACKOFF_SECS=0 LADDER_TIER2_GROK=1 \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           AUTH_ACCOUNTS_CATALOG="$T/empty-catalog.json" \
           AUTH_ACCOUNTS_LOCAL="$T/state/auth-accounts.local.json" \
           RUNNER_EVAL=claude
    "$@" bash "$DIR/bin/agent-call.sh" eval testproj claude-fable-5-1 60 "$T/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}
echo '{}' > "$T/empty-catalog.json"

# =============================================================================
# 1. OFF IS OFF
# =============================================================================
two_claude_accounts
: > "$PICK_SINK"; rm -f "$T/logs/account-routing.log"; clear_state
RC=$(run_call env CLAUDE_CODE_OAUTH_TOKEN="$PARENT_TOKEN")
[ "$RC" = 0 ] && ok || bad "1: the claude lane failed with routing off (rc=$RC)"
[ ! -s "$PICK_SINK" ] && ok || bad "1: account-pick.sh ran with ACCOUNT_ROUTING unset: $(cat "$PICK_SINK")"
grep -q '^claude|NONE|set|' "$T/order" \
  && ok || bad "1: the child's credential env changed with routing off: $(cat "$T/order")"
[ ! -f "$T/logs/account-routing.log" ] && ok || bad "1: a routing log was written with routing off"
[ ! -d "$T/state/quota" ] && ok || bad "1: state/quota was created with routing off"

RC=$(run_call env ACCOUNT_ROUTING=0 CLAUDE_CODE_OAUTH_TOKEN="$PARENT_TOKEN")
[ "$RC" = 0 ] && [ ! -s "$PICK_SINK" ] && ok || bad "1: ACCOUNT_ROUTING=0 still invoked the picker"

RC=$(run_call env ACCOUNT_ROUTING=1 CLAUDE_CODE_OAUTH_TOKEN="$PARENT_TOKEN")
[ -s "$PICK_SINK" ] && ok || bad "1: ACCOUNT_ROUTING=1 did NOT invoke the picker"
[ "$RC" = 0 ] && ok || bad "1: the routed call failed (rc=$RC)"

# =============================================================================
# 2. NO REGISTRY -> default, and the child env is untouched
# =============================================================================
clear_reg; clear_state
[ "$(pname -- eval claude claude-fable-5-1)" = default ] \
  && ok || bad "2: an empty registry did not answer name=default"
[ "$(preason -- eval claude claude-fable-5-1)" = default ] \
  && ok || bad "2: an empty registry did not answer reason=default"
[ "$(pick -- eval claude claude-fable-5-1 | grep -c '^\(export\|unset\) ')" = 0 ] \
  && ok || bad "2: the default pick emitted export/unset lines"
: > "$PICK_SINK"
RC=$(run_call env ACCOUNT_ROUTING=1 CLAUDE_CODE_OAUTH_TOKEN="$PARENT_TOKEN")
grep -q '^claude|NONE|set|' "$T/order" \
  && ok || bad "2: routing on with no registry changed the child env: $(cat "$T/order")"

# =============================================================================
# 3. PRIORITY ORDER + ACCOUNT_ENABLED
# =============================================================================
two_claude_accounts; clear_state
[ "$(pname -- eval claude claude-fable-5-1)" = b ] || bad "3: lowest priority number did not win"
[ "$(preason -- eval claude claude-fable-5-1)" = priority ] || bad "3: reason was not 'priority'"
ok
echo 'ACCOUNT_ENABLED=0' >> "$T/env/accounts.d/b.env"
[ "$(pname -- eval claude claude-fable-5-1)" = a ] \
  && ok || bad "3: ACCOUNT_ENABLED=0 was ignored"
two_claude_accounts

# =============================================================================
# 4. THRESHOLDS
# =============================================================================
quota b ok 60 86 10
[ "$(pname -- eval claude claude-fable-5-1)" = a ] && ok || bad "4: five_hour 86 >= 85 did not drop b"
[ "$(pname ACCOUNT_5H_MAX=90 -- eval claude claude-fable-5-1)" = b ] \
  && ok || bad "4: ACCOUNT_5H_MAX=90 did not keep b at 86"
quota b ok 60 10 91
[ "$(pname -- eval claude claude-fable-5-1)" = a ] && ok || bad "4: seven_day 91 >= 90 did not drop b"
quota b ok 60 10 10 fable 95
[ "$(pname -- eval claude claude-fable-5-1)" = a ] \
  && ok || bad "4: per_model fable 95 did not drop b for a fable model"
[ "$(pname -- eval claude claude-opus-5)" = b ] \
  && ok || bad "4: per_model fable 95 wrongly dropped b for an opus model"
quota b ok 60 10 10
[ "$(pname -- eval claude claude-fable-5-1)" = b ] \
  && ok || bad "4: an account under every threshold was dropped anyway"

# =============================================================================
# 5. HEADROOM UNKNOWN IS NOT HEADROOM ZERO
# =============================================================================
quota b ok 99999 99 99 fable 99
[ "$(pname -- eval claude claude-fable-5-1)" = b ] \
  && ok || bad "5: a STALE poll over every threshold excluded the account"
for ST in unreadable unknown error unmetered; do
  quota b "$ST" 60 99 99 fable 99
  [ "$(pname -- eval claude claude-fable-5-1)" = b ] \
    || bad "5: status=$ST with high numbers excluded the account"
done
ok
rm -f "$T/state/quota/b.json"
[ "$(pname -- eval claude claude-fable-5-1)" = b ] \
  && ok || bad "5: an account with NO poll file at all was excluded"

# =============================================================================
# 6. COOLDOWN
# =============================================================================
mkdir -p "$T/state/quota/cooldown/claude"
date -u +%s > "$T/state/quota/cooldown/claude/b"
[ "$(pname -- eval claude claude-fable-5-1)" = a ] && ok || bad "6: a cooling account was still picked"
echo $(( $(date -u +%s) - 2 * 21600 )) > "$T/state/quota/cooldown/claude/b"
[ "$(pname -- eval claude claude-fable-5-1)" = b ] && ok || bad "6: an EXPIRED cooldown still excluded b"
echo $(( $(date -u +%s) - 5 )) > "$T/state/quota/cooldown/claude/b"
[ "$(pname -- eval claude claude-fable-5-1)" = a ] \
  || bad "6: a 5s-old stamp under the default 6h window did not exclude b"
[ "$(pname ACCOUNT_COOLDOWN_SECS=1 -- eval claude claude-fable-5-1)" = b ] \
  && ok || bad "6: ACCOUNT_COOLDOWN_SECS=1 did not shorten the window"
rm -f "$T/state/quota/cooldown/claude/b"

# =============================================================================
# 7. THE STICKY PIN
# =============================================================================
mkdir -p "$T/state/quota/pins"; echo a > "$T/state/quota/pins/build-x"
[ "$(pname ACCOUNT_PIN_KEY=build-x -- eval claude claude-fable-5-1)" = a ] \
  && ok || bad "7: a valid pin at worse priority was not honoured"
[ "$(preason ACCOUNT_PIN_KEY=build-x -- eval claude claude-fable-5-1)" = pinned ] \
  && ok || bad "7: the pinned pick did not report reason=pinned"
date -u +%s > "$T/state/quota/cooldown/claude/a"
[ "$(pname ACCOUNT_PIN_KEY=build-x -- eval claude claude-fable-5-1)" = b ] \
  && ok || bad "7: a pin naming a COOLING account was still honoured"
[ "$(cat "$T/state/quota/pins/build-x")" = b ] \
  && ok || bad "7: the pin was not re-pointed at the account that actually served"
rm -f "$T/state/quota/cooldown/claude/a"
echo nosuchaccount > "$T/state/quota/pins/build-x"
[ "$(pname ACCOUNT_PIN_KEY=build-x -- eval claude claude-fable-5-1)" = b ] \
  && ok || bad "7: a pin naming an unregistered account was not ignored"
# An unpinned call must not share a pin file with another unpinned call.
rm -rf "$T/state/quota/pins"
pname -- eval claude claude-fable-5-1 >/dev/null
[ ! -e "$T/state/quota/pins" ] && ok || bad "7: an unpinned pick wrote a pin file anyway"

# =============================================================================
# 8. ACCOUNT_MODELS ALLOWLIST
# =============================================================================
echo 'ACCOUNT_MODELS=claude-opus-5' >> "$T/env/accounts.d/b.env"
[ "$(pname -- eval claude claude-fable-5-1)" = a ] \
  && ok || bad "8: ACCOUNT_MODELS did not exclude b for a model it does not allow"
[ "$(pname -- eval claude claude-opus-5)" = b ] \
  && ok || bad "8: ACCOUNT_MODELS wrongly excluded b for a model it DOES allow"
two_claude_accounts

# =============================================================================
# 9. NO HEADROOM -> exit 2 -> rc 76 -> the ladder steps down without a call
# =============================================================================
mkdir -p "$T/state/quota/cooldown/claude"
for A in a b default; do date -u +%s > "$T/state/quota/cooldown/claude/$A"; done
pick -- eval claude claude-fable-5-1 >/dev/null
[ "$PRC" = 2 ] && ok || bad "9: every account excluded but the pick exited $PRC, not 2"
: > "$T/logs/failovers.log"; rm -f "$T/logs/cost.csv"
RC=$(run_call env ACCOUNT_ROUTING=1 CLAUDE_CODE_OAUTH_TOKEN="$PARENT_TOKEN")
[ "$RC" = 0 ] && ok || bad "9: the ladder did not recover after rc 76 (rc=$RC)"
[ "$(cut -d'|' -f1 "$T/order" | paste -sd,)" = grok ] \
  && ok || bad "9: expected grok only, got $(cut -d'|' -f1 "$T/order" | paste -sd,)"
grep -q 'no claude account with quota headroom' "$T/logs/failovers.log" \
  && ok || bad "9: the no-headroom step-down was not logged to failovers.log"
grep -q ',-,no_headroom$' "$T/logs/account-routing.log" \
  && ok || bad "9: no_headroom was not recorded in account-routing.log"
[ "$(grep -c '^2' "$T/logs/cost.csv" 2>/dev/null)" = 1 ] \
  && ok || bad "9: a call that never happened wrote a cost row ($(grep -c '^2' "$T/logs/cost.csv" 2>/dev/null) rows)"
# The refusal writes a MARKER into $OUT. AGENT_CALL_NO_TOOLS=1 gates every rung
# of the ladder, so this run is the case the marker exists for: nothing later
# writes that file, the caller reads it, and a stale answer from an earlier
# attempt at the same path would read as a real one.
for A in a b default; do date -u +%s > "$T/state/quota/cooldown/claude/$A"; done
echo 'STALE ANSWER FROM AN EARLIER ATTEMPT' > "$T/out.txt"
RC=$(run_call env ACCOUNT_ROUTING=1 AGENT_CALL_NO_TOOLS=1 CLAUDE_CODE_OAUTH_TOKEN="$PARENT_TOKEN")
grep -qx 'AGENT_CALL_NO_HEADROOM no claude account with quota headroom' "$T/out.txt" \
  && ok || bad "9: rc 76 left the output file without the no-headroom marker: $(head -1 "$T/out.txt")"
grep -q 'STALE ANSWER' "$T/out.txt" \
  && bad "9: a stale earlier answer survived the rc-76 refusal" || ok
rm -rf "$T/state/quota/cooldown"

# =============================================================================
# 10. EXPORTS REACH THE CHILD, NEVER THE PARENT
# =============================================================================
clear_reg
reg b <<EOF
ACCOUNT_NAME=b
ACCOUNT_VENDOR=claude
ACCOUNT_PRIORITY=10
CLAUDE_CONFIG_DIR=$T/.claude-b
EOF
OUTP=$(pick -- eval claude claude-fable-5-1)
grep -qx "export CLAUDE_CONFIG_DIR=$T/.claude-b" <<<"$OUTP" \
  && ok || bad "10: the config dir was not exported: $OUTP"
grep -qx 'unset CLAUDE_CODE_OAUTH_TOKEN' <<<"$OUTP" \
  && ok || bad "10: the shadowing env token was not unset: $OUTP"
grep -qx 'unset ANTHROPIC_API_KEY' <<<"$OUTP" \
  && ok || bad "10: ANTHROPIC_API_KEY was not unset: $OUTP"
export CLAUDE_CODE_OAUTH_TOKEN="$PARENT_TOKEN"
RC=$(run_call env ACCOUNT_ROUTING=1)
grep -q "^claude|$T/.claude-b|unset|unset|" "$T/order" \
  && ok || bad "10: the child did not run on b's credentials: $(cat "$T/order")"
[ "${CLAUDE_CODE_OAUTH_TOKEN:-}" = "$PARENT_TOKEN" ] \
  && ok || bad "10: the PARENT's env was modified by a routed call"
RC=$(run_call env -u ACCOUNT_ROUTING)
grep -q '^claude|NONE|set|' "$T/order" \
  && ok || bad "10: a later unrouted call in the same shell was contaminated: $(cat "$T/order")"
unset CLAUDE_CODE_OAUTH_TOKEN

# =============================================================================
# 11. EXHAUSTION -> COOLDOWN -> EXACTLY ONE RETRY
# =============================================================================
two_claude_accounts; clear_state
printf '%s\n' "$T/.claude-b" > "$T/credits"
: > "$T/logs/failovers.log"
RC=$(run_call env ACCOUNT_ROUTING=1 CREDITS_LIST="$T/credits" CLAUDE_CODE_OAUTH_TOKEN="$PARENT_TOKEN")
[ "$RC" = 0 ] && ok || bad "11: the retry on the next account did not recover the stage (rc=$RC)"
[ "$(cut -d'|' -f2,5 "$T/order" | paste -sd,)" = "$T/.claude-b|claude-fable-5-1,$T/.claude-b|claude-opus-5-5,$T/.claude-a|claude-fable-5-1" ] \
  && ok || bad "11: expected b(fable),b(opus),a(fable); got $(cut -d'|' -f2,5 "$T/order" | paste -sd,)"
[ -f "$T/state/quota/cooldown/claude/b" ] && ok || bad "11: the exhausted account was not cooled down"
[ -f "$T/state/model-cooldown-claude-fable-5-1-b" ] \
  && ok || bad "11: the model cooldown was not keyed to the account that hit it"
[ ! -f "$T/state/model-cooldown-claude-fable-5-1" ] \
  && ok || bad "11: a routed fable exhaustion stamped the SHARED model cooldown"
[ "$(grep -c ',b,' "$T/logs/account-routing.log")" -ge 1 ] \
  && ok || bad "11: the pick of b was not logged"
# Both REGISTRY accounts out of credits: rotation no longer stops after ONE
# retry (2026-09-16) — it keeps going while the vendor still has an account with
# headroom, and the box's own `default` credentials are one of them. Answering
# there is the whole point: a healthy Claude account beats any survival lane.
rm -rf "$T/state/quota/cooldown"; rm -f "$T/state/model-cooldown-"*
printf '%s\n%s\n' "$T/.claude-b" "$T/.claude-a" > "$T/credits"
RC=$(run_call env ACCOUNT_ROUTING=1 CREDITS_LIST="$T/credits" CLAUDE_CODE_OAUTH_TOKEN="$PARENT_TOKEN")
[ "$RC" = 0 ] && ok || bad "11: rotation to the default account did not recover the stage (rc=$RC)"
[ "$(grep -c '^claude|' "$T/order")" = 5 ] \
  && ok || bad "11: expected 5 claude attempts (b fable+opus, a fable+opus, default fable), got $(grep -c '^claude|' "$T/order")"
grep -q '^grok|' "$T/order" \
  && bad "11: the vendor ladder engaged while a Claude account still had headroom" || ok
[ -f "$T/state/quota/cooldown/claude/a" ] && [ -f "$T/state/quota/cooldown/claude/b" ] \
  && ok || bad "11: an exhausted account was not cooled down before the next one was tried"

# Every account out of credits, INCLUDING the default: the vendor is genuinely
# out, and only then does the ladder descend.
rm -rf "$T/state/quota/cooldown"; rm -f "$T/state/model-cooldown-"*
printf '%s\n%s\n%s\n' "$T/.claude-b" "$T/.claude-a" default > "$T/credits"
RC=$(run_call env ACCOUNT_ROUTING=1 CREDITS_LIST="$T/credits" CLAUDE_CODE_OAUTH_TOKEN="$PARENT_TOKEN")
[ "$(grep -c '^claude|' "$T/order")" = 6 ] \
  && ok || bad "11: expected 6 claude attempts (b, a, default — fable+opus each), got $(grep -c '^claude|' "$T/order")"
[ "$(cut -d'|' -f1 "$T/order" | paste -sd, | sed 's/^\(claude,\)*//')" = grok \
  ] && ok || bad "11: the vendor ladder did not engage once every account was exhausted: $(cut -d'|' -f1 "$T/order" | paste -sd,)"
grep -q 'class=account-exhausted' "$T/logs/failovers.log" \
  && ok || bad "11: the exhaustion class was not logged on the failovers.log line"
rm -f "$T/credits" "$T/state/model-cooldown-"*; rm -rf "$T/state/quota/cooldown"
# The DEFAULT exhaustion regex is the vendors' own error text only. A failure
# that merely MENTIONS a rate limit — this repo's own sources and CLAUDE.md do,
# and a failed run echoes back what the agent read — must not cool an account
# down and re-buy the stage on another one.
two_claude_accounts; clear_state; rm -f "$T/state/model-cooldown-"*
printf '%s\n%s\n' "$T/.claude-b" "$T/.claude-a" > "$T/credits"
RC=$(run_call env ACCOUNT_ROUTING=1 CREDITS_LIST="$T/credits" \
     CREDITS_TEXT="see the rate-limit notes in bin/agent-call.sh" \
     CLAUDE_CODE_OAUTH_TOKEN="$PARENT_TOKEN")
[ ! -e "$T/state/quota/cooldown/claude/b" ] \
  && [ "$(find "$T/state/quota/cooldown" -type f 2>/dev/null | grep -c '')" = 0 ] \
  && ok || bad "11: a failure that only MENTIONS a rate limit cooled the account down"
[ "$(grep -c '^claude|' "$T/order")" = 2 ] \
  && ok || bad "11: expected 2 claude attempts and no account retry, got $(grep -c '^claude|' "$T/order")"
# ...and the vendor's own string still fires it.
rm -rf "$T/state/quota/cooldown"; rm -f "$T/state/model-cooldown-"*
RC=$(run_call env ACCOUNT_ROUTING=1 CREDITS_LIST="$T/credits" \
     CREDITS_TEXT="Error: usage limit reached for this account" \
     CLAUDE_CODE_OAUTH_TOKEN="$PARENT_TOKEN")
[ -f "$T/state/quota/cooldown/claude/b" ] \
  && ok || bad "11: the vendor's own 'usage limit' string did not cool the account down"
rm -f "$T/credits" "$T/state/model-cooldown-"*; rm -rf "$T/state/quota/cooldown"

# =============================================================================
# 12. COST-ROW ATTRIBUTION
# =============================================================================
clear_state; rm -f "$T/logs/cost.csv" "$T/state/auth-accounts.local.json"
RC=$(run_call env ACCOUNT_ROUTING=1 CLAUDE_CODE_OAUTH_TOKEN="$PARENT_TOKEN")
ROW=$(tail -1 "$T/logs/cost.csv")
# 24 since BH-656: session_id, row_source, result_usd and the ticket/job/pr/run
# tags (2026-09-14) and `note` (2026-09-18) were appended at the END, so
# auth_account is still field 16 below.
# TEST-CHANGE BH-2537: 25 -> 26 (agent-call writes guard_fp, #2666)
[ "$(printf '%s' "$ROW" | awk -F, '{print NF}')" = 26 ] \
  && ok || bad "12: the routed row is not 26 fields (guard_fp is the 26th, BH-2537): $ROW"
[ "$(printf '%s' "$ROW" | awk -F, '{print $16}')" = "acct:b" ] \
  && ok || bad "12: an unlabelled routed row did not carry acct:b: $ROW"
# A real fingerprint label still wins: routing is a FALLBACK, not an override.
FP="login:$(sha256sum "$T/.claude-b/.credentials.json" 2>/dev/null | cut -c1-12)"
mkdir -p "$T/.claude-b"; echo '{"claudeAiOauth":{"accessToken":"'"$TOKB"'"}}' > "$T/.claude-b/.credentials.json"
FP="login:$(sha256sum "$T/.claude-b/.credentials.json" | cut -c1-12)"
printf '{"%s":"acct-operator-2"}\n' "$FP" > "$T/state/auth-accounts.local.json"
RC=$(run_call env ACCOUNT_ROUTING=1 CLAUDE_CODE_OAUTH_TOKEN="$PARENT_TOKEN")
[ "$(tail -1 "$T/logs/cost.csv" | awk -F, '{print $16}')" = "acct-operator-2" ] \
  && ok || bad "12: a mapped fingerprint label did not beat the account name: $(tail -1 "$T/logs/cost.csv")"
rm -f "$T/state/auth-accounts.local.json"

# =============================================================================
# 13. quota-poll: valid json, honest statuses, no token anywhere
# =============================================================================
clear_reg; clear_state
mkdir -p "$T/.claude-b" "$T/.codex-d"
echo '{"claudeAiOauth":{"accessToken":"'"$TOKB"'"}}' > "$T/.claude-b/.credentials.json"
reg b <<EOF
ACCOUNT_NAME=b
ACCOUNT_VENDOR=claude
CLAUDE_CONFIG_DIR=$T/.claude-b
EOF
reg c <<EOF
ACCOUNT_NAME=c
ACCOUNT_VENDOR=claude
CLAUDE_CODE_OAUTH_TOKEN=$TOKC
EOF
reg d <<EOF
ACCOUNT_NAME=d
ACCOUNT_VENDOR=codex
CODEX_HOME=$T/.codex-d
EOF
reg e <<EOF
ACCOUNT_NAME=e
ACCOUNT_VENDOR=openrouter
OPENROUTER_API_KEY=$KEYE
EOF
cat > "$T/fetch-stub.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FETCH_ARGV_SINK"
echo call >> "$FETCH_CALL_SINK"
[ -n "${OAUTH_USAGE_TOKEN:-}" ] || { echo NO_TOKEN >&2; exit 1; }
if [ "${FETCH_MODE:-ok}" = 403 ]; then
  echo "urllib.error.HTTPError: HTTP Error 403: Forbidden — OAuth token does not meet scope requirement user:profile" >&2
  exit 1
fi
cat <<'J'
{"five_hour":{"utilization":42,"resets_at":"2026-09-07T01:00:00Z"},
 "seven_day":{"utilization":61,"resets_at":"2026-09-10T17:00:00Z"},
 "seven_day_opus":{"utilization":12,"resets_at":"2026-09-10T17:00:00Z"},
 "seven_day_fable":{"utilization":70,"resets_at":"2026-09-10T17:00:00Z"},
 "seven_day_oauth_apps":{"utilization":5}}
J
EOF
chmod +x "$T/fetch-stub.sh"
: > "$T/fetch-argv"; : > "$T/fetch-calls"
printf '{"five_hour":{"utilization":9},"seven_day":{"utilization":11},"seven_day_opus":{"utilization":3}}' \
  > "$T/state/extra-usage-last.json"
poll() { env HARNESS="$T" HOME="$T" ACCOUNTS_DIR="$T/env/accounts.d" \
  OAUTH_USAGE_FETCH="$T/fetch-stub.sh" FETCH_ARGV_SINK="$T/fetch-argv" \
  FETCH_CALL_SINK="$T/fetch-calls" ACCOUNT_POLL_STAGGER_SECS=0 "$@" \
  bash "$T/bin/quota-poll.sh" >/dev/null 2>&1; }
poll
jq -e . "$T/state/quota/b.json" >/dev/null 2>&1 && ok || bad "13: b.json is not valid json"
[ "$(jq -r '.status' "$T/state/quota/b.json")" = ok ] || bad "13: b did not poll ok"
[ "$(jq -r '.five_hour.pct' "$T/state/quota/b.json")" = 42 ] || bad "13: five_hour.pct wrong"
[ "$(jq -r '.seven_day.pct' "$T/state/quota/b.json")" = 61 ] || bad "13: seven_day.pct wrong"
[ "$(jq -r '.per_model.opus.pct' "$T/state/quota/b.json")" = 12 ] || bad "13: per_model.opus wrong"
[ "$(jq -r '.per_model.fable.pct' "$T/state/quota/b.json")" = 70 ] || bad "13: per_model.fable wrong"
[ "$(jq -r '.per_model.oauth_apps // "absent"' "$T/state/quota/b.json")" = absent ] \
  || bad "13: seven_day_oauth_apps leaked into per_model as if it were a model"
ok
[ "$(jq -r '.status' "$T/state/quota/c.json")" = unreadable ] \
  && ok || bad "13: a setup-token account is not 'unreadable'"
[ "$(jq -r '.status' "$T/state/quota/d.json")" = unknown ] \
  && ok || bad "13: a codex account is not 'unknown'"
[ "$(jq -r '.status' "$T/state/quota/e.json")" = unmetered ] \
  && ok || bad "13: an API-key account is not 'unmetered'"
[ "$(jq -r '.source' "$T/state/quota/default.json")" = extra-usage-track ] \
  && ok || bad "13: default.json was not derived from the tracker's snapshot"
[ "$(jq -r '.five_hour.pct' "$T/state/quota/default.json")" = 9 ] \
  && ok || bad "13: default.json carries the wrong numbers"
[ "$(stat -c %a "$T/state/quota/b.json")" = 600 ] && ok || bad "13: b.json is not 0600"
[ ! -s "$T/fetch-argv" ] || [ "$(tr -d '[:space:]' < "$T/fetch-argv")" = "" ] \
  && ok || bad "13: the token (or anything) reached the fetcher's ARGV: $(cat "$T/fetch-argv")"
LEAK=$(grep -rl -e FIXTURE "$T/state" "$T/logs" 2>/dev/null | grep -v 'accounts.d' || true)
[ -z "$LEAK" ] && ok || bad "13: a fixture secret leaked into state/ or logs/: $LEAK"
# The double-run guard: a manual run beside the cron tick must not re-poll.
poll
[ "$(grep -c call "$T/fetch-calls")" = 1 ] \
  && ok || bad "13: the rate guard did not stop a second poll ($(grep -c call "$T/fetch-calls") calls)"
# A 403 is recorded as a named error, still valid json, still no token.
poll ACCOUNT_POLL_MIN_SECS=0 FETCH_MODE=403
[ "$(jq -r '.status' "$T/state/quota/b.json")" = error ] && ok || bad "13: a 403 was not recorded as status=error"
jq -r '.error' "$T/state/quota/b.json" | grep -q 'user:profile' \
  && ok || bad "13: the 403 reason was not named: $(jq -r '.error' "$T/state/quota/b.json")"
LEAK=$(grep -rl -e FIXTURE "$T/state" "$T/logs" 2>/dev/null | grep -v 'accounts.d' || true)
[ -z "$LEAK" ] && ok || bad "13: a fixture secret leaked on the error path: $LEAK"
# The log is the thing an operator tails, so the classified reason has to reach
# it and not only the json: docs promise `ts account status [reason]`.
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z b error token lacks user:profile scope$' \
  "$T/logs/quota-poll.log" \
  && ok || bad "13: the classified reason never reached quota-poll.log: $(grep ' b error' "$T/logs/quota-poll.log" | tail -1)"
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z b ok$' "$T/logs/quota-poll.log" \
  && ok || bad "13: an ok poll line gained a trailing empty reason slot: $(grep ' b ok' "$T/logs/quota-poll.log" | tail -1)"

# =============================================================================
# 14. quota-status renders, at phone width, with no secret in it
# =============================================================================
mkdir -p "$T/state/quota/cooldown/claude"; date -u +%s > "$T/state/quota/cooldown/claude/c"
STATUS=$(env HARNESS="$T" HOME="$T" ACCOUNTS_DIR="$T/env/accounts.d" bash "$T/bin/quota-status.sh" 2>&1)
for A in default b c d e; do
  grep -qE "^$A " <<<"$STATUS" || bad "14: account $A is missing from the table"
done
ok
WIDE=$(awk 'length($0) > 40 {print length($0)": "$0}' <<<"$STATUS")
[ -z "$WIDE" ] && ok || bad "14: the table is wider than 40 columns:
$WIDE"
grep -q 'cooldown: c' <<<"$STATUS" && ok || bad "14: a cooling account has no cooldown line"
grep -qE 'sk-ant|FIXTURE|or-FIX' <<<"$STATUS" && bad "14: quota-status printed a secret" || ok
env HARNESS="$T" HOME="$T" ACCOUNTS_DIR="$T/env/accounts.d" bash "$T/bin/quota-status.sh" --json \
  | jq -e 'length >= 5' >/dev/null 2>&1 && ok || bad "14: --json did not emit the merged array"
rm -f "$T/state/quota/cooldown/claude/c"

# =============================================================================
# 15. REGISTRY VALIDATION — a bad file is skipped, never fatal
# =============================================================================
clear_reg; clear_state
reg good <<EOF
ACCOUNT_NAME=good
ACCOUNT_VENDOR=claude
ACCOUNT_PRIORITY=5
CLAUDE_CONFIG_DIR=$T/.claude-b
EOF
reg evil <<'EOF'
ACCOUNT_NAME=../x
ACCOUNT_VENDOR=claude
CLAUDE_CONFIG_DIR=/tmp/x
EOF
reg default <<'EOF'
ACCOUNT_NAME=default
ACCOUNT_VENDOR=claude
CLAUDE_CODE_OAUTH_TOKEN=nope
EOF
reg novendor <<'EOF'
ACCOUNT_NAME=novendor
CLAUDE_CONFIG_DIR=/tmp/x
EOF
reg mismatch <<'EOF'
ACCOUNT_NAME=somethingelse
ACCOUNT_VENDOR=claude
CLAUDE_CONFIG_DIR=/tmp/x
EOF
reg nocred <<'EOF'
ACCOUNT_NAME=nocred
ACCOUNT_VENDOR=claude
EOF
reg unbound <<'EOF'
ACCOUNT_NAME=unbound
ACCOUNT_VENDOR=claude
BOGUS=$THIS_IS_NOT_SET
CLAUDE_CONFIG_DIR=/tmp/unbound
EOF
: > "$T/logs/account-routing.log"
[ "$(pname -- eval claude claude-fable-5-1)" = good ] \
  && ok || bad "15: a registry with six bad files did not still pick the good one (rc=$PRC)"
for R in 'registry_skip:evil:bad_name' 'registry_skip:default:reserved_name' \
         'registry_skip:novendor:bad_vendor' 'registry_skip:mismatch:name_stem_mismatch' \
         'registry_skip:nocred:no_credential'; do
  grep -q "$R" "$T/logs/account-routing.log" || bad "15: missing skip line '$R'"
done
ok
[ ! -e "$T/state/quota/../x.json" ] && ok || bad "15: a traversing account name escaped state/quota"
# The file with an unbound reference must still register: `set +u` around the
# source is what keeps one bad config line from killing the whole registry.
grep -q 'registry_skip:unbound' "$T/logs/account-routing.log" \
  && bad "15: a file with an unbound variable reference was skipped" || ok
clear_reg

# =============================================================================
# 16. THE CRON LINE IS INSTALLED EVERYWHERE, OR ITS ABSENCE IS DECLARED
# =============================================================================
for F in "$(rendered_cron_dir)"/*.cron; do
  N=$(grep -c 'quota-poll\.sh' "$F" 2>/dev/null || true)
  case "${N:-0}" in
    1) grep -qE '^(23 \* \* \* \*|\*/10 \* \* \* \*) /root/harness/bin/quota-poll\.sh >/dev/null 2>&1 #' "$F" \
         || bad "16: $(basename "$F") has a quota-poll line of the wrong shape: $(grep 'quota-poll' "$F")" ;;
    0) grep -qi 'NO quota-poll line, deliberately' "$F" \
         || bad "16: $(basename "$F") has no quota-poll line and no stated reason" ;;
    *) bad "16: $(basename "$F") has $N quota-poll lines, expected exactly 1" ;;
  esac
done
ok

# =============================================================================
# 17. THE EXHAUSTION SCAN READS THE CLI'S OWN ERROR STREAM ON CODEX
# =============================================================================
# A failed codex run's $OUT is the events stream PLUS stderr, so it echoes back
# every file the agent read. Scanning that for quota text would stamp a 6h
# account cooldown and re-buy the stage on another account for a failure that
# had nothing to do with quota. The scan reads $OUT.err, where the CLI's own
# 429/usage text lands.
clear_reg; clear_state
mkdir -p "$T/.codex-d" "$T/.codex"; echo '{}' > "$T/.codex/auth.json"
reg d <<EOF
ACCOUNT_NAME=d
ACCOUNT_VENDOR=codex
CODEX_HOME=$T/.codex-d
EOF
cat > "$T/bin/codex-usage.sh" <<'EOF'
#!/bin/bash
echo "1 2 3 4"
EOF
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
echo "codex|${CODEX_HOME:-NONE}|-|-|-" >> "$ORDER_SINK"
echo "model: gpt-6-astra" >&2
[ -n "${CODEX_STDOUT:-}" ] && echo "$CODEX_STDOUT"
[ -n "${CODEX_STDERR:-}" ] && echo "$CODEX_STDERR" >&2
exit "${CODEX_RC:-0}"
EOF
chmod +x "$T/fakebin/codex" "$T/bin/codex-usage.sh"
RC=$(run_call env RUNNER_EVAL=codex ACCOUNT_ROUTING=1 CODEX_RC=1 \
     CODEX_STDOUT="reading bin/agent-call.sh: the usage limit note" \
     CLAUDE_CODE_OAUTH_TOKEN="$PARENT_TOKEN")
[ ! -e "$T/state/quota/cooldown/codex/d" ] \
  && [ "$(find "$T/state/quota/cooldown" -type f 2>/dev/null | grep -c '')" = 0 ] \
  && ok || bad "17: quota text in the codex EVENTS stream cooled the account down"
[ "$(grep -c '^codex|' "$T/order")" = 1 ] \
  && ok || bad "17: an unrelated codex failure bought a second attempt ($(grep -c '^codex|' "$T/order") codex calls)"
RC=$(run_call env RUNNER_EVAL=codex ACCOUNT_ROUTING=1 CODEX_RC=1 \
     CODEX_STDERR="stream error: usage limit reached" \
     CLAUDE_CODE_OAUTH_TOKEN="$PARENT_TOKEN")
[ -f "$T/state/quota/cooldown/codex/d" ] \
  && ok || bad "17: the CLI's own usage-limit error on STDERR did not cool the account down"
rm -f "$T/fakebin/codex"; rm -rf "$T/state/quota/cooldown"

# =============================================================================
# 18. CROSS-PICKER STATUS CONSISTENCY — both pickers agree on `ok` and `unreadable`
# =============================================================================
quota unreadable unreadable 60 40 2
clear_reg
reg unreadable <<EOF
ACCOUNT_NAME=unreadable
ACCOUNT_VENDOR=claude
ACCOUNT_PRIORITY=10
CLAUDE_CONFIG_DIR=$T/.claude-unreadable
EOF
POOL_LIB="$T/bin/lib/pool-account.sh"
grep -q 'rc=0' <<<"$(env HARNESS="$T" bash -c '. "$1"; account_headroom unreadable claude-fable-5-1 >/dev/null; echo "rc=$?"' x "$POOL_LIB")" && ok || bad "18: account_headroom unreadable did not return 0"
grep -q 'rc=0' <<<"$(env HARNESS="$T" bash -c '. "$1"; _pa_metered unreadable claude-fable-5-1 >/dev/null; echo "rc=$?"' x "$POOL_LIB")" && ok || bad "18: _pa_metered unreadable did not return 0"
quota unknown unknown 60 40 2
grep -q 'rc=0' <<<"$(env HARNESS="$T" bash -c '. "$1"; account_headroom unknown claude-fable-5-1 >/dev/null; echo "rc=$?"' x "$POOL_LIB")" && ok || bad "18: account_headroom unknown did not return 0"
grep -q 'rc=1' <<<"$(env HARNESS="$T" bash -c '. "$1"; _pa_metered unknown claude-fable-5-1 >/dev/null; echo "rc=$?"' x "$POOL_LIB")" && ok || bad "18: _pa_metered unknown did not return 1"
rm -f "$T/state/quota/unknown.json" "$T/state/quota/unreadable.json"

echo "account-routing-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
