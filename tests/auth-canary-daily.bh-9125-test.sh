#!/bin/bash
# tests/auth-canary-daily.bh-9125-test.sh — BH-9125 (BH-9064.3, slice C3): the
# auth canary runs on model_routes role `auth.canary`, once per account per UTC
# day. Its daily inference carries AGENT_CALL_FP=canary:<runner>:<account>:<day>,
# so a repeat inside the day is a ledger hit (a replay, no vendor call). The
# ledger keeps the answer of that fp for AGENT_LEDGER_CANARY_WINDOW_S (86400),
# not for the hour of AGENT_LEDGER_WINDOW_S.
#
# Two worlds, both on the production entry points:
#   A  the REAL bin/lane-probe.sh and the REAL PROBE_BODY of
#      bin/claude-auth-check.sh, through the REAL bin/agent-call.sh, a fake
#      `claude` that counts its calls, and the REAL jobs worker ledger route on a
#      node:sqlite file (tests/lib/ledger-worker-fake.bh-9064.sh). The day claim
#      always answers rc 0 (a box whose claim fails open), so the ledger is the
#      only thing that can stop the second purchase.
#   B  the REAL bin/claude-auth-check.sh and bin/lane-probe.sh with a stub
#      agent-call.sh that records its argv and AGENT_CALL_FP, and the REAL
#      bin/lib/lane-model.sh + model-route.sh against a fake model_routes worker
#      (tests/lib/model-route-stub.sh).
#
#   C1  two `lane-probe.sh claude --endpoint` runs, one account, one day: 1 call,
#       1 row fp canary:claude:<acct>:<today>, ok, attempts=1
#   C2  two hub PROBE_BODY runs with AUTH_CANARY_FP, the 2nd one 2 h later: 1
#       call, PROBE_OK both times, 1 LEDGER REPLAY line
#   C3  lane-probe default mode (lane-reprobe): 2 runs = 2 calls, no canary: row
#   C4  the hub probe asks the auth.canary route; AUTH_CANARY_MODEL wins;
#       TRIAGE_MODEL is ignored
#   C5  lane-probe claude asks auth.canary; codex still asks codex.default
#   C6  no auth.canary route: the probe runs on triage, 1 ALERTS line names
#       auth.canary; no route at all: rc 75, no probe
#   C7  the day fp rides only after a claim rc 0 with an account fp
#   C8  acl_precall's window: canary + caller fp = AGENT_LEDGER_CANARY_WINDOW_S,
#       every other row = AGENT_LEDGER_WINDOW_S
#   C9  two accounts on one day: 2 calls, 2 rows
#   C10 yesterday's ok row: today's probe makes 1 call
#   C11 a failed row at the cap for today's fp: 0 calls, AGENT_CALL_REFUSED in
#       the output, no cred_inference_record
#   C12 the ledger down: 2 probes = 2 calls (fail open)
#   C13 the credits fallback rung (auth.fallback) carries no day fp: under the
#       same fp the ledger would replay the primary answer to it
#
# Run from anywhere: tests/auth-canary-daily.bh-9125-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/model-route-stub.sh" || exit 1
. "$(dirname "$0")/lib/ledger-worker-fake.bh-9064.sh" || exit 1
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v node >/dev/null || { echo "node missing — skipping"; exit 0; }
node -e 'require("node:sqlite")' 2>/dev/null || { echo "node:sqlite missing — skipping"; exit 0; }
# The worker imports the git-ignored catalogs (CI renders them first; BH-6540).
[ -r "$DIR/catalog/lanes.json" ] || (cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/lanes-build.sh --write >/dev/null 2>&1)
[ -r "$DIR/catalog/llm-sites.json" ] || (cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/llm-sites-build.sh --compose >/dev/null 2>&1)
# TEST-CHANGE BH-6052: the code and this suite both read the UTC day, so start
# well inside one day (the suite runs about 30 s).
clear_boundary 86400 180 || exit 1
TODAY=$(date -u +%F)
YDAY=$(date -u -d 'yesterday' +%F)
REAL_DATE=$(command -v date)

# ═══ World A: the real agent-call and the real ledger route ══════════════════
A="$T/a"
mkdir -p "$A/bin/lib/jobs" "$A/fakebin" "$A/flags" "$A/locks" "$A/logs" "$A/state" "$A/env"
: > "$A/env/global.env"
model_routes_fixture "$A" || { echo "FAIL: model_routes_fixture"; exit 1; }
# agent-call.sh loads its libs from its own directory, so it runs from a copy
# with its whole closure (PROBE_BODY and lane-probe.sh call $HARNESS/bin/agent-call.sh).
( cd "$DIR" && scratch_install_closure bin/jobs-client.sh "$A" ) >/dev/null || { echo "FAIL: closure of bin/jobs-client.sh"; exit 1; }
( cd "$DIR" && scratch_install_closure bin/agent-call.sh "$A" ) >/dev/null || { echo "FAIL: closure of bin/agent-call.sh"; exit 1; }
( cd "$DIR" && scratch_install_closure bin/billing-mode.sh "$A" ) >/dev/null || { echo "FAIL: closure of bin/billing-mode.sh"; exit 1; }
lwf_install "$A/fakebin" "$A/jobs.db"
# The model the auth.canary route answers on this seed (bootstrap.smoke rung 0).
CANARY_M=$(awk -F'\t' '$1==0{print $2; exit}' "$A/state/model-routes/bootstrap.smoke.tsv")
[ -n "$CANARY_M" ] || { echo "FAIL: the seed has no bootstrap.smoke rung 0"; exit 1; }

# The fake vendor: it counts its calls, answers `ok` to the lane-probe prompt and
# AUTHPROBE-<code> to the hub prompt. An argv it does not know is exit 99.
cat > "$A/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$ORDER_SINK"
case " $* " in *" -p "*|*" --print "*) ;; *) echo "fake claude: unknown argv $*" >&2; exit 99 ;; esac
ALL="$*"; [ -t 0 ] || ALL="$ALL $(cat)"
CODE=$(printf '%s' "$ALL" | grep -oE 'code [0-9a-f]+' | head -1 | awk '{print $2}')
if [ -n "$CODE" ]; then R="AUTHPROBE-$CODE"; else R=ok; fi
echo "{\"result\":\"$R\",\"usage\":{\"input_tokens\":10,\"output_tokens\":2},\"total_cost_usd\":0.01}"
EOF
cat > "$A/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\nexit 0\n' > "$A/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$A/bin/sync-agent-rules.sh"
# The credential lib of a box whose day claim fails open: the claim is always 0.
cat > "$A/credlib.sh" <<'EOF'
cred_probe() { echo NO_ENDPOINT; return 4; }
cred_account_fp() { [ -n "${CASE_FP:-}" ] && echo "$CASE_FP"; }
cred_inference_claim() { printf '%s\n' "$*" >> "$RECORDS.claims"; return 0; }
cred_inference_record() { printf '%s\n' "$*" >> "$RECORDS"; }
EOF
chmod +x "$A/fakebin/"* "$A/bin/"*.sh

LOG="$A/logs/agent-call-ledger.log"
# aenv: the env of every world-A run (no real key, no real worker).
aenv() {
  env -u AGENT_CALL_FP -u AUTH_CANARY_FP -u AUTH_CANARY_MODEL -u TRIAGE_MODEL -u AGENT_LEDGER_WINDOW_S \
    -u AGENT_LEDGER_CANARY_WINDOW_S -u AGENT_CALL_TICKET -u HARNESS_TICKET \
    ORDER_SINK="$A/order" PATH="$A/fakebin:$PATH" HARNESS="$A" HOME="$A" HARNESS_ENV_DIR="$A/env" \
    JOBS_URL="https://jobs.test" HARNESS_SECRET="tok-fixture-bh9125" LWF_SECRET="tok-fixture-bh9125" \
    JOBS_RETRIES=0 JOBS_BOX=testbox CRED_PROBE_LIB="$A/credlib.sh" RECORDS="$A/records" \
    CLAUDE_CODE_OAUTH_TOKEN=tok-fixture ANTHROPIC_API_KEY= \
    OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= OPENAI_API_KEY= \
    LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 \
    AGENT_CALL_LEDGER=0 CALL_GUARD_MAX_MAP="default=50" \
    LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 \
    CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" "$@"
}
# lp [VAR=VAL ...] -- <lane-probe args>: the real bin/lane-probe.sh; stdout only.
lp() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  aenv "${envs[@]}" bash "$DIR/bin/lane-probe.sh" "$@" 2>/dev/null
}
# hub [VAR=VAL ...]: the real PROBE_BODY of bin/claude-auth-check.sh. Library
# mode resolves no route, so the model comes from AUTH_CANARY_MODEL.
hub() {
  aenv AUTH_CHECK_LIB=1 "$@" bash -c '. "$1/bin/claude-auth-check.sh"; bash -c "$PROBE_BODY"' _ "$DIR" 2>/dev/null
}
reset() { : > "$A/order"; : > "$LOG"; : > "$A/records"; : > "$A/records.claims"; }
calls() { grep -c . "$A/order" 2>/dev/null || true; }
row() { # row <fp> -> "status attempts"
  lwf_sql "SELECT status, attempts FROM agent_call_ledger WHERE project='fleet' AND stage='canary' AND fp=?" "$1" \
    | jq -r '"\(.status) \(.attempts)"'
}
nrows_like() { lwf_sql "SELECT COUNT(*) AS n FROM agent_call_ledger WHERE fp LIKE ?" "$1" | jq -r .n; }
seed() { # seed <fp> <status> <attempts> <rc|null> [body]
  local body="${5:-}"
  lwf_sql "INSERT OR REPLACE INTO agent_call_ledger (project,stage,fp,status,attempts,rc,answer_body,answer_bytes,runner,model,first_at,last_at)
           VALUES ('fleet','canary',?,?,?,${4},?,?,'claude',?,strftime('%Y-%m-%dT%H:%M:%SZ','now'),strftime('%Y-%m-%dT%H:%M:%SZ','now'))" \
    "$1" "$2" "$3" "$body" "${#body}" "$CANARY_M"
}
loglines() { grep -cF "$1" "$LOG" 2>/dev/null || true; }

# --- C1. two lane-probe --endpoint runs, one account, one day: 1 call -------
reset
o1=$(lp CASE_FP=fp-c1 -- claude --endpoint)
o2=$(lp CASE_FP=fp-c1 -- claude --endpoint)
[ "$(calls)" = 1 ] && ok || bad "C1a two probes on one day made $(calls) model calls, want 1 (log: $(cat "$LOG"))"
[ "$(row "canary:claude:fp-c1:$TODAY")" = "ok 1" ] && ok \
  || bad "C1b ledger row canary:claude:fp-c1:$TODAY is '$(row "canary:claude:fp-c1:$TODAY")', want 'ok 1' (rows: $(lwf_sql "SELECT fp, status, attempts FROM agent_call_ledger" | tr '\n' ' '))"
grep -qx ok <<<"$(sed '1,/^INFERENCE$/d' <<<"$o1")" && ok || bad "C1c the first probe did not print ok: $o1"
grep -qx ok <<<"$(sed '1,/^INFERENCE$/d' <<<"$o2")" && ok || bad "C1d the second probe did not print ok: $o2"
[ "$(grep -c "claude fp-c1 ok" "$A/records")" = 2 ] && ok || bad "C1e records: $(cat "$A/records")"

# --- C2. two hub PROBE_BODY runs with the day fp, 2 h apart: 1 call ---------
reset
FP2="canary:claude:fp-c2:$TODAY"
h1=$(hub AUTH_CANARY_FP="$FP2" AUTH_CANARY_MODEL="$CANARY_M")
lwf_sql "UPDATE agent_call_ledger SET last_at=strftime('%Y-%m-%dT%H:%M:%SZ','now','-7200 seconds') WHERE fp=?" "$FP2" >/dev/null
h2=$(hub AUTH_CANARY_FP="$FP2" AUTH_CANARY_MODEL="$CANARY_M")
[ "$(calls)" = 1 ] && ok || bad "C2a two hub probes 2 h apart made $(calls) model calls, want 1 (log: $(cat "$LOG"))"
case "$h1" in "PROBE_OK "*) ok ;; *) bad "C2b run 1: $h1" ;; esac
case "$h2" in "PROBE_OK "*) ok ;; *) bad "C2c the replayed answer failed the sentinel check: $h2" ;; esac
[ "$(loglines "LEDGER REPLAY fp=$FP2")" = 1 ] && ok || bad "C2d LEDGER REPLAY lines for $FP2: $(loglines "LEDGER REPLAY fp=$FP2") ($(cat "$LOG"))"
[ "$(row "$FP2")" = "ok 1" ] && ok || bad "C2e ledger row $FP2 is '$(row "$FP2")', want 'ok 1'"

# --- C3. default mode (lane-reprobe) keeps no fp: 2 runs = 2 calls ----------
reset
lp CASE_FP=fp-c3 -- claude >/dev/null
lp CASE_FP=fp-c3 -- claude >/dev/null
[ "$(calls)" = 2 ] && ok || bad "C3a default mode made $(calls) calls, want 2 (a reprobe needs fresh evidence)"
[ "$(nrows_like "canary:%:fp-c3:%")" = 0 ] && ok || bad "C3b default mode wrote a canary: fp row"

# --- C9. two accounts on one day: 2 calls, 2 rows ----------------------------
reset
lp CASE_FP=fp-c9a -- claude --endpoint >/dev/null
lp CASE_FP=fp-c9b -- claude --endpoint >/dev/null
[ "$(calls)" = 2 ] && ok || bad "C9a two accounts made $(calls) calls, want 2"
[ "$(row "canary:claude:fp-c9a:$TODAY")" = "ok 1" ] && [ "$(row "canary:claude:fp-c9b:$TODAY")" = "ok 1" ] && ok \
  || bad "C9b rows: '$(row "canary:claude:fp-c9a:$TODAY")' '$(row "canary:claude:fp-c9b:$TODAY")'"

# --- C10. yesterday's ok row is another key: today makes 1 call -------------
reset
seed "canary:claude:fp-c10:$YDAY" ok 1 0 "ok" >/dev/null
lp CASE_FP=fp-c10 -- claude --endpoint >/dev/null
[ "$(calls)" = 1 ] && ok || bad "C10a yesterday's row answered today's probe ($(calls) calls, want 1)"
[ "$(row "canary:claude:fp-c10:$TODAY")" = "ok 1" ] && ok || bad "C10b today's row: '$(row "canary:claude:fp-c10:$TODAY")'"

# --- C11. a failed row at the cap: 0 calls, refused, nothing recorded -------
reset
seed "canary:claude:fp-c11:$TODAY" failed 3 1 >/dev/null
# The cap of a stage is never below its K3 ceiling (acl_max_attempts), so
# this case sets the ceiling to 3: 3 failed attempts are then terminal.
o=$(lp CALL_GUARD_MAX_MAP="default=3" CASE_FP=fp-c11 -- claude --endpoint)
[ "$(calls)" = 0 ] && ok || bad "C11a a terminal failed row still bought $(calls) calls"
grep -q 'AGENT_CALL_REFUSED' <<<"$o" && ok || bad "C11b no AGENT_CALL_REFUSED in the probe output: $o"
[ -s "$A/records" ] && bad "C11c a refused probe was recorded: $(cat "$A/records")" || ok

# --- C12. the ledger down: fail open, 2 probes = 2 calls ---------------------
reset
lp LWF_MODE=down CASE_FP=fp-c12 -- claude --endpoint >/dev/null
lp LWF_MODE=down CASE_FP=fp-c12 -- claude --endpoint >/dev/null
[ "$(calls)" = 2 ] && ok || bad "C12 the ledger down: $(calls) calls, want 2 (fail open)"

# --- C8. acl_precall's window table -------------------------------------------
# A stub acl_req_begin records the window it is sent; the real acl_precall picks it.
c8() { # c8 <stage> <fp-or-empty> [VAR=VAL ...] -> the window_s sent
  local st="$1" fp="$2"; shift 2
  env -u AGENT_LEDGER_WINDOW_S -u AGENT_LEDGER_CANARY_WINDOW_S -u AGENT_CALL_GUARD_STAGE \
    HARNESS="$A" JOBS_URL=https://jobs.test AGENT_LEDGER=1 AGENT_LEDGER_STAGES=all AGENT_CALL_FP="$fp" "$@" \
    C8OUT="$A/c8.out" bash -c '. "$1/bin/lib/agent-call-ledger.sh"
      acl_req_begin() { printf "%s\n" "$5" > "$C8OUT"; echo "{\"decision\":\"run\"}"; }
      rm -f "$C8OUT"; acl_precall "$2" fleet psha0123456789 >/dev/null; cat "$C8OUT"' _ "$DIR" "$st"
}
w=$(c8 canary "canary:claude:fp1:$TODAY");                   [ "$w" = 86400 ] && ok || bad "C8a canary + caller fp: window $w, want 86400"
w=$(c8 canary "canary:claude:fp1:$TODAY" AGENT_LEDGER_CANARY_WINDOW_S=7200); [ "$w" = 7200 ] && ok || bad "C8b the knob: window $w, want 7200"
w=$(c8 canary "canary:codex:fpC:$TODAY");                    [ "$w" = 86400 ] && ok || bad "C8c canary + other runner: window $w, want 86400"
w=$(c8 canary "");                                            [ "$w" = 3600 ] && ok || bad "C8d canary + computed fp: window $w, want 3600"
w=$(c8 review "canary:claude:fp1:$TODAY");                    [ "$w" = 3600 ] && ok || bad "C8e review + caller fp: window $w, want 3600"
w=$(c8 execute "BH-1:abc");                                   [ "$w" = 3600 ] && ok || bad "C8f execute + caller fp: window $w, want 3600"
w=$(c8 canary-x "canary:claude:fp1:$TODAY");                  [ "$w" = 3600 ] && ok || bad "C8g stage canary-x: window $w, want 3600"
w=$(c8 canary "" AGENT_LEDGER_WINDOW_S=1800);                 [ "$w" = 1800 ] && ok || bad "C8h the hour knob still applies to a computed fp: window $w, want 1800"

# ═══ World B: route resolution on the real scripts, a stub agent-call ════════
# build_b <root>: the real claude-auth-check.sh and lane-probe.sh, the real
# lane-model.sh + model-route.sh, a fake model_routes worker, a stub agent-call.
# The stubs are written first: scratch_install_closure keeps a file already there.
BT="$T/b-template"
mkdir -p "$BT/bin/lib"
printf '#!/bin/bash\nexit 0\n' > "$BT/bin/fleet-conf.sh"
printf '#!/bin/bash\nexit 0\n' > "$BT/bin/box-for.sh"
printf '#!/bin/bash\nexit 0\n' > "$BT/bin/beat.sh"
cat > "$BT/bin/agent-call.sh" <<'SH'
#!/bin/bash
# argv: <stage> <project> <model> <timeout> <outfile> <prompt>
R=$(dirname "$0")/..
printf '%s\n' "$*" >> "$R/ac.log"
printf 'AGENT_CALL_FP=%s\n' "${AGENT_CALL_FP:-}" >> "$R/ac.fp"
if [ "${STUB_CREDITS:-}" = "$3" ]; then printf 'Claude AI usage credits exhausted for this model\n' | tee "$5.err" > "$5"; exit 1; fi
CODE=$(printf '%s' "$6" | grep -oE 'code [0-9a-f]+' | awk '{print $2}' | head -1)
if [ -n "$CODE" ]; then printf 'AUTHPROBE-%s\n' "$CODE" > "$5"; else printf 'ok\n' > "$5"; fi
echo "$3" > "$5.model"
SH
for s in bin/claude-auth-check.sh bin/lane-probe.sh bin/jobs-client.sh bin/lib/lane-model.sh bin/lib/model-route.sh; do
  ( cd "$DIR" && scratch_install_closure "$s" "$BT" ) >/dev/null || { echo "FAIL: closure of $s"; exit 1; }
done
build_b() {
  local R="$1"
  scratch_rm "$R"; mkdir -p "$R"; cp -a "$BT/." "$R/"
  mkdir -p "$R/fakebin" "$R/state" "$R/flags" "$R/logs" "$R/locks" "$R/env" "$R/routes"
  : > "$R/env/global.env"
  printf '#!/bin/bash\necho "$*" >> "%s/claude.log"\nexit 99\n' "$R" > "$R/fakebin/claude"
  printf '#!/bin/bash\nexit 1\n' > "$R/fakebin/ssh"
  # hour 01: the 6-hourly runner loop (other lanes, other routes) stays out of it
  cat > "$R/fakebin/date" <<SH
#!/bin/bash
for a in "\$@"; do [ "\$a" = "+%H" ] && { echo 01; exit 0; }; done
exec $REAL_DATE "\$@"
SH
  cat > "$R/credlib.sh" <<SH
cred_probe() { echo "\${STUB_EP:-NO_ENDPOINT}"; }
cred_account_fp() { [ -n "\${CASE_FP-fp1}" ] && echo "\${CASE_FP-fp1}"; }
cred_inference_claim() { printf '%s\\n' "\$*" >> "$R/claims"; return "\${STUB_CLAIM_RC:-0}"; }
cred_inference_record() { printf '%s\\n' "\$*" >> "$R/records"; }
SH
  mrs_install "$R/fakebin"
  mrs_route "$R/routes" auth.canary m-auth.canary:claude
  mrs_route "$R/routes" triage m-triage:claude
  mrs_route "$R/routes" auth.fallback m-auth.fallback:claude
  mrs_route "$R/routes" codex.default m-codex.default:codex
  chmod +x "$R"/bin/*.sh "$R"/fakebin/*
  echo project-1-lane > "$R/state/claude-auth-down.txt"
  : > "$R/logs/ALERTS.log"
}
benv() { # benv <root> [VAR=VAL ...] -- <cmd...>
  local R="$1"; shift
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  env -u AUTH_CANARY_MODEL -u TRIAGE_MODEL -u AUTH_FALLBACK_MODEL -u AUTH_CANARY_FP -u CODEX_MODEL \
    HARNESS="$R" HARNESS_ENV_DIR="$R/env" PATH="$R/fakebin:$PATH" CRED_PROBE_LIB="$R/credlib.sh" \
    MRS_ROUTES="$R/routes" JOBS_URL=https://jobs.invalid HARNESS_SECRET=tok-fixture-bh9125 JOBS_RETRIES=0 \
    "${envs[@]}" "$@"
}
check() { local R="$1"; shift; benv "$R" "$@" -- bash "$R/bin/claude-auth-check.sh" >"$R/out.txt" 2>&1; echo $? > "$R/rc"; }
alines() { grep -c "$2" "$1/logs/ALERTS.log" 2>/dev/null || true; }

# --- C4. the hub probe asks auth.canary; AUTH_CANARY_MODEL wins; TRIAGE_MODEL is ignored
R="$T/c4"; build_b "$R"; check "$R" STUB_EP="ALIVE 200"
grep -q '^canary fleet m-auth.canary 90 ' "$R/ac.log" 2>/dev/null && ok || bad "C4a hub argv: $(cat "$R/ac.log" 2>/dev/null) $(cat "$R/out.txt")"
grep -q ' m-triage ' "$R/ac.log" 2>/dev/null && bad "C4b the hub probe still ran on the triage route" || ok
R="$T/c4x"; build_b "$R"; check "$R" STUB_EP="ALIVE 200" AUTH_CANARY_MODEL=m-x TRIAGE_MODEL=m-y
grep -q '^canary fleet m-x 90 ' "$R/ac.log" 2>/dev/null && ok || bad "C4c AUTH_CANARY_MODEL did not win: $(cat "$R/ac.log" 2>/dev/null)"
grep -q ' m-y ' "$R/ac.log" 2>/dev/null && bad "C4d TRIAGE_MODEL still steers the canary" || ok

# --- C7. the day fp rides only after a claim rc 0 with an account fp ---------
R="$T/c7"; build_b "$R"; check "$R" STUB_EP="ALIVE 200"
grep -qx "AGENT_CALL_FP=canary:claude:fp1:$TODAY" "$R/ac.fp" 2>/dev/null && ok || bad "C7a hub fp: $(cat "$R/ac.fp" 2>/dev/null)"
R="$T/c7b"; build_b "$R"; check "$R" STUB_EP="ALIVE 200" STUB_CLAIM_RC=1
[ -s "$R/ac.log" ] && bad "C7b claim rc 1 still called agent-call: $(cat "$R/ac.log")" || ok
R="$T/c7c"; build_b "$R"; check "$R" STUB_EP="ALIVE 200" CASE_FP=
[ -s "$R/ac.fp" ] && ! grep -qv '^AGENT_CALL_FP=$' "$R/ac.fp" && ok || bad "C7c an empty account fp still named a caller fp: $(cat "$R/ac.fp" 2>/dev/null)"
R="$T/c7d"; build_b "$R"
benv "$R" CASE_FP=fpC -- bash "$R/bin/lane-probe.sh" --endpoint codex >/dev/null 2>&1
grep -qx "AGENT_CALL_FP=canary:codex:fpC:$TODAY" "$R/ac.fp" 2>/dev/null && ok || bad "C7d lane-probe --endpoint codex fp: $(cat "$R/ac.fp" 2>/dev/null)"
R="$T/c7e"; build_b "$R"
benv "$R" CASE_FP=fpC -- bash "$R/bin/lane-probe.sh" claude >/dev/null 2>&1
grep -qx "AGENT_CALL_FP=" "$R/ac.fp" 2>/dev/null && ok || bad "C7e default mode named a caller fp: $(cat "$R/ac.fp" 2>/dev/null)"

# --- C13. the fallback rung never carries the day fp (a different purchase) --
R="$T/c13"; build_b "$R"; check "$R" STUB_EP="ALIVE 200" STUB_CREDITS=m-auth.canary
[ "$(sed -n 1p "$R/ac.fp" 2>/dev/null)" = "AGENT_CALL_FP=canary:claude:fp1:$TODAY" ] && ok || bad "C13a primary fp: $(cat "$R/ac.fp" 2>/dev/null)"
grep -q '^canary fleet m-auth.fallback 90 ' "$R/ac.log" 2>/dev/null && [ "$(sed -n 2p "$R/ac.fp" 2>/dev/null)" = "AGENT_CALL_FP=" ] && ok \
  || bad "C13b the fallback rung: argv $(cat "$R/ac.log" 2>/dev/null) fp $(cat "$R/ac.fp" 2>/dev/null)"

# --- C5. lane-probe claude asks auth.canary; codex is unchanged --------------
R="$T/c5"; build_b "$R"
benv "$R" -- bash "$R/bin/lane-probe.sh" claude >/dev/null 2>&1
grep -q '^canary fleet m-auth.canary 120 ' "$R/ac.log" 2>/dev/null && ok || bad "C5a lane-probe claude argv: $(cat "$R/ac.log" 2>/dev/null)"
benv "$R" -- bash "$R/bin/lane-probe.sh" codex >/dev/null 2>&1
grep -q '^canary fleet m-codex.default 120 ' "$R/ac.log" 2>/dev/null && ok || bad "C5b lane-probe codex argv: $(cat "$R/ac.log" 2>/dev/null)"
benv "$R" AUTH_CANARY_MODEL=m-x TRIAGE_MODEL=m-y -- bash "$R/bin/lane-probe.sh" claude >/dev/null 2>&1
grep -q '^canary fleet m-x 120 ' "$R/ac.log" 2>/dev/null && ok || bad "C5c AUTH_CANARY_MODEL did not win in lane-probe: $(cat "$R/ac.log" 2>/dev/null)"

# --- C6. no auth.canary route: triage + 1 ALERTS line; no route at all: rc 75
R="$T/c6"; build_b "$R"; rm -f "$R/routes/auth.canary.json"; check "$R" STUB_EP="ALIVE 200"
[ "$(cat "$R/rc")" = 0 ] && grep -q '^canary fleet m-triage 90 ' "$R/ac.log" 2>/dev/null && ok \
  || bad "C6a no auth.canary route: rc $(cat "$R/rc") argv $(cat "$R/ac.log" 2>/dev/null)"
[ "$(alines "$R" 'auth.canary')" = 1 ] && ok || bad "C6b ALERTS lines naming auth.canary: $(cat "$R/logs/ALERTS.log")"
R="$T/c6x"; build_b "$R"; rm -f "$R/routes/auth.canary.json" "$R/routes/triage.json"; check "$R" STUB_EP="ALIVE 200"
[ "$(cat "$R/rc")" = 75 ] && [ ! -s "$R/ac.log" ] && ok || bad "C6c no route at all: rc $(cat "$R/rc"), argv $(cat "$R/ac.log" 2>/dev/null)"
R="$T/c6l"; build_b "$R"; rm -f "$R/routes/auth.canary.json"
benv "$R" -- bash "$R/bin/lane-probe.sh" claude >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^canary fleet m-triage 120 ' "$R/ac.log" 2>/dev/null && ok || bad "C6d lane-probe with no auth.canary route: rc $rc argv $(cat "$R/ac.log" 2>/dev/null)"
R="$T/c6m"; build_b "$R"; rm -f "$R/routes/auth.canary.json" "$R/routes/triage.json"
benv "$R" -- bash "$R/bin/lane-probe.sh" claude >/dev/null 2>&1; rc=$?
[ "$rc" = 75 ] && [ ! -s "$R/ac.log" ] && ok || bad "C6e lane-probe with no route at all: rc $rc"

echo "auth-canary-daily.bh-9125: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
