#!/bin/bash
# tests/oauth-refresh-daily-claim.bh-3222-test.sh — BH-3222: bin/oauth-refresh.sh
# spends its CLI fallback at most once per credential per UTC day, never lets
# agent-call page DEAD for it, and pages (once, warn) only for a login an
# enabled claude account routes to.
#
# Runs the REAL oauth-refresh.sh copied into $T/bin beside the REAL
# auth-fingerprint.sh, account-pick.sh and lib/env-path.sh, with stub
# lib/lane-model.sh (route m-auth), a stub lib/cred-probe.sh backed by files in
# $T/ledger (same key and rc contract as the real one), a stub agent-call.sh
# that logs argv/env and leaves the file alone (a dead login) unless BUMP=1,
# and a stub lane-alert.sh that logs argv.
#
#  C1 first run on a dead login: agent-call once, ledger
#     oauth-refresh:login:<fp>:<today> = down, rc 1.
#  C2 runs 2 and 3 the same day: still one agent-call; rc 1; agent-rules.log
#     says "already attempted today for login:<fp>" and names the file.
#  C3 a healthy CLI-only login (agent-call bumps the expiry): run 1 records ok;
#     the re-expired file is new content, so run 2 calls again (2 calls).
#  C4 unrouted dir: no lane-alert call, nothing in ALERTS.log.
#  C5 the agent-call env carries AGENT_CALL_DEAD_ALERT=0.
#  C6 routed dir (claude account, CLAUDE_CONFIG_DIR=<dir>/): exactly one
#     `lane-alert.sh --id oauth-refresh-… --severity warn` over 3 runs.
#  C6n not routed: a prefix-only match, an ACCOUNT_ENABLED=0 account, a codex
#     account whose CODEX_HOME is the dir — 0 lane-alert calls each.
#  C7 the routed dir comes back fresh: `--resolve --id <same id>`, no agent-call.
#  C8 store unreachable (claim rc 2): no agent-call, rc 1, a log line says so.
#
# Mutation (run by hand once): drop the cred_inference_claim gate → C2 red;
# drop AGENT_CALL_DEAD_ALERT=0 → C5 red; make _routed always answer 1 → C4/C6n
# red.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/oauth-refresh-daily-claim.bh-3222-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin/lib" "$T/logs" "$T/argv" "$T/ledger" "$T/accounts.d" "$T/env"
cp "$DIR/bin/oauth-refresh.sh" "$DIR/bin/auth-fingerprint.sh" "$DIR/bin/account-pick.sh" "$T/bin/"
cp "$DIR/bin/lib/env-path.sh" "$T/bin/lib/"
chmod +x "$T/bin/"*.sh

cat > "$T/bin/lib/lane-model.sh" <<'S'
lane_role_model() { [ "$1" = auth.fallback ] && echo m-auth; }
S
# The contract's rc semantics over a file store: any row for the key = 1.
cat > "$T/bin/lib/cred-probe.sh" <<'S'
cred_inference_claim() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 2
  [ -n "${STUB_CLAIM_RC:-}" ] && return "$STUB_CLAIM_RC"
  local k="$1:$2:$(date -u +%F)"
  [ -e "$LEDGER/$k" ] && return 1
  echo claimed > "$LEDGER/$k"; _CP_CLAIM="$k"; return 0
}
cred_inference_record() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  echo "$3" > "$LEDGER/${_CP_CLAIM:-$1:$2:$(date -u +%F)}"
}
S
cat > "$T/bin/agent-call.sh" <<'S'
#!/bin/bash
printf '%s\n' "$*" >> "$ARGV/agent-call.log"
echo "DEAD_ALERT=${AGENT_CALL_DEAD_ALERT-unset} CDIR=${CLAUDE_CONFIG_DIR:-}" >> "$ARGV/agent-call.env"
f="$CLAUDE_CONFIG_DIR/.credentials.json"
if [ "${BUMP:-}" = 1 ]; then
  n=$(( ($(date -u +%s) + 28800) * 1000 ))
  jq --argjson n "$n" '.claudeAiOauth.expiresAt=$n | .claudeAiOauth.accessToken="AT-CLI"' "$f" > "$f.t" && mv "$f.t" "$f"
  echo ok > "$5"; exit 0
fi
echo "Invalid API key · Please run /login" > "$5"
exit 1
S
cat > "$T/bin/lane-alert.sh" <<'S'
#!/bin/bash
printf '%s\n' "$*" >> "$ARGV/lane-alert.log"
S
chmod +x "$T/bin/agent-call.sh" "$T/bin/lane-alert.sh"

# mkcreds <dir> <expiry-offset-s> [tag] — a login file; tag varies the content.
mkcreds() {
  mkdir -p "$1"
  local e=$(( ($(date -u +%s) + $2) * 1000 ))
  jq -n --argjson e "$e" --arg t "${3:-a}" '{claudeAiOauth:{accessToken:("AT-"+$t),refreshToken:"RT-x",expiresAt:$e}}' > "$1/.credentials.json"
  chmod 600 "$1/.credentials.json"
}
fp_of() { printf 'login:%s' "$(sha256sum "$1/.credentials.json" | cut -c1-12)"; }
reset() { rm -rf "$T/argv/"* "$T/ledger/"* "$T/accounts.d/"* "$T/logs/"* "$T/state"; }
run() {  # run <dir> [VAR=val ...] -> RC
  local d="$1"; shift
  env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u OAUTH_REFRESH_CLIENT_ID -u CLAUDE_CONFIG_DIR \
    -u CRED_PROBE_LIB -u HARNESS_ENV_DIR \
    CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-setup HARNESS="$T" ARGV="$T/argv" LEDGER="$T/ledger" \
    ACCOUNTS_DIR="$T/accounts.d" "$@" "$T/bin/oauth-refresh.sh" "$d" max2 >/dev/null 2>&1
  RC=$?
}
lines() { [ -f "$1" ] && grep -c . "$1" || echo 0; }
acct() {  # acct <name> <vendor> <VAR=val>... — one registry file
  local n="$1" v="$2"; shift 2
  { echo "ACCOUNT_NAME=$n"; echo "ACCOUNT_VENDOR=$v"; printf '%s\n' "$@"; } > "$T/accounts.d/$n.env"
}
TODAY=$(date -u +%F)
D="$T/home/.claude-max2"

# C1 — first run on a dead login
reset; mkcreds "$D" -3600
FP=$(fp_of "$D")
run "$D"
[ "$RC" = 1 ] && ok || bad "C1 rc=$RC want 1"
[ "$(lines "$T/argv/agent-call.log")" = 1 ] && ok || bad "C1 agent-call ran $(lines "$T/argv/agent-call.log") times, want 1"
[ "$(cat "$T/ledger/oauth-refresh:$FP:$TODAY" 2>/dev/null)" = down ] && ok \
  || bad "C1 ledger oauth-refresh:$FP:$TODAY = '$(cat "$T/ledger/oauth-refresh:$FP:$TODAY" 2>/dev/null)' want down (have: $(ls "$T/ledger"))"
# C5 — agent-call is told not to page DEAD for this call
[ "$(head -1 "$T/argv/agent-call.env" 2>/dev/null)" = "DEAD_ALERT=0 CDIR=$D" ] && ok \
  || bad "C5 agent-call env: '$(head -1 "$T/argv/agent-call.env" 2>/dev/null)' want DEAD_ALERT=0"

# C2 — same day, two more ticks: no more spend
run "$D"; r2=$RC
run "$D"; r3=$RC
[ "$r2$r3" = 11 ] && ok || bad "C2 rc run2=$r2 run3=$r3 want 1 1"
[ "$(lines "$T/argv/agent-call.log")" = 1 ] && ok \
  || bad "C2 agent-call ran $(lines "$T/argv/agent-call.log") times over 3 runs, want 1"
grep "already attempted today for $FP" "$T/logs/agent-rules.log" 2>/dev/null | grep -qF "$D/.credentials.json" && ok \
  || bad "C2 no 'already attempted today for $FP' line naming the file: $(cat "$T/logs/agent-rules.log" 2>/dev/null)"
[ "$(grep -c 'already attempted today' "$T/logs/agent-rules.log" 2>/dev/null)" = 2 ] && ok || bad "C2 want one skip line per skipped run"

# C4 — unrouted: no page of any kind
[ ! -s "$T/argv/lane-alert.log" ] && ok || bad "C4 lane-alert ran for an unrouted dir: $(cat "$T/argv/lane-alert.log")"
[ -s "$T/logs/ALERTS.log" ] && bad "C4 ALERTS.log written for an unrouted dir: $(cat "$T/logs/ALERTS.log")" || ok
grep -q 'not routed by any account; no page' "$T/logs/agent-rules.log" 2>/dev/null && ok || bad "C4 no 'not routed' log line"

# C3 — healthy CLI-only login: every successful refresh earns a new claim
reset; mkcreds "$D" 60 h1
FP1=$(fp_of "$D")
run "$D" BUMP=1
[ "$RC" = 0 ] && ok || bad "C3 run1 rc=$RC want 0"
[ "$(cat "$T/ledger/oauth-refresh:$FP1:$TODAY" 2>/dev/null)" = ok ] && ok || bad "C3 run1 ledger '$(cat "$T/ledger/oauth-refresh:$FP1:$TODAY" 2>/dev/null)' want ok"
mkcreds "$D" 60 h2
[ "$(fp_of "$D")" != "$FP1" ] || bad "C3 fixture: re-expired file has the same fp"
run "$D" BUMP=1
[ "$RC" = 0 ] && ok || bad "C3 run2 rc=$RC want 0"
[ "$(lines "$T/argv/agent-call.log")" = 2 ] && ok || bad "C3 agent-call ran $(lines "$T/argv/agent-call.log") times, want 2 (new fp = new claim)"
[ ! -s "$T/argv/lane-alert.log" ] && ok || bad "C3 lane-alert ran on success with nothing fired: $(cat "$T/argv/lane-alert.log")"

# C6 — routed dir (trailing slash in the account file): one warn over 3 runs
reset; mkcreds "$D" -3600
acct max2 claude "CLAUDE_CONFIG_DIR=$D/"
run "$D"; run "$D"; run "$D"
n=$(grep -c -- '--severity warn' "$T/argv/lane-alert.log" 2>/dev/null)
[ "$n" = 1 ] && ok || bad "C6 want exactly 1 warn lane-alert over 3 runs, got ${n:-0}: $(cat "$T/argv/lane-alert.log" 2>/dev/null)"
ID=$(grep -o -- '--id oauth-refresh-[0-9a-f]\{12\}' "$T/argv/lane-alert.log" 2>/dev/null | head -1)
[ -n "$ID" ] && ok || bad "C6 lane-alert carries no --id oauth-refresh-<12hex>: $(cat "$T/argv/lane-alert.log" 2>/dev/null)"
grep -- '--severity warn oauth-refresh ' "$T/argv/lane-alert.log" 2>/dev/null | grep -qF "CLAUDE_CONFIG_DIR=$D claude /login" && ok \
  || bad "C6 alert text must name the re-auth command: $(cat "$T/argv/lane-alert.log" 2>/dev/null)"

# C7 — the routed dir is fresh again: resolve the same id, no spend
: > "$T/argv/lane-alert.log"; rm -f "$T/argv/agent-call.log"
mkcreds "$D" 7200 fresh
run "$D"
[ "$RC" = 0 ] && ok || bad "C7 rc=$RC want 0"
grep -q -- "--resolve $ID oauth-refresh" "$T/argv/lane-alert.log" 2>/dev/null && ok \
  || bad "C7 want '--resolve $ID', got: $(cat "$T/argv/lane-alert.log")"
[ ! -s "$T/argv/agent-call.log" ] && ok || bad "C7 agent-call ran on a fresh token"
: > "$T/argv/lane-alert.log"
run "$D"
[ ! -s "$T/argv/lane-alert.log" ] && ok || bad "C7 a second fresh run resolved again: $(cat "$T/argv/lane-alert.log")"

# C6n — must NOT count as routed
for c in prefix disabled codex; do
  reset; mkcreds "$D" -3600
  case "$c" in
    prefix)   acct main claude "CLAUDE_CONFIG_DIR=$T/home/.claude" ;;
    disabled) acct max2 claude "CLAUDE_CONFIG_DIR=$D" ACCOUNT_ENABLED=0 ;;
    codex)    acct cx codex "CODEX_HOME=$D" ;;
  esac
  run "$D"
  [ "$(lines "$T/argv/agent-call.log")" = 1 ] || bad "C6n/$c fixture: agent-call did not run"
  [ ! -s "$T/argv/lane-alert.log" ] && ok || bad "C6n/$c counted as routed: $(cat "$T/argv/lane-alert.log")"
done

# C8 — store unreachable: do not spend
reset; mkcreds "$D" -3600
run "$D" STUB_CLAIM_RC=2
[ "$RC" = 1 ] && ok || bad "C8 rc=$RC want 1"
[ ! -s "$T/argv/agent-call.log" ] && ok || bad "C8 agent-call ran with the store unreachable"
grep -q 'canary-inference store unreachable or no fp; no CLI refresh attempted' "$T/logs/agent-rules.log" 2>/dev/null && ok \
  || bad "C8 no store-unreachable log line: $(cat "$T/logs/agent-rules.log" 2>/dev/null)"

echo "oauth-refresh-daily-claim: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
