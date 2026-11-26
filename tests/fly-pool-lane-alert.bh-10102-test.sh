#!/bin/bash
# tests/fly-pool-lane-alert.bh-10102-test.sh — a RUNNER_EXHAUSTED lane failure
# names the whole runner line and the leased account label in its alert
# (BH-10102). The reap cut the RESULT line at 120 bytes, inside
# "runner=claude r…", so the alert row never said which account ran out.
#
# Driven through the real bin/fly-pool.sh against the shared fake HARNESS and
# fake flyctl (tests/lib/pool-reap-fixture.sh):
#   L1  cooled branch and hold branch: the ALERTS line holds the WHOLE RESULT
#       first line and account=<lease>; one lane-failure line per reap; no
#       lease -> account=none
#   L2  a fixture token in the env bundle, the machine record and the fly
#       output reaches no alert, queue file, hold or pool log
#   L3  the alert beat's `line`, and the pool_deferred status beat's
#       `detail`, hold the whole RESULT line
#   L4  an ordinary deferral keeps its 120-byte text and names no account
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/pool-reap-fixture.sh" || exit 1
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
prf_setup
cp "$DIR/bin/alert-line.sh" "$H/bin/"
# beat.sh records its one argv, so L3 can read the alert beat.
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats"\nexit 0\n' "$T" > "$H/bin/beat.sh"
chmod +x "$H/bin/beat.sh"
HF="$H/state/pool/project-5/_spawn-hold"
QF="$H/state/build-queue/project-5/BH-1016.json"
LANE_EX="BUILD_DEFERRED plan session ended RUNNER_EXHAUSTED class=account-exhausted(quota) seen=account-exhausted runner=claude rc=1 exhausted=claude resets_at=$RESET"
lanefail_lines() { grep -cE 'BH-1016: (the RUNNER LANE failed|account [a-z0-9._-]+ ran out)' "$H/logs/ALERTS.log" || true; }

# ── L1: the cooled branch (another account can serve) ─────────────────────
prf_reset; : > "$T/beats"
write_fly_stub "m-exh=$LANE_EX"
machine_json m-exh BH-1016 2 max3
prf_run_pool OTHERS_OK=1 COOLING=1 POOL_SPAWN=0
L=$(grep 'BH-1016: account max3 ran out' "$H/logs/ALERTS.log")
[ -n "$L" ] && ok || bad "L1 cooled: no 'account max3 ran out' alert: $(cat "$H/logs/ALERTS.log")"
grep -qF -- "($LANE_EX account=max3)" <<<"$L" && ok || bad "L1 cooled: the alert must hold the whole RESULT line and account=max3: $L"
[ "$(lanefail_lines)" = 1 ] && ok || bad "L1 cooled: one lane-failure alert per reap (got $(lanefail_lines))"
grep -qF -- "LANE FAILURE BH-1016: $LANE_EX account=max3 — requeued" "$H/logs/fly-pool.log" \
  && ok || bad "L1 cooled: the say line must hold the whole line: $(grep 'LANE FAILURE' "$H/logs/fly-pool.log")"

# ── L1: the hold branch (no other account) ────────────────────────────────
prf_reset; : > "$T/beats"
write_fly_stub "m-exh=$LANE_EX"
machine_json m-exh BH-1016 2 max3
prf_run_pool OTHERS_OK=0 COOLING=1
L=$(grep 'BH-1016: the RUNNER LANE failed' "$H/logs/ALERTS.log")
grep -qF -- "($LANE_EX account=max3)" <<<"$L" && ok || bad "L1 hold: the alert must hold the whole RESULT line and account=max3: $L"
[ "$(lanefail_lines)" = 1 ] && ok || bad "L1 hold: one lane-failure alert per reap (got $(lanefail_lines))"
[ -s "$HF" ] && grep -qF 'BH-1016: BUILD_DEFERRED plan session ended RUNNER_EXHAUSTED' "$HF" \
  && ok || bad "L1 hold: the hold reason must carry the RESULT line: $(cat "$HF" 2>/dev/null)"
# L3: the alert beat (alert-line.sh's argv to beat.sh) holds the whole line.
jq -r 'select(.kind=="alert") | .line' "$T/beats" 2>/dev/null | grep -qF -- "$LANE_EX account=max3" \
  && ok || bad "L3: the alert beat's line must hold the whole RESULT line: $(cat "$T/beats")"
# L3b: the project status beat (stage pool_deferred) carries the same text.
[ "$(jq -r 'select(.kind=="build" and .stage=="pool_deferred") | .detail' "$T/beats" 2>/dev/null)" = "$LANE_EX account=max3" ] \
  && ok || bad "L3b: the pool_deferred beat detail must be the whole line + account: $(grep pool_deferred "$T/beats")"

# ── L1: no lease -> account=none ──────────────────────────────────────────
prf_reset; : > "$T/beats"
write_fly_stub "m-exh=$LANE_EX"
machine_json m-exh BH-1016 2
prf_run_pool OTHERS_OK=0 COOLING=1
grep -qF -- "($LANE_EX account=none)" "$H/logs/ALERTS.log" && ok || bad "L1 none: no lease must print account=none: $(cat "$H/logs/ALERTS.log")"

# ── L2: no token reaches any text ─────────────────────────────────────────
TOK="sk-ant-oat01-fixture-TESTONLY-0000"
prf_reset; : > "$T/beats"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOK" >> "$H/env/global.env"
printf 'ANTHROPIC_API_KEY=%s\n' "$TOK" >> "$H/env/fly.env"
write_fly_stub "m-exh=$LANE_EX"
machine_json m-exh BH-1016 2 max3
jq --arg t "$TOK" '. + {token_fixture:$t}' "$H/state/fly-pool/project-5/m-exh.json" > "$T/mj" && mv "$T/mj" "$H/state/fly-pool/project-5/m-exh.json"
prf_run_pool OTHERS_OK=0 COOLING=1
LEAK=""
for f in "$H/logs/ALERTS.log" "$QF" "$HF" "$H/logs/fly-pool.log" "$T/beats"; do
  [ -f "$f" ] && grep -qF -- "$TOK" "$f" && LEAK="$LEAK $f"
done
[ -z "$LEAK" ] && ok || bad "L2: the fixture token reached:$LEAK"
grep -qF -- "account=max3" "$H/logs/ALERTS.log" && ok || bad "L2: the label is still printed"

# ── L4: an ordinary deferral keeps its 120-byte text ──────────────────────
LONG="BUILD_DEFERRED wip-limit 2 reached for project-5; open PRs #101 #102 hold both slots and this ticket waits for one of them to merge or close; next try in 30m"
prf_reset; : > "$T/beats"
write_fly_stub "m-ok=$LONG"
machine_json m-ok BH-1016 0 max3
prf_run_pool OTHERS_OK=1 COOLING=1 POOL_SPAWN=0
CUT=${LONG:0:120}   # ASCII: 120 chars = 120 bytes
grep -qF -- "pool build DEFERRED ($CUT) — requeued" "$H/logs/ALERTS.log" && ok || bad "L4: the ordinary deferral text must stay at 120 bytes: $(cat "$H/logs/ALERTS.log")"
grep -q 'account=' "$H/logs/ALERTS.log" && bad "L4: an ordinary deferral printed an account" || ok
[ "$(lanefail_lines)" = 0 ] && ok || bad "L4: an ordinary deferral wrote a lane-failure alert"
[ "$(jq -r 'select(.kind=="build" and .stage=="pool_deferred") | .detail' "$T/beats" 2>/dev/null)" = "$CUT" ] \
  && ok || bad "L4: the ordinary pool_deferred beat detail stays the 120-byte text: $(grep pool_deferred "$T/beats")"

echo "fly-pool-lane-alert: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
