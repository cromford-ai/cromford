#!/bin/bash
# tests/envelope-consume.bh-7965-test.sh — BH-7965 (BH-7937.2): bin/envelope-consume.sh
# reads one envelope from the REAL jobs worker over HTTP
# (tests/lib/envelope-worker.bh-7965.mjs), decrypts it with a key pair made by
# the real bin/envelope-keygen.sh, proves it through the fake vendor seam
# (HARNESS_VENDOR_FAKE=1) and writes it over a PATH shim ssh to scratch boxes.
#   C0 a bad id: exit 1, no request
#   C1 observable outcome: claude project token lands in accounts.d, the account
#      lib reads it back, confirm boxes=1/1, the hub header was sent
#   C2 the token is in no output, log, worker log or ssh argv
#   C3 a refused key: exit 1, nothing written, apply_failed
#   C4 pool scope, one box fails: exit 4, the good box written, the failed ip named
#   C5 the same id again: exit 3, no new event
#   C6 xai project key: the other env lines stay, the line is added once, then replaced
#   C7 decision rule 4: an existing pool key is never overwritten
#   C8 the wrong key: exit 2, apply_failed "decrypt failed"
#   C9 decision rule 2: the scope grammar table
#   C10 after --rotate an envelope sealed to the old key decrypts inside the TTL only
#   C11 the hub token refused: exit 75, one ALERTS line, the envelope stays pending
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/envelope-consume.bh-7965-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/envelope-suite.bh-7965.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v openssl >/dev/null 2>&1 || { echo "SKIP: node, jq, curl or openssl missing"; exit 0; }
for f in "$DIR/bin/envelope-consume.sh" "$DIR/bin/lib/envelope.sh" "$DIR/tests/lib/envelope-worker.bh-7965.mjs" \
         "$DIR/tests/lib/envelope-suite.bh-7965.sh"; do
  [ -s "$f" ] && ok "source exists: ${f#"$DIR"/}" || bad "missing source ${f#"$DIR"/}"
done
es_init || { echo "setup failed"; exit 1; }
trap 'es_stop' EXIT
es_srv w1; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "${PORT:-}" ] || { echo "setup: worker did not start: $(cat "$T/w1.err")"; exit 1; }
"$H/bin/envelope-keygen.sh" > "$T/keygen.out" 2>&1 || { echo "setup: keygen failed: $(cat "$T/keygen.out")"; exit 1; }
openssl pkey -in "$ENVELOPE_KEY" -pubout -out "$T/keys/pub.pem" 2>/dev/null

consume() { "$H/bin/envelope-consume.sh" "$1" > "$T/c.out" 2> "$T/c.err"; RC=$?; }
events() { es_get "SELECT event, detail FROM secret_envelope_events WHERE envelope_id='$1' ORDER BY id" | jq -r '.[] | "\(.event) \(.detail // "")"' | paste -sd'|'; }
pending() { es_get "SELECT COUNT(*) AS n FROM secret_envelopes WHERE id='$1'" | jq -r '.[0].n'; }
B10=$(es_box 192.0.2.10); B11=$(es_box 192.0.2.11)

echo "C0: a bad id"
N0=$(wc -l < "$T/w1.log")
"$H/bin/envelope-consume.sh" not-a-uuid >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && [ "$(wc -l < "$T/w1.log")" = "$N0" ] && ok "C0 exit 1 and no request" || bad "C0 rc=$RC"

echo "C1: observable outcome"
TOK=tok-fixture-claude-good
ID1=$(es_seal "$TOK" ai-account:claude:team-a:project:demo)
[ -n "$ID1" ] || bad "C1 setup: seal failed"
consume "$ID1"
[ "$RC" = 0 ] && ok "C1 exit 0" || bad "C1 rc=$RC err=$(cat "$T/c.err")"
F="$B10/env/accounts.d/team-a.env"
[ -f "$F" ] && [ "$(stat -c %a "$F")" = 600 ] && ok "C1 accounts.d/team-a.env mode 600" || bad "C1 file $(ls -la "$B10/env/accounts.d" 2>&1)"
[ "$(cat "$F" 2>/dev/null)" = "CLAUDE_CODE_OAUTH_TOKEN=$TOK" ] && ok "C1 file holds the token line" || bad "C1 file content"
[ ! -e "$B11/env/accounts.d/team-a.env" ] && ok "C1 the other project's box is not written" || bad "C1 wrote 192.0.2.11"
GOT=$(HARNESS="$B10" JOBS_URL='' ACCOUNT_OWN_PROJECTS=demo=team-a bash -c ". '$DIR/bin/lib/project-account.sh'; project_account_exports demo" 2>/dev/null)
[ "$GOT" = "export CLAUDE_CODE_OAUTH_TOKEN='$TOK'" ] && ok "C1 project_account_exports demo reads the token back" || bad "C1 account lib read: '$GOT'"
[ "$(events "$ID1")" = "stored |consumed |applied boxes=1/1" ] && ok "C1 events stored, consumed, applied boxes=1/1" || bad "C1 events: $(events "$ID1")"
grep -q "^GET /api/secrets/envelope/$ID1 200 hub=1$" "$T/w1.log" && grep -q "^POST /api/secrets/envelope/$ID1/confirm 200 hub=1$" "$T/w1.log" \
  && ok "C1 the read and the confirm carried x-envelope-hub-token" || bad "C1 worker log: $(cat "$T/w1.log")"
[ "$(pending "$ID1")" = 0 ] && ok "C1 the envelope row is gone" || bad "C1 row still there"

echo "C3: a refused key"
ID3=$(es_seal tok-fixture-claude-bad ai-account:claude:team-b:project:demo)
consume "$ID3"
[ "$RC" = 1 ] && [ ! -e "$B10/env/accounts.d/team-b.env" ] && ok "C3 exit 1, no file" || bad "C3 rc=$RC"
[ "$(events "$ID3")" = "stored |consumed |apply_failed vendor refused the key" ] && ok "C3 apply_failed vendor refused the key" || bad "C3 events: $(events "$ID3")"
ID3b=$(es_seal tok-fixture-claude-down ai-account:claude:team-b:project:demo)
consume "$ID3b"
[ "$RC" = 1 ] && [ "$(events "$ID3b")" = "stored |consumed |apply_failed vendor unreachable" ] && ok "C3 an unreachable vendor: exit 1, apply_failed vendor unreachable" || bad "C3b rc=$RC $(events "$ID3b")"
ID3c=$(es_seal 'short' ai-account:claude:team-b:project:demo)
consume "$ID3c"
[ "$RC" = 1 ] && [ "$(events "$ID3c")" = "stored |consumed |apply_failed value format" ] && ok "C3 a short value: apply_failed value format" || bad "C3c rc=$RC $(events "$ID3c")"
[ ! -e "$B10/env/accounts.d/team-b.env" ] && [ ! -e "$B11/env/accounts.d/team-b.env" ] && ok "C3 no box holds team-b" || bad "C3 a box holds team-b"

echo "C4: pool scope, one box fails"
ID4=$(es_seal tok-fixture-xai-good ai-account:xai:ops:pool)
SSH_FAIL_IPS=192.0.2.11 consume "$ID4"
[ "$RC" = 4 ] && ok "C4 exit 4" || bad "C4 rc=$RC"
grep -qx 'XAI_API_KEY=tok-fixture-xai-good' "$B10/env/global.env" 2>/dev/null && ok "C4 the good box holds XAI_API_KEY" || bad "C4 good box: $(cat "$B10/env/global.env" 2>&1)"
[ ! -s "$B11/env/global.env" ] && ok "C4 the failed box is not written" || bad "C4 failed box written"
[ "$(events "$ID4")" = "stored |consumed |apply_failed boxes=1/2 failed=192.0.2.11" ] && ok "C4 apply_failed names 192.0.2.11" || bad "C4 events: $(events "$ID4")"

echo "C5: the same id again"
consume "$ID1"
[ "$RC" = 3 ] && [ "$(events "$ID1")" = "stored |consumed |applied boxes=1/1" ] && ok "C5 exit 3, no new event" || bad "C5 rc=$RC $(events "$ID1")"

echo "C6: xai project key keeps the other lines"
printf 'FOO=1\n# a comment line\nBAR="two words"' > "$B10/env/demo.env"
ID6=$(es_seal tok-fixture-xai-good ai-account:xai:ops:project:demo)
consume "$ID6"
[ "$RC" = 0 ] && ok "C6 exit 0" || bad "C6 rc=$RC"
WANT=$(printf 'FOO=1\n# a comment line\nBAR="two words"\nXAI_API_KEY_OPS=tok-fixture-xai-good')
[ "$(cat "$B10/env/demo.env")" = "$WANT" ] && ok "C6 the 3 other lines stay, the key line is added" || bad "C6 file: $(cat -A "$B10/env/demo.env")"
[ "$(stat -c %a "$B10/env/demo.env")" = 600 ] && ok "C6 mode 600" || bad "C6 mode $(stat -c %a "$B10/env/demo.env")"
ID6b=$(es_seal tok-fixture-xai-good2 ai-account:xai:ops:project:demo)
consume "$ID6b"
WANT2=$(printf 'FOO=1\n# a comment line\nBAR="two words"\nXAI_API_KEY_OPS=tok-fixture-xai-good2')
[ "$RC" = 0 ] && [ "$(cat "$B10/env/demo.env")" = "$WANT2" ] && [ "$(grep -c '^XAI_API_KEY_OPS=' "$B10/env/demo.env")" = 1 ] \
  && ok "C6 a second envelope replaces the line, once" || bad "C6b rc=$RC $(cat -A "$B10/env/demo.env")"
GOT=$(set -a; . "$B10/env/demo.env"; printf '%s' "$XAI_API_KEY_OPS")
[ "$GOT" = tok-fixture-xai-good2 ] && ok "C6 the env file sources and gives the new key" || bad "C6 source: $GOT"

echo "C7: decision rule 4 (pool key never overwritten)"
mkdir -p "$B10/env" "$B11/env"
printf 'OPENROUTER_API_KEY=tok-fixture-openrouter-old\nKEEP=1\n' > "$B10/env/global.env"
printf 'OPENROUTER_API_KEY=tok-fixture-openrouter-old\n' > "$B11/env/global.env"
ID7=$(es_seal tok-fixture-openrouter-good ai-account:openrouter:backup-1:fallback)
consume "$ID7"
[ "$RC" = 4 ] && [ "$(cat "$B10/env/global.env")" = "$(printf 'OPENROUTER_API_KEY=tok-fixture-openrouter-old\nKEEP=1')" ] \
  && [ "$(cat "$B11/env/global.env")" = OPENROUTER_API_KEY=tok-fixture-openrouter-old ] \
  && ok "C7 an existing OPENROUTER_API_KEY line: no write, exit 4" || bad "C7 rc=$RC $(cat "$B10/env/global.env")"
[ "$(events "$ID7")" = "stored |consumed |apply_failed boxes=0/2 failed=192.0.2.10,192.0.2.11" ] && ok "C7 both boxes named failed" || bad "C7 events: $(events "$ID7")"
grep -q 'key exists; use Rotate' "$H/logs/secrets-apply.log" && ok "C7 the log says key exists; use Rotate" || bad "C7 log"
printf 'FIREWORKS_API_KEY_OTHER=tok-fixture-x\n#FIREWORKS_API_KEY=tok-fixture-y\n' > "$B10/env/global.env"
printf 'FIREWORKS_API_KEY_OTHER=tok-fixture-x\n#FIREWORKS_API_KEY=tok-fixture-y\n' > "$B11/env/global.env"
ID7b=$(es_seal tok-fixture-fireworks-good ai-account:fireworks:main:pool)
consume "$ID7b"
WANT=$(printf 'FIREWORKS_API_KEY_OTHER=tok-fixture-x\n#FIREWORKS_API_KEY=tok-fixture-y\nFIREWORKS_API_KEY=tok-fixture-fireworks-good')
[ "$RC" = 0 ] && [ "$(cat "$B10/env/global.env")" = "$WANT" ] && [ "$(cat "$B11/env/global.env")" = "$WANT" ] \
  && ok "C7 a prefix near miss and a commented line do not block the write" || bad "C7b rc=$RC $(cat -A "$B10/env/global.env")"

echo "C8: the wrong key"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$T/other.key" 2>/dev/null
openssl pkey -in "$T/other.key" -pubout -out "$T/other.pub" 2>/dev/null
ID8=$(es_seal tok-fixture-claude-good ai-account:claude:team-c:project:demo "$T/other.pub")
consume "$ID8"
[ "$RC" = 2 ] && [ "$(events "$ID8")" = "stored |consumed |apply_failed decrypt failed" ] && [ ! -e "$B10/env/accounts.d/team-c.env" ] \
  && ok "C8 exit 2, apply_failed decrypt failed, nothing written" || bad "C8 rc=$RC $(events "$ID8")"

echo "C9: decision rule 2 (scope grammar)"
c9() { # c9 <want: accept|refuse[:reason]> <scope>
  local out rc
  out=$(ENVELOPE_FLEET_CONF_BIN="$H/bin/fleet-conf.sh" bash -c ". '$DIR/bin/lib/envelope.sh'; envelope_scope_parse '$2'"); rc=$?
  case "$1" in
    accept) [ "$rc" = 0 ] && ok "C9 accept $2 -> $out" || bad "C9 should accept $2 ($out)" ;;
    refuse) [ "$rc" = 1 ] && ok "C9 refuse $2 ($out)" || bad "C9 should refuse $2 (rc=$rc $out)" ;;
    refuse:*) [ "$rc" = 1 ] && [ "$out" = "${1#refuse:}" ] && ok "C9 refuse $2: $out" || bad "C9 should refuse $2 with '${1#refuse:}' (rc=$rc '$out')" ;;
  esac
}
c9 accept ai-account:claude:team-a:project:demo
c9 accept ai-account:xai:ops:pool
c9 accept ai-account:openrouter:backup-1:fallback
c9 accept ai-account:claude:skate:pool
c9 'refuse:label looks like a key' ai-account:claude:sk-ant-oat01-abc:pool
c9 'refuse:label looks like a key' ai-account:xai:xai-abc123:pool
c9 'refuse:label looks like a key' ai-account:fireworks:fw_abc:pool
c9 'refuse:label looks like a key' ai-account:openrouter:or-abc:pool
c9 'refuse:label looks like a key' "ai-account:claude:$(printf 'a%.0s' $(seq 1 49)):pool"
c9 'refuse:project scope needs a project' ai-account:claude:team-a:project
c9 'refuse:only a project scope names a project' ai-account:claude:team-a:pool:demo
c9 'refuse:unknown project' ai-account:claude:team-a:project:nosuch
c9 'refuse:unknown vendor' ai-account:gemini:x:pool
c9 'refuse:scope has too few fields' ai-account:claude:team-a
c9 'refuse:scope has too many fields' ai-account:claude:team-a:project:demo:x
c9 'refuse:unknown use kind' ai-account:claude:team-a:shared
c9 'refuse:not an ai-account scope' tracker:jira:x
c9 refuse 'ai-account:claude:../x:pool'
ID9=$(es_seal tok-fixture-claude-good tracker:jira:x)
consume "$ID9"
[ "$RC" = 1 ] && [ "$(events "$ID9")" = "stored |consumed |apply_failed scope refused: not an ai-account scope" ] \
  && ok "C9 envelope-consume refuses a tracker scope, nothing written" || bad "C9 tracker rc=$RC $(events "$ID9")"

echo "C10: --rotate keeps the old key for one TTL"
T0=1791000000
IDA=$(es_seal tok-fixture-claude-good ai-account:claude:rot-a:project:demo)
IDB=$(es_seal tok-fixture-claude-good ai-account:claude:rot-b:project:demo)
ENVELOPE_NOW=$T0 "$H/bin/envelope-keygen.sh" --rotate > "$T/rot.out" 2>&1 || bad "C10 rotate failed: $(cat "$T/rot.out")"
[ -f "$ENVELOPE_KEY.$T0" ] || bad "C10 no envelope.key.$T0"
ENVELOPE_NOW=$((T0 + 60)) consume "$IDA"
[ "$RC" = 0 ] && [ -f "$B10/env/accounts.d/rot-a.env" ] && ok "C10 60 s after the rotation the old key decrypts" || bad "C10a rc=$RC"
ENVELOPE_NOW=$((T0 + 900)) consume "$IDB"
[ "$RC" = 2 ] && [ ! -e "$B10/env/accounts.d/rot-b.env" ] && ok "C10 at the TTL the old key is not tried: exit 2" || bad "C10b rc=$RC"

echo "C11: the hub token refused"
ID11=$(es_seal tok-fixture-claude-good ai-account:claude:team-d:project:demo)
: > "$H/logs/ALERTS.log"
ENVELOPE_HUB_TOKEN=tok-fixture-wrong consume "$ID11"
[ "$RC" = 75 ] && ok "C11 exit 75" || bad "C11 rc=$RC"
[ "$(grep -c 'hub token not accepted' "$H/logs/ALERTS.log")" = 1 ] && ok "C11 one ALERTS line" || bad "C11 ALERTS: $(cat "$H/logs/ALERTS.log")"
[ "$(pending "$ID11")" = 1 ] && [ "$(events "$ID11")" = "stored " ] && ok "C11 the envelope stays pending" || bad "C11 pending=$(pending "$ID11") $(events "$ID11")"

echo "C2: no secret in any output"
LEAK=0
for f in "$T/c.out" "$T/c.err" "$T/keygen.out" "$T/w1.log" "$T/w1.err" "$T/ssh-argv.log" "$H"/logs/*; do
  [ -f "$f" ] || continue
  if grep -qE 'tok-fixture-(claude|xai|openrouter|fireworks)-good' "$f"; then LEAK=1; bad "C2 a secret value is in ${f#"$T"/}"; fi
done
[ -s "$T/ssh-argv.log" ] && [ "$LEAK" = 0 ] && ok "C2 no value in stdout, stderr, logs, the worker log or the ssh argv" || [ "$LEAK" = 1 ] || bad "C2 no ssh argv log"
# The worker log must also hold no ciphertext and no hub token.
! grep -q "$ES_HUB" "$T/w1.log" "$T/ssh-argv.log" "$H"/logs/* 2>/dev/null && ok "C2 the hub token is in no log" || bad "C2 hub token in a log"

echo "envelope-consume.bh-7965: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
