#!/bin/bash
# tests/agent-call-runner-lock.bh-9675-test.sh — BH-9675 (C1 of #9334): the
# settings row runner_lock.<project>=claude makes bin/agent-call.sh run only
# claude rungs for that project, and exit rc 75 (a wait the caller defers on)
# when no claude rung can run. One `RUNNER LOCK WAIT` failovers.log line per
# wait, and no DEAD ALERTS line for it.
#
#   N1   no row: a 529 on claude descends to grok, as on main.
#   N2   a row for another project only: the same as N1.
#   N3   lock + RUNNER_EVAL=codex: codex never runs, claude does, rc 0.
#   N4   lock + RUNNER_EVAL_FALLBACK=openrouter, claude 529: no codex, rc 75.
#   N5   lock + AGENT_CALL_RUNNERS=claude,openrouter, claude 529: no codex, rc 75.
#   N6   lock + RUNNER_EVAL=gemini: gemini never runs, claude does.
#   C1   lock + AGENT_CALL_RUNNERS=codex: rc 2, the refusal marker, nothing runs.
#   C2   row `Claude` (a bad value): fails closed to the lock, one line naming it.
#   C3   no settings cache at all: no lock.
#   B1/B2 row `codex` and an empty row: fail closed to the lock.
#   W1   lock, 529 every attempt: rc 75, only claude, one wait line, no DEAD.
#   W2   429 rate_limit_error -> rc 75.  W3 401 authentication_error -> rc 75.
#   W4   api-key project with no key (rc 76 refusal) -> rc 75, no grok.
#   W5   claude not installed -> rc 75 before any call, 0 cost rows.
#   W6   a real failure keeps rc 1 and the DEAD line.  W7 rc 124 is not a wait.
#   W8   two waits -> two wait lines, one ALERTS line.
#   W9   a 529, then a success on the retry -> rc 0, no wait line.
#   W10  a 529, then a real failure on the retry -> the real rc, no wait line.
#
# DRIVEN, NOT GREPPED: bin/agent-call.sh runs for real against a scratch
# HARNESS with fake CLIs (0 network calls); the real bin/lib/claude-auth.sh
# reads the settings cache.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" p-lock p-free
mkdir -p "$T/bin" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/env/accounts.d" "$T/ms"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------- fakes -----------------------------------------------------------
# claude: CL_MODE picks the answer; CL_SEQ="a b c" gives one mode per attempt.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in *" --help "*) printf -- '  --session-id <uuid>\n'; exit 0 ;; esac
echo "claude" >> "$ORDER_SINK"
mode="${CL_MODE:-ok}"
if [ -n "${CL_SEQ:-}" ]; then
  n=$(grep -c '^claude' "$ORDER_SINK")
  set -- $CL_SEQ
  mode="${!n:-${!#}}"
fi
case "$mode" in
  ok)   printf '{"result":"ok","usage":{"input_tokens":5,"output_tokens":1},"total_cost_usd":0.01}\n'; exit 0 ;;
  529)  echo 'API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}'; exit 1 ;;
  429)  echo 'API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}'; exit 1 ;;
  401)  echo 'API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"bad credential"}}'; exit 1 ;;
  fail) echo 'something broke'; exit 1 ;;
  t124) echo 'still working'; exit 124 ;;
esac
EOF
for v in grok codex gemini; do
  printf '#!/bin/bash\necho "%s" >> "$ORDER_SINK"; echo "%s answered"; exit 0\n' "$v" "$v" > "$T/fakebin/$v"
done
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\nexec bash "%s/bin/billing-mode.sh" "$@"\n' "$DIR" > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
# The REAL alert-line helper (its beat goes to the stub above).
printf '#!/bin/bash\nexec bash "%s/bin/alert-line.sh" "$@"\n' "$DIR" > "$T/bin/alert-line.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
printf '#!/bin/bash\necho "1 2 3 4"\n' > "$T/bin/codex-usage.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh
echo '{}' > "$T/catalog.json"
mkdir -p "$T/.codex"; echo '{}' > "$T/.codex/auth.json"   # codex is ready, so only the lock keeps it off

cache()   { jq -n --argjson fa "$(date -u +%s)" --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' > "$T/state/settings-cache.json"; }
nocache() { rm -f "$T/state/settings-cache.json"; }
reset() {
  : > "$T/order"; : > "$T/logs/failovers.log"; : > "$T/logs/ALERTS.log"; : > "$T/logs/cost.csv"
  rm -f "$T/out.txt"* "$T/flags/alerted-runner-lock-wait-"*; rm -rf "$T/state/quota" "$T/state/agent-call-ledger"
  rm -f "$T/state/model-cooldown-"* "$T/state/runner-fast-fail-"*
}

# run_call <project> [ENV=...] — drives bin/agent-call.sh for real. NORESET=1
# keeps the logs of the call before (W8).
run_call() {
  local p="$1"; shift
  [ "${NORESET:-0}" = 1 ] || reset
  ( export ORDER_SINK="$T/order" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           ACCOUNTS_DIR="$T/env/accounts.d" LADDER_BACKOFF_SECS=0 LADDER_TIER2_GROK=1 \
           RUNNER_EVAL="${RUNNER_EVAL:-claude}" CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           AUTH_ACCOUNTS_CATALOG="$T/catalog.json" JOBS_URL= \
           OPENROUTER_API_KEY=or-fixture FIREWORKS_API_KEY=fw-fixture GEMINI_API_KEY=gm-fixture \
           CLAUDE_MANAGED_SETTINGS_FILE="$T/ms/none.json" CLAUDE_MANAGED_SETTINGS_DIR="$T/ms/none.d"
    env -u ACCOUNT_ROUTING -u RUNNER_EVAL_FALLBACK -u AGENT_CALL_RUNNERS -u CLAUDE_CODE_OAUTH_TOKEN \
      -u ANTHROPIC_API_KEY -u ACCOUNT_OWN_PROJECTS -u CL_MODE -u CL_SEQ \
      "$@" bash "$DIR/bin/agent-call.sh" eval "$p" claude-opus-5 600 "$T/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}
count()     { grep -c "^$1" "$T/order" 2>/dev/null || true; }
others()    { grep -vc '^claude' "$T/order" 2>/dev/null || true; }
waits()     { grep -c 'RUNNER LOCK WAIT' "$T/logs/failovers.log" 2>/dev/null || true; }
dead()      { grep -c 'DEAD:' "$T/logs/ALERTS.log" 2>/dev/null || true; }
claudecost(){ grep -c ',claude,' "$T/logs/cost.csv" 2>/dev/null || true; }
LOCK='{"runner_lock.p-lock":"claude"}'

# ── N1 no row: a 529 descends to grok, as on main ──────────────────────────
cache '{}'
RC=$(run_call p-lock CL_MODE=529)
[ "$RC" = 0 ] && [ "$(count grok)" = 1 ] && ok || bad "N1 rc=$RC order=$(tr '\n' ' ' < "$T/order")"
[ "$(waits)" = 0 ] && ok || bad "N1 a wait line with no lock"

# ── N2 a row for another project only ──────────────────────────────────────
cache '{"runner_lock.p-free":"claude"}'
RC=$(run_call p-lock CL_MODE=529)
[ "$RC" = 0 ] && [ "$(count grok)" = 1 ] && [ "$(waits)" = 0 ] && ok || bad "N2 rc=$RC order=$(tr '\n' ' ' < "$T/order")"

# ── C3 no settings cache at all: no lock ───────────────────────────────────
nocache
RC=$(run_call p-lock CL_MODE=529)
[ "$RC" = 0 ] && [ "$(count grok)" = 1 ] && [ "$(waits)" = 0 ] && ok || bad "C3 rc=$RC order=$(tr '\n' ' ' < "$T/order")"

# ── N3 lock, codex primary: claude serves ──────────────────────────────────
cache "$LOCK"
RC=$(RUNNER_EVAL=codex run_call p-lock CL_MODE=ok)
[ "$RC" = 0 ] && [ "$(count claude)" = 1 ] && [ "$(others)" = 0 ] && ok || bad "N3 rc=$RC order=$(tr '\n' ' ' < "$T/order")"

# ── N4 lock, configured fallback openrouter, claude 529 ────────────────────
RC=$(run_call p-lock CL_MODE=529 RUNNER_EVAL_FALLBACK=openrouter)
[ "$RC" = 75 ] && [ "$(others)" = 0 ] && ok || bad "N4 rc=$RC order=$(tr '\n' ' ' < "$T/order")"

# ── N5 lock, caller list claude,openrouter, claude 529 ─────────────────────
RC=$(run_call p-lock CL_MODE=529 AGENT_CALL_RUNNERS=claude,openrouter)
[ "$RC" = 75 ] && [ "$(others)" = 0 ] && ok || bad "N5 rc=$RC order=$(tr '\n' ' ' < "$T/order")"

# ── N6 lock, gemini primary ────────────────────────────────────────────────
RC=$(RUNNER_EVAL=gemini run_call p-lock CL_MODE=ok)
[ "$RC" = 0 ] && [ "$(count gemini)" = 0 ] && [ "$(count claude)" = 1 ] && ok || bad "N6 rc=$RC order=$(tr '\n' ' ' < "$T/order")"

# ── C1 lock, caller allows only codex: refused rc 2 ────────────────────────
RC=$(run_call p-lock CL_MODE=ok AGENT_CALL_RUNNERS=codex)
[ "$RC" = 2 ] && ok || bad "C1 rc=$RC"
head -1 "$T/out.txt" 2>/dev/null | grep -q '^AGENT_CALL_REFUSED runner-lock runner_lock.p-lock=claude' && ok || bad "C1 \$OUT: $(head -1 "$T/out.txt" 2>/dev/null)"
[ ! -s "$T/order" ] && [ "$(claudecost)" = 0 ] && ok || bad "C1 something ran: $(tr '\n' ' ' < "$T/order")"
grep -q 'runner_lock.p-lock=claude and this caller allows only: codex' "$T/logs/failovers.log" && ok || bad "C1 failovers: $(cat "$T/logs/failovers.log")"

# ── C2 / B1 / B2 a bad row value fails closed to the lock ──────────────────
for v in Claude codex ''; do
  cache "$(jq -n --arg v "$v" '{"runner_lock.p-lock":$v}')"
  RC=$(run_call p-lock CL_MODE=529)
  [ "$RC" = 75 ] && [ "$(others)" = 0 ] && ok || bad "C2/B '$v' rc=$RC order=$(tr '\n' ' ' < "$T/order")"
  grep -q "runner_lock.p-lock is not claude .*locking to claude" "$T/logs/failovers.log" && ok || bad "C2/B '$v' no fail-closed line: $(cat "$T/logs/failovers.log")"
done

# ── W1 lock, 529 on every attempt ──────────────────────────────────────────
cache "$LOCK"
RC=$(run_call p-lock CL_MODE=529)
[ "$RC" = 75 ] && ok || bad "W1 rc=$RC"
[ "$(count claude)" -ge 1 ] && [ "$(others)" = 0 ] && ok || bad "W1 order=$(tr '\n' ' ' < "$T/order")"
[ "$(waits)" = 1 ] && grep 'RUNNER LOCK WAIT' "$T/logs/failovers.log" | grep -q 'transient:vendor.*exiting 75' && ok || bad "W1 wait line: $(grep 'LOCK' "$T/logs/failovers.log")"
[ "$(dead)" = 0 ] && grep -q 'DEAD:' "$T/logs/failovers.log" && bad "W1 a DEAD line was written" || ok
[ "$(dead)" = 0 ] && ok || bad "W1 a DEAD ALERTS line"
grep -q '^RUNNER_ERROR class=transient(vendor)' "$T/out.txt.class" 2>/dev/null && ok || bad "W1 .class: $(cat "$T/out.txt.class" 2>/dev/null)"
[ "$(claudecost)" = "$(count claude)" ] && ok || bad "W1 cost rows $(claudecost) != claude attempts $(count claude)"
[ "$(grep -c 'RUNNER LOCK WAIT' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "W1 ALERTS: $(cat "$T/logs/ALERTS.log")"

# ── W2 429 / W3 401 ────────────────────────────────────────────────────────
RC=$(run_call p-lock CL_MODE=429)
[ "$RC" = 75 ] && [ "$(others)" = 0 ] && grep 'RUNNER LOCK WAIT' "$T/logs/failovers.log" | grep -q 'transient:rate_limited' && ok || bad "W2 rc=$RC $(grep LOCK "$T/logs/failovers.log")"
RC=$(run_call p-lock CL_MODE=401)
[ "$RC" = 75 ] && [ "$(others)" = 0 ] && grep 'RUNNER LOCK WAIT' "$T/logs/failovers.log" | grep -q 'auth:' && ok || bad "W3 rc=$RC $(grep LOCK "$T/logs/failovers.log")"

# ── W4 api-key project, no key on the box (rc 76 refusal) ──────────────────
cache '{"runner_lock.p-lock":"claude","claude_auth.p-lock":"api-key"}'
RC=$(run_call p-lock CL_MODE=ok)
[ "$RC" = 75 ] && [ ! -s "$T/order" ] && ok || bad "W4 rc=$RC order=$(tr '\n' ' ' < "$T/order")"
grep 'RUNNER LOCK WAIT' "$T/logs/failovers.log" | grep -q 'account-exhausted:no_headroom' && ok || bad "W4 wait line: $(grep LOCK "$T/logs/failovers.log")"

# ── W5 claude not installed ────────────────────────────────────────────────
cache "$LOCK"
mkdir -p "$T/nocl"
for d in ${PATH//:/ }; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b=${f##*/}; [ "$b" = claude ] && continue
    [ -e "$T/nocl/$b" ] || ln -s "$f" "$T/nocl/$b" 2>/dev/null
  done
done
mv "$T/fakebin/claude" "$T/claude.off"
if PATH="$T/fakebin:$T/nocl" command -v claude >/dev/null 2>&1; then
  echo "SKIP W5: a claude binary cannot be hidden on this box"
else
  RC=$(PATH="$T/nocl" run_call p-lock)
  [ "$RC" = 75 ] && ok || bad "W5 rc=$RC"
  head -1 "$T/out.txt" 2>/dev/null | grep -q '^AGENT_CALL_REFUSED runner-lock-wait' && ok || bad "W5 \$OUT: $(head -1 "$T/out.txt" 2>/dev/null)"
  [ ! -s "$T/order" ] && [ "$(claudecost)" = 0 ] && ok || bad "W5 something ran: $(tr '\n' ' ' < "$T/order")"
  [ "$(waits)" = 1 ] && grep 'RUNNER LOCK WAIT' "$T/logs/failovers.log" | grep -q 'claude-not-ready' && ok || bad "W5 wait line: $(cat "$T/logs/failovers.log")"
fi
mv "$T/claude.off" "$T/fakebin/claude"

# ── W6 a real failure keeps its rc and its DEAD line ───────────────────────
RC=$(run_call p-lock CL_MODE=fail)
[ "$RC" = 1 ] && [ "$(others)" = 0 ] && ok || bad "W6 rc=$RC order=$(tr '\n' ' ' < "$T/order")"
[ "$(waits)" = 0 ] && [ "$(dead)" = 1 ] && ok || bad "W6 waits=$(waits) dead=$(dead)"

# ── W7 a timeout is not a wait ─────────────────────────────────────────────
RC=$(run_call p-lock CL_MODE=t124)
[ "$RC" != 75 ] && [ "$RC" != 0 ] && [ "$(others)" = 0 ] && [ "$(waits)" = 0 ] && ok || bad "W7 rc=$RC waits=$(waits) order=$(tr '\n' ' ' < "$T/order")"

# ── W8 two waits: two failovers lines, one ALERTS line ─────────────────────
RC=$(run_call p-lock CL_MODE=529)
RC2=$(NORESET=1 run_call p-lock CL_MODE=529)
[ "$RC" = 75 ] && [ "$RC2" = 75 ] && [ "$(waits)" = 2 ] && ok || bad "W8 rc=$RC/$RC2 waits=$(waits)"
[ "$(grep -c 'RUNNER LOCK WAIT' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "W8 ALERTS: $(cat "$T/logs/ALERTS.log")"

# ── W9 a 529, then a success ───────────────────────────────────────────────
RC=$(run_call p-lock CL_SEQ="529 ok")
[ "$RC" = 0 ] && [ "$(count claude)" = 2 ] && [ "$(waits)" = 0 ] && ok || bad "W9 rc=$RC waits=$(waits) order=$(tr '\n' ' ' < "$T/order")"

# ── W10 a 529, then a real failure: one non-waitable kind decides ──────────
RC=$(run_call p-lock CL_SEQ="529 fail")
[ "$RC" != 75 ] && [ "$RC" != 0 ] && [ "$(others)" = 0 ] && [ "$(waits)" = 0 ] && ok || bad "W10 rc=$RC waits=$(waits) order=$(tr '\n' ' ' < "$T/order")"

echo "agent-call-runner-lock.bh-9675: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
