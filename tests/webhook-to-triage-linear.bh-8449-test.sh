#!/bin/bash
# tests/webhook-to-triage-linear.bh-8449-test.sh — BH-8449 (C1 of #7920): a
# signed Linear delivery reaches a triage tick, end to end, with no network.
# (The ticket names this suite webhook-to-triage-linear.bh-7920-test.sh; it
# carries this build's key by the test-ownership rule.)
#
#   stage 1  the REAL jobs worker (tests/lib/linear-wake-worker.bh-8449.mjs:
#            worker/jobs/src/index.js on node:sqlite) takes one signed
#            delivery on POST /webhooks/linear and writes the wakes table
#   stage 2  the REAL bin/wake-loop.sh (WAKE_LOOP_CYCLES=1) claims those rows
#            through tests/lib/wake-claim-stub.sh and launches a recording
#            run-triage.sh. Its curl answers the wake routes first, then
#            tests/lib/linear-stub.bh-7920.sh (Linear and the settings rows)
#   stage 3  the REAL bin/triage-gate.sh crolin --pending on the Linear stub
#
#   W1  CRO-12 with the row webhook_route.linear.cro: exactly 1 wake row,
#       repo o/crolin, kind issue, key CRO-12
#   W2  ENG-4 (no webhook_route.linear.eng row): 0 wake rows
#   W3  a wrong signature: 0 rows (the stage uses the real verifier)
#   W4  wake-loop on the W1 rows launches run-triage.sh once, argv crolin, and
#       state/wake-keys-crolin holds CRO-12
#   W5  wake-loop on the W2 rows (none) launches nothing
#   W6  triage-gate crolin --pending exits 0 and .linear in
#       state/crolin.gate.pending holds key CRO-12
#   W7  in stage 2 issue_closures read CRO-12 through the Linear stub (one
#       TrkIssue request) and released nothing: CRO-12 is open
#   W8  0 gh calls and 0 ssh calls in stage 2; every curl is a stub
#   W9  the Linear key sentinel is in no file under the scratch state, logs or
#       the recorded argv
#   HARNESS_TEST_SANDBOX=1 bash tests/webhook-to-triage-linear.bh-8449-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
. "$DIR/tests/lib/linear-stub.bh-7920.sh" || exit 1
. "$DIR/tests/lib/wake-claim-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
for c in jq node; do command -v "$c" >/dev/null 2>&1 || { echo "SKIP: $c missing"; exit 0; }; done

KEY=lin-api-fixture-sentinel-8449
HUB=box-hub
WORKER="$DIR/tests/lib/linear-wake-worker.bh-8449.mjs"
FIX="$DIR/tests/fixtures/triage-intake.bh-7920/linear"

# ---- stage 1: the real worker ---------------------------------------------------------
# stage1 <case> <out> — the wakes table after one delivery; exit 3 = no node:sqlite.
stage1() {
  node "$WORKER" "$2" "$1" 2>>"$T/worker.err"; local rc=$?
  [ "$rc" = 3 ] && { echo "SKIP: node:sqlite unavailable"; exit 0; }
  [ "$rc" = 0 ] || bad "stage 1 ($1): the worker exited $rc: $(tail -3 "$T/worker.err")"
}
stage1 cro "$T/w1.json"
stage1 eng "$T/w2.json"
stage1 badsig "$T/w3.json"
eq "W1 one wake row" "$(jq '.wakes | length' "$T/w1.json" 2>/dev/null)" 1
eq "W1 the row" "$(jq -r '.wakes[0] | [.repo, .kind, .key] | join(" ")' "$T/w1.json" 2>/dev/null)" "o/crolin issue CRO-12"
eq "W1 the route answered 200" "$(jq -r .status "$T/w1.json" 2>/dev/null)" 200
eq "W2 no route row: 0 wake rows" "$(jq '.wakes | length' "$T/w2.json" 2>/dev/null)" 0
eq "W2 the route answered 202 (unrouted)" "$(jq -r .status "$T/w2.json" 2>/dev/null)" 202
eq "W3 a wrong signature: 0 rows" "$(jq '.wakes | length' "$T/w3.json" 2>/dev/null)" 0
eq "W3 the route answered 401" "$(jq -r .status "$T/w3.json" 2>/dev/null)" 401

# ---- the harness tree stages 2 and 3 run in ------------------------------------------
W="$T/w"
mkdir -p "$W/bin" "$W/env" "$W/logs" "$W/locks" "$W/state" "$W/flags" "$W/calls"
scratch_install_closure bin/wake-loop.sh "$W" >/dev/null || exit 1
scratch_install_closure bin/jobs-client.sh "$W" >/dev/null || exit 1
scratch_install_closure bin/fleet-conf.sh "$W" >/dev/null || exit 1
rm -f "$W/bin/launch-fastpath.sh"   # no fast path: the wake buys a triage tick
cat > "$W/fleet.conf" <<CONF
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
crolin  o/crolin  https://cl.example  -  2  $HUB  192.0.2.10
CONF
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.example\n' > "$W/env/global.env"
printf 'LINEAR_API_KEY=%s\nLINEAR_TEAM=CRO\n' "$KEY" > "$W/env/crolin.env"
wcs_install "$W/bin"
wcs_identity "$W/bin" || { echo "wcs_identity failed"; exit 1; }
linear_stub_setup "$T" "$FIX" || { echo "stub setup failed"; exit 1; }
# curl: the wake routes first, then Linear and the settings rows.
cat > "$W/bin/curl" <<SH
#!/bin/bash
"\$(dirname "\$0")/wcs-routes" "\$@" && exit 0
exec "$T/lstub/curl" "\$@"
SH
printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/run-triage"\n' > "$W/bin/run-triage.sh"
printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/gh"\nexit 1\n' > "$W/bin/gh"
printf '#!/bin/bash\nexec "$@"\n' > "$W/bin/setsid"
chmod +x "$W/bin/"*
export HARNESS="$W" FLEET_CONF="$W/fleet.conf" BOX_NAME="$HUB" WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0 \
       WCS_WAKES="$T/wakes.json" WCS_SSH_LOG="$W/calls/ssh" LS_KEY_EXPECT="$KEY" GH_ETAG=0 \
       PATH="$W/bin:$PATH"
unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE
linear_set tracker_adapter.crolin linear
linear_set tracker_linear.crolin.team CRO

# waitfor <file> — the launch is detached; wait for its recorder.
waitfor() { local i; for i in $(seq 1 40); do [ -s "$1" ] && return 0; sleep 0.25; done; return 1; }
reset() { scratch_rm "$W/calls" || exit 1; scratch_rm "$W/state" || exit 1; mkdir -p "$W/calls" "$W/state"; linear_reset_log; }

# ---- stage 2: the real wake-loop -------------------------------------------------------
# W5 first: the W2 table (no rows) launches nothing.
reset; cp "$T/w2.json" "$T/wakes.json"
"$W/bin/wake-loop.sh" >>"$T/loop.out" 2>&1
sleep 1
eq "W5 no row: run-triage never launched" "$(cat "$W/calls/run-triage" 2>/dev/null | grep -c .)" 0
eq "W5 no row: 0 Linear requests" "$(linear_req_count)" 0

reset; cp "$T/w1.json" "$T/wakes.json"
"$W/bin/wake-loop.sh" >>"$T/loop.out" 2>&1; rc=$?
eq "W4 the loop exits 0" "$rc" 0
waitfor "$W/calls/run-triage" || bad "W4 run-triage.sh was never launched: $(tail -5 "$T/loop.out")"
sleep 0.5
eq "W4 run-triage launched once with argv crolin" "$(cat "$W/calls/run-triage" 2>/dev/null)" "crolin"
eq "W4 state/wake-keys-crolin holds CRO-12" "$(cat "$W/state/wake-keys-crolin" 2>/dev/null)" "CRO-12"
eq "W7 one TrkIssue read" "$(linear_req_count TrkIssue)" 1
eq "W7 the read was CRO-12" "$(linear_req_of TrkIssue | jq -r .variables.id 2>/dev/null)" CRO-12
grep -q 'released by the close' "$W/logs/"*.log "$T/loop.out" 2>/dev/null \
  && bad "W7 an open CRO-12 released something: $(grep -h 'released by' "$W/logs/"*.log "$T/loop.out")" || ok
eq "W8 0 gh calls" "$(cat "$W/calls/gh" "$LS_STATE/gh.log" 2>/dev/null | grep -c .)" 0
eq "W8 0 ssh calls" "$(cat "$W/calls/ssh" 2>/dev/null | grep -c .)" 0
[ ! -e "$LS_STATE/authbad" ] && ok || bad "W8 a Linear call carried the wrong key"
eq "W8 every Linear request was GraphQL to the stub" "$(awk '$3 != "https://api.linear.app/graphql"' "$LS_STATE/reqs" 2>/dev/null | grep -c .)" 0

# ---- stage 3: the real gate --------------------------------------------------------------
out=$("$DIR/bin/triage-gate.sh" crolin --pending 2>>"$T/gate.err"); rc=$?
eq "W6 --pending exits 0" "$rc" 0
eq "W6 the pending list holds CRO-12" "$(jq -r '[.linear[] | select(.key == "CRO-12")] | length' "$W/state/crolin.gate.pending" 2>/dev/null)" 1
eq "W8 the gate called no gh" "$(cat "$W/calls/gh" "$LS_STATE/gh.log" 2>/dev/null | grep -c .)" 0

# ---- W9 ----------------------------------------------------------------------------------
LEAK=$(grep -rlF -- "$KEY" "$W/state" "$W/logs" "$W/calls" "$LS_STATE" "$T/loop.out" "$T/gate.err" 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "W9 the Linear key reached: $LEAK"
[ "$(find "$W/state" "$W/calls" -type f | grep -c .)" -gt 0 ] && ok || bad "W9 scanned an empty tree"

echo "webhook-to-triage-linear.bh-8449: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
