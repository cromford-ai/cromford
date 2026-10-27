#!/bin/bash
# tests/envelope-fleet-consume.bh-8541-test.sh — BH-8541 (BH-7976.1): the hub
# consumer bin/envelope-consume.sh applies `fleet:` envelopes through
# bin/lib/envelope-fleet.sh and, for fleet:telegram, runs bin/fleet-telegram-chat.sh.
# The REAL jobs worker on node:sqlite over 127.0.0.1 (tests/lib/envelope-worker.bh-7965.mjs),
# the real bin/envelope-keygen.sh, a scratch harness. 0 vendor calls: the
# Telegram verb is a stub in F3-F8 (the real verb is #7974, F9 runs it in fake mode).
#   F1 fleet:fly:acme: fly.env lines, fly.token_present=1, applied fleet=fly, no ssh
#   F2 fleet:tailscale and fleet:tailscale:cromford: two lines, one flag
#   F3 fleet:telegram: the verb sees the NEW token; GET /api/settings has
#      telegram.chat_id and telegram.bot_present=1; applied fleet=telegram chat=ok
#   F4 the verb answer table: ok/waiting applied, every other answer apply_failed
#   F5 no verb installed: applied fleet=telegram chat=not-installed, the line is written
#   F6 a value with ': apply_failed fleet=telegram refused, global.env unchanged
#   F7 no sealed value in any output, log, event or ssh argv; no api.telegram.org
#   F8 bin/secrets-apply.sh passes ai-account: and fleet: ids, skips tracker:
#   F9 the real verb in fake mode, when it is in the tree (else one SKIP line)
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/envelope-fleet-consume.bh-8541-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/envelope-suite.bh-7965.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v openssl >/dev/null 2>&1 || { echo "SKIP: node, jq, curl or openssl missing"; exit 0; }
es_init || { echo "setup failed"; exit 1; }
( cd "$DIR" && scratch_install_closure bin/lib/envelope-fleet.sh "$H" ) >/dev/null 2>&1 || { echo "setup: could not install bin/lib/envelope-fleet.sh"; exit 1; }
export HARNESS_ENV_DIR="$H/env"
trap 'es_stop' EXIT
es_srv w1; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "${PORT:-}" ] || { echo "setup: worker did not start: $(cat "$T/w1.err")"; exit 1; }
"$H/bin/envelope-keygen.sh" > "$T/keygen.out" 2>&1 || { echo "setup: keygen failed: $(cat "$T/keygen.out")"; exit 1; }
openssl pkey -in "$ENVELOPE_KEY" -pubout -out "$T/keys/pub.pem" 2>/dev/null

consume() { "$H/bin/envelope-consume.sh" "$1" > "$T/c.out" 2> "$T/c.err"; RC=$?; }
events() { es_get "SELECT event, detail FROM secret_envelope_events WHERE envelope_id='$1' ORDER BY id" | jq -r '.[] | "\(.event) \(.detail // "")"' | paste -sd'|'; }
setting() { curl -sS -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/settings/$1" | jq -r '.setting.value // empty'; }
count() { grep -c -E "$1" "$2" 2>/dev/null || true; }
SEALED=()
seal() { SEALED+=("$1"); es_seal "$1" "$2"; }
G="$H/env/global.env"; FE="$H/env/fly.env"
: > "$T/ssh-argv.log"

# The stub verb: the interface of bin/fleet-telegram-chat.sh (#7985): no
# arguments, the token from env TELEGRAM_BOT_TOKEN else the global.env line, one
# `TELEGRAM_CHAT ...` line. It records the token it saw and writes the rows the
# real verb writes, through the same PUT /api/settings.
install_stub() {
  cat > "$H/bin/fleet-telegram-chat.sh" <<'EOF'
#!/bin/bash
# fixture verb (tests/envelope-fleet-consume.bh-8541-test.sh)
. "$HARNESS/bin/lib/env-path.sh"
tok="${TELEGRAM_BOT_TOKEN:-}"
[ -n "$tok" ] || tok=$( set -a; . "$(harness_env_dir "$HARNESS")/global.env" >/dev/null 2>&1; printf '%s' "${TELEGRAM_BOT_TOKEN:-}" )
printf '%s' "$tok" > "$ES_T/stub-saw"
echo run >> "$ES_T/stub-runs"
if [ -n "${STUB_LINE+x}" ]; then printf '%s\n' "$STUB_LINE"; exit "${STUB_RC:-0}"; fi
. "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1 || exit 1
setting_set telegram.chat_id 4242 && setting_set telegram.bot_present 1 && setting_set telegram.state ok || exit 1
echo "TELEGRAM_CHAT ok 4242"
EOF
  chmod +x "$H/bin/fleet-telegram-chat.sh"
}

echo "F1: fleet:fly:acme"
V1='FlyV1 fm2_tok-fixture-f1,abc'
ID=$(seal "$V1" fleet:fly:acme)
[ -n "$ID" ] || bad "F1 setup: seal failed"
consume "$ID"
[ "$RC" = 0 ] && ok "F1 exit 0" || bad "F1 rc=$RC err=$(cat "$T/c.err")"
[ "$(count "^FLY_ORG='acme'$" "$FE")" = 1 ] && [ "$(count "^FLY_API_TOKEN='$V1'$" "$FE")" = 1 ] \
  && ok "F1 fly.env has one FLY_ORG and one FLY_API_TOKEN line" || bad "F1 fly.env: $(cat "$FE" 2>&1 | sed 's/=.*/=…/')"
[ "$(stat -c %a "$FE" 2>/dev/null)" = 600 ] && ok "F1 fly.env mode 600" || bad "F1 mode $(stat -c %a "$FE" 2>&1)"
[ "$(es_get "SELECT value FROM settings WHERE key='fly.token_present'" | jq -r '.[0].value // empty')" = 1 ] \
  && ok "F1 fly.token_present=1" || bad "F1 flag not set"
[ "$(events "$ID")" = "stored |consumed |applied fleet=fly" ] && ok "F1 events stored, consumed, applied fleet=fly" || bad "F1 events: $(events "$ID")"
[ ! -s "$T/ssh-argv.log" ] && ok "F1 no ssh call" || bad "F1 ssh argv: $(cat "$T/ssh-argv.log")"

echo "F2: fleet:tailscale, fleet:tailscale:cromford"
ID=$(seal tskey-auth-fixture-f2a fleet:tailscale); consume "$ID"; RCA=$RC; EA=$(events "$ID")
ID=$(seal tskey-auth-fixture-f2b fleet:tailscale:cromford); consume "$ID"; RCB=$RC; EB=$(events "$ID")
[ "$RCA" = 0 ] && [ "$RCB" = 0 ] && ok "F2 both exit 0" || bad "F2 rc=$RCA,$RCB"
[ "$(count "^TS_AUTHKEY='tskey-auth-fixture-f2a'$" "$FE")" = 1 ] && [ "$(count "^TS_AUTHKEY_CROMFORD='tskey-auth-fixture-f2b'$" "$FE")" = 1 ] \
  && ok "F2 TS_AUTHKEY and TS_AUTHKEY_CROMFORD lines" || bad "F2 fly.env lines"
[ "$(es_get "SELECT value FROM settings WHERE key='tailscale.key_present'" | jq -r '.[0].value // empty')" = 1 ] \
  && ok "F2 tailscale.key_present=1" || bad "F2 flag not set"
[ "$EA" = "stored |consumed |applied fleet=tailscale" ] && [ "$EB" = "stored |consumed |applied fleet=tailscale" ] \
  && ok "F2 both applied fleet=tailscale" || bad "F2 events: $EA / $EB"

echo "F3: fleet:telegram runs the chat verb"
install_stub
printf '%s\n' 'KEEP=1' "TELEGRAM_BOT_TOKEN='111:old-fixture-token'" > "$G"; chmod 600 "$G"
V3='222:new-fixture-token_f3'
ID=$(seal "$V3" fleet:telegram)
TELEGRAM_BOT_TOKEN='111:old-fixture-token' consume "$ID"
[ "$RC" = 0 ] && ok "F3 exit 0" || bad "F3 rc=$RC err=$(cat "$T/c.err")"
[ "$(count '^TELEGRAM_BOT_TOKEN=' "$G")" = 1 ] && [ "$(count "^TELEGRAM_BOT_TOKEN='$V3'$" "$G")" = 1 ] && [ "$(count '^KEEP=1$' "$G")" = 1 ] \
  && ok "F3 one TELEGRAM_BOT_TOKEN line, the new token, other lines kept" || bad "F3 global.env lines"
[ "$(stat -c %a "$G")" = 600 ] && ok "F3 global.env mode 600" || bad "F3 mode $(stat -c %a "$G")"
[ "$(cat "$T/stub-saw" 2>/dev/null)" = "$V3" ] && ok "F3 the verb saw the NEW token" || bad "F3 the verb saw the wrong token"
[ "$(setting telegram.chat_id)" = 4242 ] && ok "F3 GET /api/settings/telegram.chat_id = 4242" || bad "F3 chat_id '$(setting telegram.chat_id)'"
[ "$(setting telegram.bot_present)" = 1 ] && ok "F3 GET /api/settings/telegram.bot_present = 1" || bad "F3 bot_present '$(setting telegram.bot_present)'"
[ "$(events "$ID")" = "stored |consumed |applied fleet=telegram chat=ok" ] && ok "F3 applied fleet=telegram chat=ok" || bad "F3 events: $(events "$ID")"

echo "F4: the verb answer table"
F4_N=0
f4() { # f4 <rc> <line> <want exit> <want last event>
  local id
  F4_N=$((F4_N + 1))
  id=$(seal "333:fixture-f4-$F4_N" fleet:telegram)
  STUB_RC="$1" STUB_LINE="$2" consume "$id"
  local got; got=$(events "$id"); got=${got##*|}
  [ "$RC" = "$3" ] && [ "$got" = "$4" ] && ok "F4 rc $1 '$2' -> exit $3, $4" || bad "F4 rc $1 '$2': exit $RC, '$got' (want $3, $4)"
}
f4 0 'TELEGRAM_CHAT ok 123'                0 'applied fleet=telegram chat=ok'
f4 0 'TELEGRAM_CHAT ok -100123'            0 'applied fleet=telegram chat=ok'
f4 0 'TELEGRAM_CHAT waiting no update yet' 0 'applied fleet=telegram chat=waiting'
f4 1 'TELEGRAM_CHAT failed 401'            1 'apply_failed fleet=telegram chat=failed'
f4 0 ''                                    1 'apply_failed fleet=telegram chat=failed'
f4 0 'TELEGRAM_CHAT okay'                  1 'apply_failed fleet=telegram chat=failed'
f4 2 'usage: fleet-telegram-chat.sh'       1 'apply_failed fleet=telegram chat=failed'
f4 0 'TELEGRAM_CHAT failed x'              1 'apply_failed fleet=telegram chat=failed'
f4 1 'TELEGRAM_CHAT ok 123'                1 'apply_failed fleet=telegram chat=failed'
f4 0 'TELEGRAM_CHAT waitingx'              1 'apply_failed fleet=telegram chat=failed'

echo "F5: no verb installed"
rm -f "$H/bin/fleet-telegram-chat.sh"
V5='444:fixture-token-f5'
ID=$(seal "$V5" fleet:telegram); consume "$ID"
[ "$RC" = 0 ] && [ "$(events "$ID")" = "stored |consumed |applied fleet=telegram chat=not-installed" ] \
  && ok "F5 exit 0, applied fleet=telegram chat=not-installed" || bad "F5 rc=$RC $(events "$ID")"
[ "$(count "^TELEGRAM_BOT_TOKEN='$V5'$" "$G")" = 1 ] && ok "F5 the token line is written" || bad "F5 no token line"
grep -q "telegram chat verb not installed" "$H/logs/secrets-apply.log" && ok "F5 one log line names the missing verb" || bad "F5 no log line"

echo "F6: a value with a quote"
install_stub; : > "$T/stub-runs"
BEFORE=$(cat "$G")
ID=$(seal "555:fixture'f6" fleet:telegram); consume "$ID"
[ "$RC" = 1 ] && [ "$(events "$ID")" = "stored |consumed |apply_failed fleet=telegram refused" ] \
  && ok "F6 exit 1, apply_failed fleet=telegram refused" || bad "F6 rc=$RC $(events "$ID")"
[ "$(cat "$G")" = "$BEFORE" ] && ok "F6 global.env unchanged" || bad "F6 global.env changed"
[ ! -s "$T/stub-runs" ] && ok "F6 the verb did not run" || bad "F6 the verb ran"

echo "F8: bin/secrets-apply.sh passes fleet: ids"
es_sql "DELETE FROM secret_envelopes"
IDA=$(seal tok-fixture-claude-good ai-account:claude:f8:project:demo)
IDT=$(seal '666:fixture-token-f8' fleet:telegram)
IDX=$(seal tok-fixture-claude-good tracker:jira:acme)
"$H/bin/secrets-apply.sh" > "$T/run.out" 2>&1; RC=$?
[ "$RC" = 0 ] && ok "F8 exit 0" || bad "F8 rc=$RC $(cat "$T/run.out")"
grep -q "tick pending=3 consumed=2 failed=0 skipped=1 " "$H/logs/secrets-apply.log" \
  && ok "F8 tick pending=3 consumed=2 failed=0 skipped=1" || bad "F8 log: $(grep tick "$H/logs/secrets-apply.log" | tail -1)"
[ "$(events "$IDT")" = "stored |consumed |applied fleet=telegram chat=ok" ] && ok "F8 the fleet envelope is applied" || bad "F8 fleet events: $(events "$IDT")"
[ "$(events "$IDA")" = "stored |consumed |applied boxes=1/1" ] && ok "F8 the ai-account envelope is applied" || bad "F8 ai events: $(events "$IDA")"
[ "$(es_get "SELECT COUNT(*) AS n FROM secret_envelopes WHERE id='$IDX'" | jq -r '.[0].n')" = 1 ] && [ "$(events "$IDX")" = "stored " ] \
  && ok "F8 the tracker envelope stays pending" || bad "F8 tracker: $(events "$IDX")"
[ "$(count '^TELEGRAM_BOT_TOKEN=' "$G")" = 1 ] && ok "F8 still one TELEGRAM_BOT_TOKEN line" || bad "F8 token lines $(count '^TELEGRAM_BOT_TOKEN=' "$G")"

echo "F9: the real verb in fake mode"
if [ -x "$DIR/bin/fleet-telegram-chat.sh" ] && [ -f "$DIR/bin/lib/vendor/telegram.sh" ] && [ -f "$DIR/tests/fakes/vendor/telegram.json" ]; then
  rm -f "$H/bin/fleet-telegram-chat.sh"
  ( cd "$DIR" && scratch_install_closure bin/fleet-telegram-chat.sh "$H" ) >/dev/null 2>&1 || bad "F9 setup: could not install the verb"
  chmod +x "$H/bin/fleet-telegram-chat.sh"
  es_sql "DELETE FROM settings WHERE key IN ('telegram.chat_id','telegram.bot_present')"
  export VENDOR_CALL_LOG="$T/vendor-calls.log"; : > "$VENDOR_CALL_LOG"
  ID=$(seal '777:fixture-token-f9' fleet:telegram)
  HARNESS_VENDOR_MODE=fake consume "$ID"
  [ "$RC" = 0 ] && ok "F9 exit 0 ($(events "$ID"))" || bad "F9 rc=$RC $(events "$ID")"
  [ -n "$(setting telegram.chat_id)" ] && [ "$(setting telegram.bot_present)" = 1 ] \
    && ok "F9 telegram.chat_id and telegram.bot_present=1 are stored" || bad "F9 rows: '$(setting telegram.chat_id)' '$(setting telegram.bot_present)'"
  [ ! -s "$VENDOR_CALL_LOG" ] && ok "F9 0 vendor calls" || bad "F9 vendor calls: $(wc -l < "$VENDOR_CALL_LOG")"
else
  echo "SKIP F9: contract verb not in tree (#7974)"
fi

echo "F7: no secret in any output"
LEAK=0
for f in "$T/c.out" "$T/c.err" "$T/run.out" "$T/w1.log" "$T/w1.err" "$T/ssh-argv.log" "$H"/logs/*; do
  [ -f "$f" ] || continue
  for v in "${SEALED[@]}"; do
    if grep -qF -- "$v" "$f"; then LEAK=1; bad "F7 a sealed value is in ${f#"$T"/}"; fi
  done
  grep -q 'api\.telegram\.org' "$f" && { LEAK=1; bad "F7 api.telegram.org in ${f#"$T"/}"; }
done
DETAILS=$(es_get "SELECT detail FROM secret_envelope_events" | jq -r '.[].detail // empty')
for v in "${SEALED[@]}"; do
  grep -qF -- "$v" <<<"$DETAILS" && { LEAK=1; bad "F7 a sealed value is in an event detail"; }
done
[ "$LEAK" = 0 ] && ok "F7 no sealed value in stdout, stderr, logs, the worker log, ssh argv or event details" || true

echo "envelope-fleet-consume.bh-8541: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
