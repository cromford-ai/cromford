#!/bin/bash
# tests/secrets-apply-held.bh-7968-test.sh — BH-7968 (BH-7937.4): an
# ai-account:<v>:<l>:project:<p> envelope stays pending while <p> is not
# registered. The Onboard form seals the new project's own account before the
# run's register station writes the registry row; the read deletes the
# envelope and bin/envelope-consume.sh refuses an unknown project after it, so
# a consume before register loses the secret. bin/secrets-apply.sh and
# obe_consume (bin/lib/onboard-envelopes.sh) both hold it.
# Runs against the REAL jobs worker over HTTP (tests/lib/envelope-worker.bh-7965.mjs)
# with the real bin/envelope-consume.sh; $H/bin/fleet-conf.sh is a wrapper
# that counts `--projects` calls and can answer empty or fail, else runs the
# real one.
#   H1 an unregistered project: no read, one `held <id> (project newp not
#      registered)` line, the envelope stays pending; after the row is added the
#      next tick consumes and applies it (red on main: the secret is lost)
#   H2 a registered project: one consume; obe_consume with the real consumer is
#      held while unregistered (the envelope stays pending) and applies it once
#      registered
#   H3 pool and fleet scopes with an empty registry: consumed (the hold binds
#      project scopes only); `p` listed and scope `px`: held
#   H4 fleet-conf.sh fails: held (fail closed); the registry is read once per
#      tick with two pending project scopes
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/secrets-apply-held.bh-7968-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/envelope-suite.bh-7965.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v openssl >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: node, jq, curl, openssl or flock missing"; exit 0; }
es_init || { echo "setup failed"; exit 1; }
trap 'es_stop; __scratch_exit_trap' EXIT
es_srv w1; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "${PORT:-}" ] || { echo "setup: worker did not start: $(cat "$T/w1.err")"; exit 1; }
"$H/bin/envelope-keygen.sh" > "$T/keygen.out" 2>&1 || { echo "setup: keygen failed: $(cat "$T/keygen.out")"; exit 1; }
openssl pkey -in "$ENVELOPE_KEY" -pubout -out "$T/keys/pub.pem" 2>/dev/null
export ENVELOPE_NOW=1791000000

# The registry wrapper: $T/projects-mode is real | empty | fail for `--projects`.
mv "$H/bin/fleet-conf.sh" "$H/bin/fleet-conf-real.sh"
cat > "$H/bin/fleet-conf.sh" <<EOF
#!/bin/bash
if [ "\${1:-}" = --projects ]; then
  echo x >> "$T/projects-calls"
  case "\$(cat "$T/projects-mode" 2>/dev/null)" in
    empty) exit 0 ;;
    fail) exit 1 ;;
  esac
fi
exec "$H/bin/fleet-conf-real.sh" "\$@"
EOF
chmod +x "$H/bin/fleet-conf.sh"
echo real > "$T/projects-mode"

run() { "$H/bin/secrets-apply.sh" > "$T/run.out" 2>&1; RC=$?; }
count_ev() { es_get "SELECT COUNT(*) AS n FROM secret_envelope_events WHERE envelope_id='$1' AND event='$2'" | jq -r '.[0].n'; }
pending() { es_get "SELECT COUNT(*) AS n FROM secret_envelopes WHERE id='$1'" | jq -r '.[0].n'; }
pcalls() { [ -s "$T/projects-calls" ] && wc -l < "$T/projects-calls" || echo 0; }
RESET() { : > "$H/logs/ALERTS.log"; : > "$H/logs/secrets-apply.log"; : > "$T/projects-calls"; scratch_rm "$H/state/alerts"; }
LOG="$H/logs/secrets-apply.log"

echo "H1: a project that is not registered yet"
RESET
ID1=$(es_seal tok-fixture-claude-good ai-account:claude:nine:project:newp)
[ -n "$ID1" ] || bad "H1 setup: seal failed"
run
[ "$RC" = 0 ] && [ "$(pending "$ID1")" = 1 ] && [ "$(count_ev "$ID1" consumed)" = 0 ] \
  && ok "H1 an unregistered project: the envelope is not read and stays pending" || bad "H1 rc=$RC pending=$(pending "$ID1") consumed=$(count_ev "$ID1" consumed)"
[ "$(grep -c "held $ID1 (project newp not registered)" "$LOG")" = 1 ] && ok "H1 one held line" || bad "H1 log: $(cat "$LOG")"
printf 'newp   o/newp   https://newp.example.test   -  3  box-demo   192.0.2.10\n' >> "$T/fleet.conf"
run
[ "$(pending "$ID1")" = 0 ] && [ "$(count_ev "$ID1" consumed)" = 1 ] && [ "$(count_ev "$ID1" applied)" = 1 ] \
  && [ -f "$(es_box 192.0.2.10)/env/accounts.d/nine.env" ] \
  && ok "H1 after the row is added the next tick applies it" || bad "H1 after register: pending=$(pending "$ID1") applied=$(count_ev "$ID1" applied)"

echo "H2: a registered project, and obe_consume with the real consumer"
RESET
ID2=$(es_seal tok-fixture-claude-good ai-account:claude:two:project:demo)
run
[ "$(count_ev "$ID2" consumed)" = 1 ] && [ "$(count_ev "$ID2" applied)" = 1 ] && ! grep -q "held $ID2" "$LOG" \
  && ok "H2 a registered project: consumed once and applied" || bad "H2 consumed=$(count_ev "$ID2" consumed) log=$(cat "$LOG")"
ID2b=$(es_seal tok-fixture-claude-good ai-account:claude:ten:project:newq)
jq -nc --arg a "$ID2b" '{run:{id:"ob_fixture", inputs:{project:"newq", ai_envelope:$a}}, steps:[{station:"register", state:"queued"}]}' > "$T/run2.json"
obe() {
  ( export ONBOARD_ENVELOPE_CONSUME="$H/bin/envelope-consume.sh" ONBOARD_FLEET_CONF="$H/bin/fleet-conf.sh"
    # shellcheck source=bin/lib/onboard-envelopes.sh
    . "$DIR/bin/lib/onboard-envelopes.sh" || exit 98
    obe_consume "$T/run2.json" ob_fixture ) > "$T/obe.out" 2>&1
}
obe
[ "$(pending "$ID2b")" = 1 ] && [ "$(count_ev "$ID2b" consumed)" = 0 ] && grep -q "envelope ob_fixture $ID2b held (project newq not registered)" "$T/obe.out" \
  && ok "H2 obe_consume, unregistered: held, the envelope stays pending" || bad "H2 held: pending=$(pending "$ID2b") out=$(cat "$T/obe.out")"
printf 'newq   o/newq   https://newq.example.test   -  4  box-demo   192.0.2.10\n' >> "$T/fleet.conf"
obe
[ "$(pending "$ID2b")" = 0 ] && [ "$(count_ev "$ID2b" applied)" = 1 ] && [ -f "$(es_box 192.0.2.10)/env/accounts.d/ten.env" ] \
  && grep -q "envelope ob_fixture $ID2b applied" "$T/obe.out" \
  && ok "H2 obe_consume, registered: applied, the secret is on the box" || bad "H2 applied: pending=$(pending "$ID2b") out=$(cat "$T/obe.out")"

echo "H3: the hold binds project scopes only"
RESET; echo empty > "$T/projects-mode"
ID3p=$(es_seal tok-fixture-xai-good ai-account:xai:three:pool)
ID3f=$(es_seal tok-fixture-openrouter-good ai-account:openrouter:three-f:fallback)
ID3t=$(es_seal tok-fixture-fleet-3 fleet:telegram)
run
for id in "$ID3p" "$ID3f" "$ID3t"; do
  [ -n "$id" ] && [ "$(count_ev "$id" consumed)" = 1 ] && ! grep -q "held $id" "$LOG" \
    && ok "H3 $id (not a project scope) is consumed with an empty registry" || bad "H3 '$id' consumed=$(count_ev "$id" consumed) log=$(cat "$LOG")"
done
[ "$(pcalls)" = 0 ] && ok "H3 no project scope pending: the registry is not read" || bad "H3 registry read $(pcalls) times"
RESET; echo real > "$T/projects-mode"
ID3x=$(es_seal tok-fixture-claude-good ai-account:claude:three-x:project:demox)
run
[ "$(pending "$ID3x")" = 1 ] && grep -q "held $ID3x (project demox not registered)" "$LOG" \
  && ok "H3 'demo' listed, scope 'demox': held" || bad "H3 prefix: pending=$(pending "$ID3x") log=$(cat "$LOG")"
es_sql "DELETE FROM secret_envelopes WHERE id='$ID3x'"

echo "H4: the registry fails closed and is read once per tick"
RESET; echo fail > "$T/projects-mode"
ID4a=$(es_seal tok-fixture-claude-good ai-account:claude:four-a:project:demo)
ID4b=$(es_seal tok-fixture-claude-good ai-account:claude:four-b:project:other)
run
[ "$RC" = 0 ] && [ "$(pending "$ID4a")" = 1 ] && [ "$(pending "$ID4b")" = 1 ] \
  && grep -q "held $ID4a (project demo not registered)" "$LOG" && grep -q "held $ID4b (project other not registered)" "$LOG" \
  && ok "H4 fleet-conf.sh fails: both held, both still pending" || bad "H4 rc=$RC pending=$(pending "$ID4a")/$(pending "$ID4b") log=$(cat "$LOG")"
[ "$(pcalls)" = 1 ] && ok "H4 two pending project scopes: the registry is read once" || bad "H4 registry read $(pcalls) times"
RESET; echo real > "$T/projects-mode"
run
# envelope-consume.sh reads --projects once per consume itself (bin/lib/envelope.sh),
# so this tick reads it 1 (secrets-apply) + 2 (the two consumes) = 3 times.
[ "$(count_ev "$ID4a" applied)" = 1 ] && [ "$(count_ev "$ID4b" applied)" = 1 ] && [ "$(pcalls)" = 3 ] \
  && ok "H4 the registry back: both applied, one read by the tick" || bad "H4 recovery: applied=$(count_ev "$ID4a" applied)/$(count_ev "$ID4b" applied) reads=$(pcalls)"

! grep -qE 'tok-fixture-(claude|xai|openrouter)-good' "$H"/logs/* "$T/w1.log" "$T/run.out" "$T/obe.out" && ok "H5 no secret value in any log" || bad "H5 a value is in a log"

echo "secrets-apply-held.bh-7968: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
