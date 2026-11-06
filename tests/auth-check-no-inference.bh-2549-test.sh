#!/bin/bash
# tests/auth-check-no-inference.bh-2549-test.sh — BH-2560 (BH-2549.2): the hourly
# claude box loop in bin/claude-auth-check.sh runs on the credential probe, and
# buys its inference (the PROBE_BODY ladder) only through agent-call, only when
# cred_inference_claim says so.
#   Run 1  ALIVE, claim free: one agent-call (canary, runner claude), one claim,
#          one record "ok".
#   Run 2  ALIVE, claim spent: no agent-call, no raw claude.
#   Run 3  DEAD 401: hub in STATE, one CLAUDE AUTH DOWN line.
#   Run 4  INCONCLUSIVE 429: one inconclusive note, no DOWN, no STATE.
#   Run 5  ALIVE, claim spent, conductor marker present: the marker stands.
#   A6     the 6-hourly runner loop: DEAD marks, ALIVE and INCONCLUSIVE do not.
#   A7     NO_ENDPOINT, claim spent: nothing at all.
#   A8     DEGRADED endpoint: MODEL POOL EXHAUSTED, no DOWN.
#   A9     inference refused by agent-call (rc 74): no DOWN, no record.
#   A10    a remote box is asked `lane-probe.sh claude --endpoint` over ssh.
#   A11    ALIVE clears a standing hub outage (RECOVERED).
#   A12    NO_ENDPOINT + inference PROBE_OK clears the conductor marker.
#   M      the claim forced to 0 turns Run 2 red.
# Drives the real script (HARNESS=$R). Run from anywhere (exit 0 = pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
REAL_DATE=$(command -v date)

# build_tree <root> [hour]: one box (hub) unless A10 adds one; hour 01 by default.
build_tree() {
  local R=$1 HR=${2:-01}
  scratch_rm "$R"; mkdir -p "$R/bin/lib" "$R/fakebin" "$R/state" "$R/flags" "$R/logs" "$R/locks"
  cp "$DIR/bin/claude-auth-check.sh" "$R/bin/"
  cp "$DIR/bin/lib/lane-down.sh" "$DIR/bin/lib/fleet-cooldown.sh" "$R/bin/lib/"
  cp "$DIR/bin/alert-line.sh" "$R/bin/"
  printf 'lane_role_model() { echo "m-$1"; }\nlane_model() { echo m-test; }\n' > "$R/bin/lib/lane-model.sh"
  printf '#!/bin/bash\nexit 0\n' > "$R/bin/fleet-conf.sh"
  printf '#!/bin/bash\nexit 0\n' > "$R/bin/box-for.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$(dirname "$0")/../beats.txt"\n' > "$R/bin/beat.sh"
  cat > "$R/bin/agent-call.sh" <<'SH'
#!/bin/bash
# argv: <stage> <project> <model> <timeout> <outfile> <prompt>
R=$(dirname "$0")/..
printf '%s\n' "$*" >> "$R/ac.log"
printf 'AGENT_CALL_RUNNERS=%s AGENT_CALL_LANE=%s ACCOUNT_ROUTING=%s\n' \
  "${AGENT_CALL_RUNNERS:-}" "${AGENT_CALL_LANE:-}" "${ACCOUNT_ROUTING:-}" >> "$R/ac.env"
case "${STUB_AC_MODE:-token}" in
  refuse) printf 'AGENT_CALL_REFUSED llm-gate x\n' | tee "$5.err" > "$5"; exit 74 ;;
  loggedout) printf 'Invalid API key · Please run /login\n' | tee "$5.err" > "$5"; exit 1 ;;
esac
CODE=$(printf '%s' "$6" | grep -oE 'code [0-9a-f]+' | awk '{print $2}' | head -1)
printf 'AUTHPROBE-%s\n' "$CODE" > "$5"
SH
  cat > "$R/bin/lane-probe.sh" <<'SH'
#!/bin/bash
R=$(dirname "$0")/..
echo "$*" >> "$R/probe-calls.txt"
if [ -f "$R/probe-$1" ]; then cat "$R/probe-$1"; else echo "ALIVE 200"; fi
SH
  cat > "$R/fakebin/date" <<SH
#!/bin/bash
for a in "\$@"; do [ "\$a" = "+%H" ] && { echo $HR; exit 0; }; done
exec $REAL_DATE "\$@"
SH
  printf '#!/bin/bash\necho "$*" >> "%s/claude.log"\nexit 99\n' "$R" > "$R/fakebin/claude"
  printf '#!/bin/bash\necho "$*" >> "%s/ssh.log"\nexit 1\n' "$R" > "$R/fakebin/ssh"
  cat > "$R/credlib.sh" <<SH
cred_probe() { echo "\${STUB_EP:-NO_ENDPOINT}"; }
cred_account_fp() { echo fp1; }
cred_inference_claim() {
  grep -qxF "\$1 \$2" "$R/claims" 2>/dev/null && return 1
  printf '%s\\n' "\$1 \$2" >> "$R/claims"; return 0
}
cred_inference_record() { printf '%s\\n' "\$*" >> "$R/records"; }
SH
  chmod +x "$R"/bin/*.sh "$R"/fakebin/*
  # project-1-lane is already down in every run, so its own note stays out of the way
  echo project-1-lane > "$R/state/claude-auth-down.txt"
  : > "$R/logs/ALERTS.log"; : > "$R/beats.txt"
}
spend_claim() { echo "claude fp1" >> "$1/claims"; }   # today's inference already bought
run_check() { # run_check <root> [VAR=val ...]: the production entry point
  local R=$1; shift
  env HARNESS="$R" PATH="$R/fakebin:$PATH" CRED_PROBE_LIB="$R/credlib.sh" "$@" \
    bash "$R/bin/claude-auth-check.sh" >"$R/out.txt" 2>&1
}
cnt() { [ -f "$1" ] && grep -c -- "$2" "$1" || echo 0; }
lines() { [ -f "$1" ] && grep -c . "$1" || echo 0; }

# ---- Run 1: ALIVE, claim free -------------------------------------------------
R="$T/r1"; build_tree "$R"
run_check "$R" STUB_EP="ALIVE 200"; rc=$?
[ "$rc" = 0 ] && ok || bad "Run1 rc=$rc: $(cat "$R/out.txt")"
# hub + project-1-lane share fp1 here, so the second probe finds the claim taken
[ "$(lines "$R/ac.log")" = 1 ] && ok || bad "Run1 want exactly 1 agent-call: $(cat "$R/ac.log" 2>/dev/null)"
# TEST-CHANGE (BH-9125): the canary runs on model_routes role auth.canary, not triage.
grep -q '^canary fleet m-auth.canary 90 ' "$R/ac.log" 2>/dev/null && ok || bad "Run1 argv: $(cat "$R/ac.log" 2>/dev/null)"
grep -qx 'AGENT_CALL_RUNNERS=claude AGENT_CALL_LANE=claude-auth-check ACCOUNT_ROUTING=0' "$R/ac.env" 2>/dev/null && ok || bad "Run1 env: $(cat "$R/ac.env" 2>/dev/null)"
[ "$(lines "$R/claims")" = 1 ] && ok || bad "Run1 claims: $(cat "$R/claims" 2>/dev/null)"
[ "$(cat "$R/records" 2>/dev/null)" = "claude fp1 ok" ] && ok || bad "Run1 record: $(cat "$R/records" 2>/dev/null)"
[ "$(lines "$R/claude.log")" = 0 ] && ok || bad "Run1 raw claude ran: $(cat "$R/claude.log")"
grep -q 'CLAUDE AUTH DOWN\|INCONCLUSIVE' "$R/logs/ALERTS.log" && bad "Run1 alerted: $(cat "$R/logs/ALERTS.log")" || ok

# ---- Run 2: ALIVE, claim spent ------------------------------------------------
run2() { build_tree "$1"; spend_claim "$1"; run_check "$1" STUB_EP="ALIVE 200"; }
R="$T/r2"; run2 "$R"
[ "$(lines "$R/ac.log")" = 0 ] && ok || bad "Run2 spent with the claim taken: $(cat "$R/ac.log")"
[ "$(lines "$R/claude.log")" = 0 ] && ok || bad "Run2 raw claude ran: $(cat "$R/claude.log")"
[ "$(lines "$R/records")" = 0 ] && ok || bad "Run2 recorded: $(cat "$R/records")"

# ---- Run 3: DEAD 401 ------------------------------------------------------------
R="$T/r3"; build_tree "$R"; spend_claim "$R"
run_check "$R" STUB_EP="DEAD 401"
grep -qx hub "$R/state/claude-auth-down.txt" && ok || bad "Run3 hub not in STATE: $(cat "$R/state/claude-auth-down.txt")"
[ "$(cnt "$R/logs/ALERTS.log" '\] hub CLAUDE AUTH DOWN')" = 1 ] && ok || bad "Run3 DOWN lines: $(cat "$R/logs/ALERTS.log")"
grep -q '\] hub CLAUDE AUTH DOWN: DEAD 401' "$R/logs/ALERTS.log" && ok || bad "Run3 snippet: $(cat "$R/logs/ALERTS.log")"

# ---- Run 4: INCONCLUSIVE 429 -----------------------------------------------------
R="$T/r4"; build_tree "$R"; spend_claim "$R"
run_check "$R" STUB_EP="INCONCLUSIVE 429"
[ "$(cnt "$R/logs/ALERTS.log" 'hub AUTH PROBE INCONCLUSIVE')" = 1 ] && ok || bad "Run4 note: $(cat "$R/logs/ALERTS.log")"
grep -q 'hub CLAUDE AUTH DOWN' "$R/logs/ALERTS.log" && bad "Run4 paged DOWN on a 429" || ok
grep -qx hub "$R/state/claude-auth-down.txt" && bad "Run4 hub in STATE" || ok

# ---- Run 5: ALIVE alone never clears the conductor marker --------------------------
R="$T/r5"; build_tree "$R"; spend_claim "$R"
mkdir -p "$R/state/merge-conductor"; echo 'HTTP 429' > "$R/state/merge-conductor/lane-down"
run_check "$R" STUB_EP="ALIVE 200"
[ -e "$R/state/merge-conductor/lane-down" ] && ok || bad "Run5 an endpoint ALIVE removed the conductor marker"

# ---- A6: the 6-hourly runner loop --------------------------------------------------
R="$T/a6"; build_tree "$R" 06; spend_claim "$R"
echo 'INCONCLUSIVE 429' > "$R/probe-grok"
echo 'DEAD 401' > "$R/probe-codex"
echo 'ALIVE 200' > "$R/probe-openrouter"
printf 'NO_ENDPOINT\n' > "$R/probe-fireworks"
run_check "$R" STUB_EP="ALIVE 200"
grep -qx 'codex --endpoint' "$R/probe-calls.txt" 2>/dev/null && ok || bad "A6 lane-probe not asked for --endpoint: $(cat "$R/probe-calls.txt" 2>/dev/null)"
[ -e "$R/state/lane-down/hub-codex" ] && ok || bad "A6 DEAD codex not marked: $(cat "$R/logs/ALERTS.log")"
[ -e "$R/state/lane-down/hub-grok" ] && bad "A6 INCONCLUSIVE grok marked down" || ok
grep -qx hub-grok "$R/state/claude-auth-down.txt" && bad "A6 grok STATE line" || ok
[ -e "$R/state/lane-down/hub-openrouter" ] && bad "A6 ALIVE openrouter marked down" || ok
[ -e "$R/state/lane-down/hub-fireworks" ] && bad "A6 NO_ENDPOINT without inference marked down" || ok

# ---- A7: NO_ENDPOINT, claim spent: nothing ------------------------------------------
R="$T/a7"; build_tree "$R"; spend_claim "$R"
cp "$R/state/claude-auth-down.txt" "$R/state.before"
run_check "$R" STUB_EP="NO_ENDPOINT"
cmp -s "$R/state.before" "$R/state/claude-auth-down.txt" && ok || bad "A7 STATE changed: $(cat "$R/state/claude-auth-down.txt")"
[ -s "$R/logs/ALERTS.log" ] && bad "A7 ALERTS written: $(cat "$R/logs/ALERTS.log")" || ok
[ -s "$R/beats.txt" ] && bad "A7 beat: $(cat "$R/beats.txt")" || ok
[ "$(lines "$R/ac.log")" = 0 ] && ok || bad "A7 spent: $(cat "$R/ac.log")"

# ---- A8: DEGRADED endpoint -----------------------------------------------------------
R="$T/a8"; build_tree "$R"; spend_claim "$R"
run_check "$R" STUB_EP="DEGRADED limit_remaining=0"
[ "$(cnt "$R/logs/ALERTS.log" 'hub MODEL POOL EXHAUSTED')" = 1 ] && ok || bad "A8 degraded note: $(cat "$R/logs/ALERTS.log")"
grep -q 'hub CLAUDE AUTH DOWN' "$R/logs/ALERTS.log" && bad "A8 DEGRADED paged DOWN" || ok

# ---- A9: inference refused (rc 74) ----------------------------------------------------
R="$T/a9"; build_tree "$R"
run_check "$R" STUB_EP="NO_ENDPOINT" STUB_AC_MODE=refuse
[ "$(lines "$R/ac.log")" -ge 1 ] && ok || bad "A9 agent-call not reached"
grep -q 'hub CLAUDE AUTH DOWN' "$R/logs/ALERTS.log" && bad "A9 a refusal paged DOWN: $(cat "$R/logs/ALERTS.log")" || ok
[ "$(lines "$R/records")" = 0 ] && ok || bad "A9 a refused (unbilled) call was recorded: $(cat "$R/records")"

# ---- A10: a remote box gets lane-probe.sh claude --endpoint over ssh --------------------
R="$T/a10"; build_tree "$R"; spend_claim "$R"
printf '#!/bin/bash\ncase "$1" in --projects) echo p1 ;; --tailnet-ip-of-box) echo 192.0.2.7 ;; esac\n' > "$R/bin/fleet-conf.sh"
printf '#!/bin/bash\necho box-b1\n' > "$R/bin/box-for.sh"
run_check "$R" STUB_EP="ALIVE 200"
grep -q 'root@192.0.2.7 /root/harness/bin/lane-probe.sh claude --endpoint' "$R/ssh.log" 2>/dev/null && ok || bad "A10 ssh argv: $(cat "$R/ssh.log" 2>/dev/null)"
grep -q 'claude -p' "$R/ssh.log" 2>/dev/null && bad "A10 a raw claude -p went over ssh" || ok

# ---- A11: ALIVE clears a standing hub outage ----------------------------------------------
R="$T/a11"; build_tree "$R"; spend_claim "$R"
echo hub >> "$R/state/claude-auth-down.txt"
run_check "$R" STUB_EP="ALIVE 200"
grep -qx hub "$R/state/claude-auth-down.txt" && bad "A11 hub still in STATE" || ok
[ "$(cnt "$R/logs/ALERTS.log" '\] hub RECOVERED')" = 1 ] && ok || bad "A11 RECOVERED: $(cat "$R/logs/ALERTS.log")"

# ---- A12: NO_ENDPOINT + inference PROBE_OK clears the conductor marker ---------------------
R="$T/a12"; build_tree "$R"
mkdir -p "$R/state/merge-conductor"; echo 'HTTP 429' > "$R/state/merge-conductor/lane-down"
run_check "$R" STUB_EP="NO_ENDPOINT"
[ -e "$R/state/merge-conductor/lane-down" ] && bad "A12 inference ok did not clear the marker: $(cat "$R/out.txt")" || ok

# ---- A13: ALIVE, but the inference is logged out: the end-to-end evidence wins -------------
R="$T/a13"; build_tree "$R"
run_check "$R" STUB_EP="ALIVE 200" STUB_AC_MODE=loggedout
grep -qx hub "$R/state/claude-auth-down.txt" && ok || bad "A13 hub not down: $(cat "$R/logs/ALERTS.log")"
[ "$(cat "$R/records" 2>/dev/null)" = "claude fp1 down" ] && ok || bad "A13 record: $(cat "$R/records" 2>/dev/null)"

# ---- M: the claim forced to 0 turns Run 2 red ----------------------------------------------
R="$T/m"; build_tree "$R"; spend_claim "$R"
sed -i 's/&& return 1$/\&\& return 0/' "$R/credlib.sh"
if grep -q '&& return 0$' "$R/credlib.sh"; then
  run_check "$R" STUB_EP="ALIVE 200"
  [ "$(lines "$R/ac.log")" -ge 1 ] && ok || bad "M a claim that always says spend did not spend, so Run 2 proves nothing"
else bad "M mutation did not apply"; fi

echo "auth-check-no-inference: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
