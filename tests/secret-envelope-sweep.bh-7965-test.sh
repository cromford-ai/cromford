#!/bin/bash
# tests/secret-envelope-sweep.bh-7965-test.sh — BH-7965 (BH-7937.2): the hourly
# hub lane bin/secret-envelope-sweep.sh against the REAL jobs worker over HTTP
# (tests/lib/envelope-worker.bh-7965.mjs).
#   W1 a 200: exit 0, the log line has the counts; dry run (the default) deletes nothing
#   W2 the worker unreachable (closed port) or 5xx: exit 75
#   W3 archive "failed" in the answer: exit 0 and one ALERTS line
#   W4 knob 2: exit 1, no request; knob unset: body dry_run true; knob 0: a real run
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/secret-envelope-sweep.bh-7965-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/envelope-suite.bh-7965.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }
for f in "$DIR/bin/secret-envelope-sweep.sh" "$DIR/catalog/lanes.d/secret-envelope-sweep.json" "$DIR/cron/lanes/774-secret-envelope-sweep.cron"; do
  [ -s "$f" ] && ok "source exists: ${f#"$DIR"/}" || bad "missing source ${f#"$DIR"/}"
done
es_init || { echo "setup failed"; exit 1; }
trap 'es_stop' EXIT
es_srv w1; src=$?
if [ "$src" = 3 ]; then echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; fi
[ -n "${PORT:-}" ] || { echo "setup: worker did not start: $(cat "$T/w1.err")"; exit 1; }
unset SECRET_ENVELOPE_SWEEP_DRY_RUN
run() { "$H/bin/secret-envelope-sweep.sh" > "$T/run.out" 2>&1; RC=$?; }
# Envelope requests only: the lane gate's own flag and liveness calls come first.
reqs() { grep -c ' /api/secrets/' "$1"; }
n_env() { es_get "SELECT COUNT(*) AS n FROM secret_envelopes" | jq -r '.[0].n'; }
sweep_ev() { es_get "SELECT detail FROM secret_envelope_events WHERE event='sweep' ORDER BY id DESC LIMIT 1" | jq -r '.[0].detail'; }
CT=$(head -c 256 /dev/zero | tr '\0' 'A' | base64 -w0)
es_sql "INSERT INTO secret_envelopes (id, scope, ciphertext, created_at, expires_at) VALUES
  ('exp-fixture-1','ai-account:a','$CT','2020-01-01T00:00:00Z','2020-01-01T00:15:00Z'),
  ('exp-fixture-2','ai-account:a','$CT','2020-01-01T00:00:00Z','2020-01-01T00:15:00Z'),
  ('live-fixture-1','ai-account:a','$CT','2020-01-01T00:00:00Z','2099-01-01T00:00:00Z');"

echo "W1: a 200 (dry run by default)"
run
[ "$RC" = 0 ] && ok "W1 exit 0" || bad "W1 rc=$RC $(cat "$T/run.out")"
grep -q 'sweep dry_run=true envelopes=2 events=0 archive=dry more=false' "$H/logs/secret-envelope-sweep.log" \
  && ok "W1 the log line has the counts" || bad "W1 log: $(cat "$H/logs/secret-envelope-sweep.log")"
[ "$(n_env)" = 3 ] && ok "W1 a dry run deletes nothing" || bad "W1 envelopes=$(n_env)"
[ "$(sweep_ev | jq -r '.dry_run')" = true ] && ok "W4 knob unset: the worker saw dry_run true" || bad "W4 event $(sweep_ev)"

echo "W4: the knob"
N0=$(reqs "$T/w1.log")
SECRET_ENVELOPE_SWEEP_DRY_RUN=2 run
[ "$RC" = 1 ] && [ "$(reqs "$T/w1.log")" = "$N0" ] && [ "$(grep -c 'SECRET_ENVELOPE_SWEEP_DRY_RUN=2' "$H/logs/ALERTS.log")" = 1 ] \
  && ok "W4 knob 2: exit 1, one ALERTS line, no sweep request" || bad "W4 rc=$RC"
SECRET_ENVELOPE_SWEEP_DRY_RUN=0 run
[ "$RC" = 0 ] && [ "$(n_env)" = 1 ] && [ "$(sweep_ev | jq -r '.envelopes')" = 2 ] && ok "W4 knob 0: the 2 expired envelopes are deleted" || bad "W4 real rc=$RC n=$(n_env)"
grep -q 'sweep dry_run=false envelopes=2 events=0 archive=not-bound more=false' "$H/logs/secret-envelope-sweep.log" \
  && ok "W4 the log says archive=not-bound" || bad "W4 log: $(tail -1 "$H/logs/secret-envelope-sweep.log")"

echo "W3: archive failed"
: > "$H/logs/ALERTS.log"
REAL_CURL=$(command -v curl); mkdir -p "$T/w3bin"
cat > "$T/w3bin/curl" <<EOF
#!/bin/bash
for a in "\$@"; do case "\$a" in */api/secrets/envelope/sweep)
  printf '{"dry_run":false,"envelopes":0,"events":0,"archive":"failed","more":false}\n200'; exit 0 ;; esac; done
exec "$REAL_CURL" "\$@"
EOF
chmod +x "$T/w3bin/curl"
PATH="$T/w3bin:$PATH" run
[ "$RC" = 0 ] && [ "$(grep -c 'archive copy failed' "$H/logs/ALERTS.log")" = 1 ] && ok "W3 exit 0 and one ALERTS line" || bad "W3 rc=$RC $(cat "$H/logs/ALERTS.log")"

echo "W2: the worker unreachable"
JOBS_URL="http://127.0.0.1:9" run
[ "$RC" = 75 ] && grep -q 'worker-failed' "$H/logs/secret-envelope-sweep.log" && ok "W2 a closed port: exit 75" || bad "W2 rc=$RC"
es_stop; ES_PIDS=()
es_srv w2 FAIL_ALL=1
run
[ "$RC" = 75 ] && ok "W2 a 500: exit 75" || bad "W2 500 rc=$RC"
JOBS_URL='' run
[ "$RC" = 75 ] && ok "W2 no JOBS_URL: exit 75" || bad "W2 no-url rc=$RC"

echo "secret-envelope-sweep.bh-7965: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
