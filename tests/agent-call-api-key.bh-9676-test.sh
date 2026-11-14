#!/bin/bash
# tests/agent-call-api-key.bh-9676-test.sh — BH-9676 (C0): a project whose
# settings row claude_auth.<project> is `api-key` runs its claude rung on the
# box's ANTHROPIC_API_KEY, never on an OAuth token or a pinned/picked account,
# and its cost row says metered + apikey:<project>.
#
#   K1   row api-key, key set: claude runs on the key, routing row api_key,
#        $OUT.account = apikey:p-key. K1b: an account.p-key pin + accounts.d
#        token exist; neither is used and account-pick never runs.
#   K2   plus a box CLAUDE_CODE_OAUTH_TOKEN: the child sees the key, no token.
#   K3   no key on the box: claude never runs, rc-76 refusal, no OAuth fallback.
#   K4-K6 cost.csv: col 14 metered, col 15 the key's fp, col 16 apikey:p-key.
#   K6b  col 16 stays apikey:p-key when the key's fp has a label of its own.
#   K7/K8 managed settings with forceLoginMethod / forceLoginOrgUUID: refused
#        before the CLI.
#   K9/K9b no row / row oauth: the OAuth token runs, as on main.
#   K10  row API-KEY: refused, the OAuth token never reaches claude.
#   K11  a row for another project changes nothing.
#   K12  codex rung of an api-key project: runs as before.
#   K13  the key value is in no log, no state file, no $OUT file.
#   G1-G6 claude_auth_managed_guard; G7 the image/bootstrap write no forceLogin*.
#
# DRIVEN, NOT GREPPED: bin/agent-call.sh runs for real against a scratch
# HARNESS with fake CLIs (0 network calls); the real bin/billing-mode.sh and
# bin/lib/claude-auth.sh answer.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" p-key p-oauth p-key2
mkdir -p "$T/bin" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/env/accounts.d" "$T/ms"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Fixtures built at run time, so no key-shaped literal sits in this file.
KEY="sk-ant-api""03-$(printf 'bh9676keyfixture%.0s' 1 2 3 | cut -c1-40)"
TOK="sk-ant-oat""01-bh9676-box-oauth-fixture"
OWN="sk-ant-oat""01-bh9676-own-pin-fixture"
fp8()  { printf '%s' "$1" | sha256sum | cut -c1-8; }
fp12() { printf '%s' "$1" | sha256sum | cut -c1-12; }
TOK_FP=$(fp8 "$TOK"); OWN_FP=$(fp8 "$OWN")

# ---------- fakes -----------------------------------------------------------
# claude records WHICH credential reached it (an fp, never the value).
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in *" --help "*) printf -- '  --session-id <uuid>\n'; exit 0 ;; esac
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then o=$(printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" | sha256sum | cut -c1-8); else o=none; fi
printf 'claude oauth=%s apikey=%s\n' "$o" "${ANTHROPIC_API_KEY:+set}" >> "$ORDER_SINK"
printf '{"result":"ok","usage":{"input_tokens":5,"output_tokens":1},"total_cost_usd":0.01}\n'; exit 0
EOF
cat > "$T/fakebin/grok" <<'EOF'
#!/bin/bash
echo "grok" >> "$ORDER_SINK"; echo "grok answered"; exit 0
EOF
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
echo "codex" >> "$ORDER_SINK"; echo "codex answered"; exit 0
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
cat > "$T/bin/account-pick.sh" <<'EOF'
#!/bin/bash
[ "${1:-}" = --overage-ok ] && exit 1
touch "$PICK_SENTINEL"
echo "name=default"; echo "reason=stub"; exit 0
EOF
# The REAL billing-mode (and through it the real claude-auth lib and lane-gate).
printf '#!/bin/bash\nexec bash "%s/bin/billing-mode.sh" "$@"\n' "$DIR" > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
printf '#!/bin/bash\necho "1 2 3 4"\n' > "$T/bin/codex-usage.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh
echo '{}' > "$T/catalog.json"

cache() { jq -n --argjson fa "$(date -u +%s)" --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' > "$T/state/settings-cache.json"; }
reset() { : > "$T/order"; : > "$T/logs/failovers.log"; rm -f "$T/pick" "$T/out.txt"*; rm -rf "$T/state/quota"; rm -f "$T/state/model-cooldown-"*; }

# run_call <project> [ENV=...] — drives bin/agent-call.sh for real.
run_call() {
  local p="$1"; shift
  reset
  ( export ORDER_SINK="$T/order" PICK_SENTINEL="$T/pick" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           ACCOUNTS_DIR="$T/env/accounts.d" LADDER_BACKOFF_SECS=0 LADDER_TIER2_GROK=1 \
           RUNNER_EVAL="${RUNNER_EVAL:-claude}" CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           AUTH_ACCOUNTS_CATALOG="$T/catalog.json" JOBS_URL= \
           CLAUDE_MANAGED_SETTINGS_FILE="${MS_FILE:-$T/ms/none.json}" CLAUDE_MANAGED_SETTINGS_DIR="$T/ms/none.d"
    env -u ACCOUNT_ROUTING -u RUNNER_EVAL_FALLBACK -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY \
      -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u ACCOUNT_OWN_PROJECTS \
      "$@" bash "$DIR/bin/agent-call.sh" eval "$p" claude-opus-5 600 "$T/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}
count() { grep -c "^$1" "$T/order" 2>/dev/null || true; }
costcol() { tail -1 "$T/logs/cost.csv" 2>/dev/null | awk -F, -v c="$1" '{print $c}'; }
costrows() { grep -c . "$T/logs/cost.csv" 2>/dev/null || echo 0; }
lastroute() { tail -1 "$T/logs/account-routing.log" 2>/dev/null; }

# ── K1 api-key row, key set ────────────────────────────────────────────────
cache '{"claude_auth.p-key":"api-key"}'
RC=$(run_call p-key ACCOUNT_ROUTING=1 ANTHROPIC_API_KEY="$KEY")
[ "$RC" = 0 ] && ok || bad "K1 rc=$RC"
[ "$(cat "$T/order")" = "claude oauth=none apikey=set" ] && ok || bad "K1 claude did not run once on the key: $(cat "$T/order")"
lastroute | grep -q ',p-key,eval,claude-opus-5,apikey:p-key,api_key$' && ok || bad "K1 routing row: $(lastroute)"
[ "$(cat "$T/out.txt.account" 2>/dev/null)" = apikey:p-key ] && ok || bad "K1 \$OUT.account=$(cat "$T/out.txt.account" 2>/dev/null)"
[ -e "$T/pick" ] && bad "K1 account-pick ran for an api-key project" || ok
# K4-K6 the cost row of that attempt
[ "$(costcol 14)" = metered ] && ok || bad "K4 billing_mode: $(tail -1 "$T/logs/cost.csv")"
[ "$(costcol 15)" = "$(fp12 "$KEY")" ] && ok || bad "K5 auth_fp: $(costcol 15) want $(fp12 "$KEY")"
[ "$(costcol 16)" = apikey:p-key ] && ok || bad "K6 auth_account: $(costcol 16)"

# K6b the key's fp carries a label in the overlay: apikey:<project> still wins
printf '{"%s":"claude:fixture-label"}\n' "$(fp12 "$KEY")" > "$T/state/auth-accounts.local.json"
RC=$(run_call p-key ANTHROPIC_API_KEY="$KEY")
[ "$(costcol 16)" = apikey:p-key ] && ok || bad "K6b a fingerprint label replaced apikey:p-key: $(costcol 16)"
rm -f "$T/state/auth-accounts.local.json"

# ── K1b an account pin and an accounts.d token exist: neither is used ──────
cache '{"claude_auth.p-key":"api-key","account.p-key":"own:x"}'
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$OWN" > "$T/env/accounts.d/own:x.env"; chmod 600 "$T/env/accounts.d/own:x.env"
RC=$(run_call p-key ACCOUNT_ROUTING=1 ANTHROPIC_API_KEY="$KEY")
[ "$RC" = 0 ] && ok || bad "K1b rc=$RC"
[ "$(cat "$T/order")" = "claude oauth=none apikey=set" ] && ok || bad "K1b claude ran on: $(cat "$T/order")"
grep -q "oauth=$OWN_FP" "$T/order" && bad "K1b the pinned own:x token reached claude" || ok
[ -e "$T/pick" ] && bad "K1b account-pick ran" || ok
lastroute | grep -q ',apikey:p-key,api_key$' && ok || bad "K1b routing row: $(lastroute)"
[ "$(costcol 16)" = apikey:p-key ] && ok || bad "K1b auth_account: $(costcol 16)"
rm -f "$T/env/accounts.d/own:x.env"

# ── K2 a box OAuth token is unset in the child; the key stays ──────────────
cache '{"claude_auth.p-key":"api-key"}'
RC=$(run_call p-key ACCOUNT_ROUTING=1 ANTHROPIC_API_KEY="$KEY" CLAUDE_CODE_OAUTH_TOKEN="$TOK")
[ "$RC" = 0 ] && ok || bad "K2 rc=$RC"
[ "$(cat "$T/order")" = "claude oauth=none apikey=set" ] && ok || bad "K2 child env: $(cat "$T/order")"
[ "$(costcol 14)" = metered ] && ok || bad "K2 billing_mode with a box token: $(costcol 14)"
[ "$(costcol 15)" = "$(fp12 "$KEY")" ] && ok || bad "K2 auth_fp must be the key's: $(costcol 15)"

# ── K3 no key on the box: refuse, never the OAuth token ────────────────────
n0=$(costrows)
RC=$(run_call p-key ACCOUNT_ROUTING=1 CLAUDE_CODE_OAUTH_TOKEN="$TOK")
[ "$(count claude)" = 0 ] && ok || bad "K3 claude ran with no key: $(cat "$T/order")"
grep -q 'claude_auth.p-key=api-key and this box has no ANTHROPIC_API_KEY, not falling back to OAuth' "$T/logs/failovers.log" \
  && ok || bad "K3 failovers.log: $(cat "$T/logs/failovers.log")"
grep -q ',apikey:p-key,api_key_unavailable' "$T/logs/account-routing.log" && ok || bad "K3 routing row: $(lastroute)"
[ "$(count grok)" = 1 ] && ok || bad "K3 the rung did not descend: $(cat "$T/order")"
[ -e "$T/pick" ] && bad "K3 account-pick ran" || ok
[ -z "$(ls -A "$T/state/quota/cooldown/claude" 2>/dev/null)" ] && [ -z "$(ls "$T/state/model-cooldown-"* 2>/dev/null)" ] \
  && ok || bad "K3 a cooldown was stamped"
grep -q ',claude,' <<<"$(tail -n +"$((n0+1))" "$T/logs/cost.csv" 2>/dev/null)" && bad "K3 a claude cost row was written for a refusal" || ok

# ── K7/K8 managed settings block the key ───────────────────────────────────
for kv in 'forceLoginMethod:"claudeai"' 'forceLoginOrgUUID:"00000000-0000-0000-0000-000000000000"'; do
  k=${kv%%:*}; v=${kv#*:}
  printf '{"%s":%s}\n' "$k" "$v" > "$T/ms/managed.json"
  RC=$(MS_FILE="$T/ms/managed.json" run_call p-key ANTHROPIC_API_KEY="$KEY")
  [ "$(count claude)" = 0 ] && ok || bad "K7/$k claude ran: $(cat "$T/order")"
  grep -q "$T/ms/managed.json sets $k" "$T/logs/failovers.log" && ok || bad "K7/$k failovers.log: $(cat "$T/logs/failovers.log")"
  grep -qF "${v//\"/}" "$T/logs/failovers.log" && bad "K7/$k the value was printed" || ok
  [ "$(count grok)" = 1 ] && ok || bad "K7/$k did not refuse and descend: $(cat "$T/order")"
done
rm -f "$T/ms/managed.json"

# ── K9/K9b no row, or row oauth: main behavior ─────────────────────────────
for v in none oauth; do
  if [ "$v" = none ]; then cache '{}'; else cache '{"claude_auth.p-oauth":"oauth"}'; fi
  RC=$(run_call p-oauth CLAUDE_CODE_OAUTH_TOKEN="$TOK" ANTHROPIC_API_KEY="$KEY")
  [ "$RC" = 0 ] && ok || bad "K9/$v rc=$RC"
  [ "$(cat "$T/order")" = "claude oauth=$TOK_FP apikey=set" ] && ok || bad "K9/$v claude env: $(cat "$T/order")"
  [ "$(costcol 14)" = subscription ] && ok || bad "K9/$v billing_mode: $(costcol 14)"
  [ "$(costcol 15)" = "$(fp12 "$TOK")" ] && ok || bad "K9/$v auth_fp: $(costcol 15)"
  [ "$(costcol 16)" = apikey:p-oauth ] && bad "K9/$v labelled apikey" || ok
  grep -q ',p-oauth,.*,api_key' "$T/logs/account-routing.log" 2>/dev/null \
    && bad "K9/$v an api_key routing row for an oauth project" || ok
done

# ── K10 a near-miss row value is refused, never OAuth ──────────────────────
for v in API-KEY api_key; do
  cache "$(jq -n --arg v "$v" '{"claude_auth.p-key":$v}')"
  RC=$(run_call p-key CLAUDE_CODE_OAUTH_TOKEN="$TOK" ANTHROPIC_API_KEY="$KEY")
  [ "$(count claude)" = 0 ] && ok || bad "K10/$v claude ran: $(cat "$T/order")"
  lastroute | grep -q ',p-key,eval,claude-opus-5,-,claude_auth_invalid$' && ok || bad "K10/$v routing row: $(lastroute)"
  grep -q 'settings row claude_auth.p-key is not oauth or api-key, refusing the claude rung' "$T/logs/failovers.log" \
    && ok || bad "K10/$v failovers.log: $(cat "$T/logs/failovers.log")"
  [ "$(count grok)" = 1 ] && ok || bad "K10/$v did not descend: $(cat "$T/order")"
done

# ── K11 a row for another project changes nothing ──────────────────────────
cache '{"claude_auth.p-key2":"api-key"}'
RC=$(run_call p-key CLAUDE_CODE_OAUTH_TOKEN="$TOK")
[ "$(cat "$T/order")" = "claude oauth=$TOK_FP apikey=" ] && ok || bad "K11 p-key did not run on OAuth: $(cat "$T/order")"
[ "$(costcol 16)" = apikey:p-key ] && bad "K11 labelled apikey:p-key" || ok

# ── K12 the codex rung of an api-key project runs as before ────────────────
cache '{"claude_auth.p-key":"api-key"}'
mkdir -p "$T/.codex"; echo '{}' > "$T/.codex/auth.json"
r0=$(grep -c . "$T/logs/account-routing.log" 2>/dev/null || echo 0)
RC=$(RUNNER_EVAL=codex run_call p-key ANTHROPIC_API_KEY="$KEY")
[ "$(count codex)" = 1 ] && [ "$(count claude)" = 0 ] && ok || bad "K12 codex rung: $(cat "$T/order")"
new_rows=$(tail -n +"$((r0+1))" "$T/logs/account-routing.log" 2>/dev/null)
grep -q 'apikey:\|claude_auth_invalid' <<<"$new_rows" && bad "K12 codex rung touched the auth branch: $new_rows" || ok
[ "$(costcol 16)" = apikey:p-key ] && bad "K12 the codex row was labelled apikey:p-key" || ok
rm -rf "$T/.codex"

# ── K13 the key value is nowhere on disk but the env fixture ───────────────
hits=$(grep -rlF "$KEY" "$T/logs" "$T/state" "$T"/out.txt* 2>/dev/null)
[ -z "$hits" ] && ok || bad "K13 the key leaked into: $hits"

# ── G1-G6 claude_auth_managed_guard ─────────────────────────────────────────
LIB="$DIR/bin/lib/claude-auth.sh"
guard() { # guard <file-or-empty> <dir> -> GRC, GERR
  GERR=$(env HARNESS="$T" JOBS_URL= CLAUDE_MANAGED_SETTINGS_FILE="${1:-$T/ms/absent.json}" CLAUDE_MANAGED_SETTINGS_DIR="$2" \
    bash -c '. "$0" || exit 99; claude_auth_managed_guard' "$LIB" 2>&1 >/dev/null); GRC=$?
}
mkdir -p "$T/g/empty.d" "$T/g/drop.d"
printf '{"forceLoginMethod":"claudeai"}\n' > "$T/g/g1.json"
guard "$T/g/g1.json" "$T/g/empty.d"
[ "$GRC" = 1 ] && grep -q "g1.json sets forceLoginMethod" <<<"$GERR" && ! grep -q claudeai <<<"$GERR" && ok || bad "G1 rc=$GRC err=$GERR"
printf '{"forceLoginOrgUUID":"org-fixture"}\n' > "$T/g/g2.json"
guard "$T/g/g2.json" "$T/g/empty.d"
[ "$GRC" = 1 ] && grep -q "sets forceLoginOrgUUID" <<<"$GERR" && ! grep -q org-fixture <<<"$GERR" && ok || bad "G2 rc=$GRC err=$GERR"
printf '{"forceLoginMethod":"console"}\n' > "$T/g/drop.d/10-x.json"
guard "" "$T/g/drop.d"
[ "$GRC" = 1 ] && grep -q "10-x.json sets forceLoginMethod" <<<"$GERR" && ok || bad "G3 drop-in rc=$GRC err=$GERR"
printf '{"forceLoginMethod": "claudeai",,,\n' > "$T/g/g4.json"
guard "$T/g/g4.json" "$T/g/empty.d"
[ "$GRC" = 1 ] && grep -q "g4.json sets forceLoginMethod" <<<"$GERR" && ok || bad "G4 broken JSON rc=$GRC err=$GERR"
guard "" "$T/g/absent.d"
[ "$GRC" = 0 ] && [ -z "$GERR" ] && ok || bad "G5 no file rc=$GRC err=$GERR"
printf '{"permissions":{},"note":"forceLoginMethod is off","env":{"forceLoginMethod":"x"}}\n' > "$T/g/g6.json"
guard "$T/g/g6.json" "$T/g/empty.d"
[ "$GRC" = 0 ] && [ -z "$GERR" ] && ok || bad "G6 near miss refused rc=$GRC err=$GERR"
# G7 nothing the fleet image or bootstrap ships writes forceLogin*
g7=$(cd "$DIR" && git grep -n forceLogin -- fly bin/bootstrap-machine.sh 2>/dev/null)
[ -z "$g7" ] && ok || bad "G7 forceLogin in the image/bootstrap: $g7"

echo "agent-call-api-key.bh-9676: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
