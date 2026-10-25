#!/bin/bash
# tests/secrets-apply.bh-7965-test.sh — BH-7965 (BH-7937.2): the per-minute hub
# lane bin/secrets-apply.sh against the REAL jobs worker over HTTP
# (tests/lib/envelope-worker.bh-7965.mjs), with the real bin/envelope-consume.sh,
# the fake vendor seam and a PATH shim ssh.
#   A1 a held lock skips the tick: exit 0, no worker request
#   A2 two ai-account envelopes and one tracker envelope: each ai-account one is
#      consumed once, the tracker one stays pending
#   A3 the hub token refused: one ALERTS line, the loop stops
#   A4 no key file and 1 pending: one ALERTS line, still one after a second run
#   A5 a rotated key older than the TTL is deleted, a younger one is kept
#   A6 a knob out of range: exit 1, one ALERTS line, no request
#   A7 no ENVELOPE_HUB_TOKEN: exit 0, one log line, no request
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/secrets-apply.bh-7965-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/envelope-suite.bh-7965.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v openssl >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: node, jq, curl, openssl or flock missing"; exit 0; }
for f in "$DIR/bin/secrets-apply.sh" "$DIR/catalog/lanes.d/secrets-apply.json" "$DIR/cron/lanes/773-secrets-apply.cron"; do
  [ -s "$f" ] && ok "source exists: ${f#"$DIR"/}" || bad "missing source ${f#"$DIR"/}"
done
es_init || { echo "setup failed"; exit 1; }
trap 'es_stop' EXIT
es_srv w1; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "${PORT:-}" ] || { echo "setup: worker did not start: $(cat "$T/w1.err")"; exit 1; }
"$H/bin/envelope-keygen.sh" > "$T/keygen.out" 2>&1 || { echo "setup: keygen failed: $(cat "$T/keygen.out")"; exit 1; }
openssl pkey -in "$ENVELOPE_KEY" -pubout -out "$T/keys/pub.pem" 2>/dev/null
export ENVELOPE_NOW=1791000000

run() { "$H/bin/secrets-apply.sh" > "$T/run.out" 2>&1; RC=$?; }
# Envelope requests only: the lane gate's own flag and liveness calls come first.
reqs() { grep -c ' /api/secrets/' "$T/w1.log"; }
count_ev() { es_get "SELECT COUNT(*) AS n FROM secret_envelope_events WHERE envelope_id='$1' AND event='$2'" | jq -r '.[0].n'; }
pending() { es_get "SELECT COUNT(*) AS n FROM secret_envelopes WHERE id='$1'" | jq -r '.[0].n'; }
RESET() { : > "$H/logs/ALERTS.log"; : > "$H/logs/secrets-apply.log"; scratch_rm "$H/state/alerts"; }

echo "A1: a held lock skips the tick"
RESET
IDL=$(es_seal tok-fixture-claude-good ai-account:claude:lock-a:project:demo)
exec 8>"$H/locks/secrets-apply.lock"; flock -n 8 || bad "A1 setup: cannot take the lock"
N0=$(reqs); run
[ "$RC" = 0 ] && [ "$(reqs)" = "$N0" ] && ok "A1 exit 0 and no envelope request" || bad "A1 rc=$RC requests $N0 -> $(reqs)"
exec 8>&-
[ "$(pending "$IDL")" = 1 ] && ok "A1 the envelope is still pending" || bad "A1 envelope gone"

echo "A2: two ai-account envelopes and a tracker one"
RESET
IDA=$(es_seal tok-fixture-claude-good ai-account:claude:two-a:project:demo)
IDB=$(es_seal tok-fixture-xai-good ai-account:xai:two-b:project:demo)
IDT=$(es_seal tok-fixture-tracker-1 tracker:jira:acme)
run
[ "$RC" = 0 ] && ok "A2 exit 0" || bad "A2 rc=$RC"
for id in "$IDL" "$IDA" "$IDB"; do
  [ "$(count_ev "$id" consumed)" = 1 ] && [ "$(count_ev "$id" applied)" = 1 ] && ok "A2 $id consumed once and applied" \
    || bad "A2 $id consumed=$(count_ev "$id" consumed) applied=$(count_ev "$id" applied)"
done
[ "$(pending "$IDT")" = 1 ] && [ "$(count_ev "$IDT" consumed)" = 0 ] && ok "A2 the tracker envelope stays pending" || bad "A2 tracker consumed"
[ -f "$(es_box 192.0.2.10)/env/accounts.d/two-a.env" ] && grep -q '^XAI_API_KEY_TWO_B=' "$(es_box 192.0.2.10)/env/demo.env" \
  && ok "A2 both secrets are on the demo box" || bad "A2 box files"
grep -q 'tick pending=4 consumed=3 failed=0 skipped=1 truncated=false' "$H/logs/secrets-apply.log" \
  && ok "A2 the log line counts pending=4 consumed=3 skipped=1" || bad "A2 log: $(cat "$H/logs/secrets-apply.log")"
run
[ "$(count_ev "$IDA" consumed)" = 1 ] && grep -q 'tick pending=1 consumed=0 failed=0 skipped=1' "$H/logs/secrets-apply.log" \
  && ok "A2 a second tick consumes nothing again" || bad "A2 second tick: $(tail -1 "$H/logs/secrets-apply.log")"

echo "A3: the hub token refused"
RESET
ID3=$(es_seal tok-fixture-claude-good ai-account:claude:three:project:demo)
ENVELOPE_HUB_TOKEN=tok-fixture-wrong run
[ "$RC" = 0 ] && [ "$(grep -c 'hub token not accepted' "$H/logs/ALERTS.log")" = 1 ] && ok "A3 exit 0 and one ALERTS line" || bad "A3 rc=$RC ALERTS: $(cat "$H/logs/ALERTS.log")"
[ "$(pending "$ID3")" = 1 ] && ok "A3 the envelope stays pending" || bad "A3 envelope gone"
# The worker accepts the list but refuses the read: the first 75 stops the loop.
ID3b=$(es_seal tok-fixture-claude-good ai-account:claude:three-b:project:demo)
mkdir -p "$T/stub"; cp "$H/bin/envelope-consume.sh" "$T/stub/real-consume.sh"
cat > "$H/bin/envelope-consume.sh" <<EOF
#!/bin/bash
echo "\$1" >> "$T/consume-calls"
exit 75
EOF
chmod +x "$H/bin/envelope-consume.sh"; : > "$T/consume-calls"
run
[ "$(wc -l < "$T/consume-calls")" = 1 ] && grep -q 'stopped at' "$H/logs/secrets-apply.log" \
  && ok "A3 the first exit 75 stops the loop (1 of 2 pending tried)" || bad "A3 calls=$(wc -l < "$T/consume-calls")"
cp "$T/stub/real-consume.sh" "$H/bin/envelope-consume.sh"
run
[ "$(pending "$ID3")" = 0 ] && [ "$(pending "$ID3b")" = 0 ] && ok "A3 the next good tick consumes both" || bad "A3 recovery"

echo "A4: no key file"
RESET
mv "$ENVELOPE_KEY" "$T/keys/away.key"
ID4=$(es_seal tok-fixture-claude-good ai-account:claude:four:project:demo)
run; run
[ "$RC" = 0 ] && [ "$(grep -c 'no key at' "$H/logs/ALERTS.log")" = 1 ] && ok "A4 two runs, one ALERTS line" || bad "A4 rc=$RC ALERTS: $(cat "$H/logs/ALERTS.log")"
[ "$(pending "$ID4")" = 1 ] && ok "A4 the envelope is not read without a key" || bad "A4 envelope read"
ENVELOPE_NOW=$((ENVELOPE_NOW + 3600)) run
[ "$(grep -c 'no key at' "$H/logs/ALERTS.log")" -ge 1 ] && [ "$(cat "$H/state/secrets-apply-nokey.stamp")" = $((ENVELOPE_NOW + 3600)) ] \
  && ok "A4 after the window the stamp moves" || bad "A4 stamp $(cat "$H/state/secrets-apply-nokey.stamp")"
mv "$T/keys/away.key" "$ENVELOPE_KEY"

echo "A5: rotated keys and the TTL"
RESET
cp "$ENVELOPE_KEY" "$ENVELOPE_KEY.$((ENVELOPE_NOW - 1000))"
cp "$ENVELOPE_KEY" "$ENVELOPE_KEY.$((ENVELOPE_NOW - 100))"
run
[ ! -e "$ENVELOPE_KEY.$((ENVELOPE_NOW - 1000))" ] && [ -e "$ENVELOPE_KEY.$((ENVELOPE_NOW - 100))" ] && [ -e "$ENVELOPE_KEY" ] \
  && ok "A5 the key older than 900 s is deleted, the younger one and the current one stay" || bad "A5 $(ls "$T/keys")"

echo "A6: a knob out of range"
RESET; N0=$(reqs)
SECRETS_APPLY_BATCH=0 run
[ "$RC" = 1 ] && [ "$(reqs)" = "$N0" ] && [ "$(grep -c 'SECRETS_APPLY_BATCH=0' "$H/logs/ALERTS.log")" = 1 ] && ok "A6 BATCH=0: exit 1, one ALERTS line, no envelope request" || bad "A6 rc=$RC"
SECRETS_APPLY_SSH_TIMEOUT_S=121 run
[ "$RC" = 1 ] && [ "$(reqs)" = "$N0" ] && ok "A6 SSH_TIMEOUT_S=121: exit 1, no request" || bad "A6 ssh rc=$RC"

echo "A7: no hub token"
RESET; N0=$(reqs)
ENVELOPE_HUB_TOKEN=' ' run
[ "$RC" = 0 ] && [ "$(reqs)" = "$N0" ] && grep -q 'not-configured' "$H/logs/secrets-apply.log" && [ ! -s "$H/logs/ALERTS.log" ] \
  && ok "A7 exit 0, a not-configured line, no envelope request, no alert" || bad "A7 rc=$RC"

! grep -qE 'tok-fixture-(claude|xai)-good' "$H"/logs/* "$T/w1.log" "$T/run.out" && ok "A8 no secret value in any log" || bad "A8 a value is in a log"

echo "secrets-apply.bh-7965: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
