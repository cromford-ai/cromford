#!/bin/bash
# tests/triage-intake-linear.bh-7920-test.sh — BH-7920: the real
# bin/triage-gate.sh reads a Linear project through the tracker contract.
# A stubbed Linear GraphQL endpoint (tests/lib/linear-stub.bh-7920.sh) serves
# three issues: CRO-12 (Todo, ai-build, two comments), CRO-13 (Done, ai-build)
# and CRO-14 (Todo, no label), whatever the filter asks.
#
#   I1  --pending exits 0 and writes state/crolin.gate.pending
#   I2  its .linear holds exactly CRO-12 (id == key), with updatedAt and commentCount
#   I3  CRO-13 (Done) and CRO-14 (unlabeled) are absent
#   I4  the request was TrkIssues for team CRO, label ai-build; no gh call
#   I5  --thread CRO-12 prints the fixture's comments in order
#   I6  --signal CRO-12 prints 16 hex characters
#   I7  --buildable and --buildable-strict CRO-12 are OK (one Linear read);
#       --buildable-strict CRO-404 is BLOCKED unreadable
#   I8  no tracker_adapter row (column 4 `-`): the GitHub arm, no Linear call
#   I9  no LINEAR_API_KEY in the env file: 0 settings requests, 0 Linear requests
#   I10 plain mode: RUN no-gate-state, --seed, SKIP no-change (1 tickets), and a
#       new comment on CRO-12 (2 -> 3) is RUN board-changed, and the board
#       self-write classifier (BASE/BP/TOKEN only) is never run
#   I11 the key reached no file under the scratch state, logs or stub state
#   I12 the settings worker answers 500: the GitHub arm, no Linear call
#   I13 a Linear context that does not load: --pending exit 1, plain SKIP
#       token-unresolved, --seed SEED-FAILED, and one ALERTS line for all three
#   HARNESS_TEST_SANDBOX=1 bash tests/triage-intake-linear.bh-7920-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/linear-stub.bh-7920.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

KEY=lin-api-fixture-sentinel-7920
FIX="$DIR/tests/fixtures/triage-intake.bh-7920/linear"
H="$T/h"; GATE="$DIR/bin/triage-gate.sh"
mkdir -p "$H/bin" "$H/env" "$H/state" "$H/logs" "$H/flags" "$T/out"
cp "$DIR/bin/fleet-conf.sh" "$H/bin/"
# The gate hands a self-write classifier's stderr to this; it must stay unused.
printf '#!/bin/bash\necho "$*" >> "%s/logs/alert-line.log"\n' "$H" > "$H/bin/alert-line.sh"; chmod +x "$H/bin/alert-line.sh"
cat > "$H/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
crolin  o/crolin  https://x.example  -  2
CONF
linear_stub_setup "$T" "$FIX" || { echo "stub setup failed"; exit 1; }
export HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_ETAG=0 LS_KEY_EXPECT="$KEY"
envfile() { printf 'LINEAR_API_KEY=%s\nLINEAR_TEAM=CRO\n' "$KEY" > "$H/env/crolin.env"; }
envfile
linear_set tracker_adapter.crolin linear
linear_set tracker_linear.crolin.team CRO
fresh_state() { rm -f "$H/state/crolin.gate.json" "$H/state/crolin.gate.pending" "$H/state/crolin.gate-meta" "$H/flags"/alerted-token-*; linear_reset_log; }
gate() { "$GATE" crolin "$@" 2>>"$T/out/gate.err"; }

# I1-I4 --pending
fresh_state
out=$(gate --pending); rc=$?
printf '%s' "$out" >> "$T/out/all.out"
[ "$rc" = 0 ] && [ -s "$H/state/crolin.gate.pending" ] && ok || bad "I1 --pending must exit 0 and write the pending file (rc=$rc)"
P="$H/state/crolin.gate.pending"
[ "$(jq -c '[.linear[] | [.id, .key]]' "$P" 2>/dev/null)" = '[["CRO-12","CRO-12"]]' ] && ok || bad "I2 .linear must hold exactly CRO-12: $(cat "$P" 2>/dev/null)"
[ "$(jq -c '.linear[0] | [.updatedAt, .commentCount, .state, .status]' "$P" 2>/dev/null)" = '["2026-10-21T09:15:00Z",2,"open","Todo"]' ] \
  && ok || bad "I2 CRO-12's updatedAt, commentCount, state and status: $(jq -c '.linear[0]' "$P" 2>/dev/null)"
[ "$(jq -c 'keys' "$P" 2>/dev/null)" = '["linear"]' ] && ok || bad "I2 the fingerprint is {linear: rows}: $(jq -c 'keys' "$P" 2>/dev/null)"
grep -qE 'CRO-13|CRO-14' "$P" && bad "I3 a Done or unlabeled issue reached the pending file" || ok
[ "$(linear_req_count TrkIssues)" = 1 ] && ok || bad "I4 one TrkIssues request: $(cat "$LS_STATE/reqs" 2>/dev/null)"
[ "$(linear_req_of TrkIssues | jq -c '[.variables.team, .variables.label]')" = '["CRO","ai-build"]' ] && ok || bad "I4 team CRO, label ai-build: $(linear_req_of TrkIssues | jq -c .variables)"
[ ! -s "$LS_STATE/gh.log" ] && ok || bad "I4 the gate called gh: $(cat "$LS_STATE/gh.log")"
[ ! -e "$LS_STATE/authbad" ] && ok || bad "I4 a Linear call carried the wrong key"

# I5 --thread
out=$(gate --thread CRO-12); rc=$?
printf '%s' "$out" >> "$T/out/all.out"
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -c '[.doc.comments[].body]' 2>/dev/null)" = '["Can it include the fee column?","Yes, add the fee column too."]' ] \
  && ok || bad "I5 --thread CRO-12 must print the comments in order (rc=$rc): $out"
[ "$(printf '%s' "$out" | jq -r '.kind + " " + .doc.id' 2>/dev/null)" = "inapp CRO-12" ] && ok || bad "I5 the thread wrapper: $out"
out=$(gate --thread CRO-404); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "I5 a missing issue under --thread must exit 1 with nothing (rc=$rc out=$out)"

# I6 --signal
out=$(gate --signal CRO-12); rc=$?
[ "$rc" = 0 ] && grep -qxE '[0-9a-f]{16}' <<<"$out" && ok || bad "I6 --signal must print 16 hex (rc=$rc): $out"

# I7 --buildable
linear_reset_log
[ "$(gate --buildable CRO-12)" = OK ] && ok || bad "I7 --buildable CRO-12: $(gate --buildable CRO-12)"
[ "$(linear_req_count TrkIssue)" = 1 ] && [ "$(linear_req_of TrkIssue | jq -r .variables.id)" = CRO-12 ] \
  && ok || bad "I7 --buildable CRO-12 must read CRO-12 from Linear once: $(cat "$LS_STATE/reqs" 2>/dev/null)"
# Strict fails closed on any read it could not make, so OK here proves the read.
[ "$(gate --buildable-strict CRO-12)" = OK ] && ok || bad "I7 --buildable-strict CRO-12: $(gate --buildable-strict CRO-12)"
[ "$(gate --buildable-strict CRO-404)" = "BLOCKED unreadable" ] && ok || bad "I7 --buildable-strict CRO-404: $(gate --buildable-strict CRO-404)"
[ "$(gate --buildable CRO-404)" = OK ] && ok || bad "I7 --buildable CRO-404 stays fail-open OK"

# I8 no row: column 4 `-` is github-issues, and the gate takes the GitHub arm
fresh_state; linear_unset tracker_adapter.crolin
gate --pending >/dev/null; rc=$?
[ "$rc" = 1 ] && [ -s "$LS_STATE/gh.log" ] && [ "$(linear_req_count)" = 0 ] && ok \
  || bad "I8 no row must take the GitHub arm and ask no Linear endpoint (rc=$rc gh=$(cat "$LS_STATE/gh.log" 2>/dev/null | grep -c .) linear=$(linear_req_count))"
linear_set tracker_adapter.crolin linear

# I9 no LINEAR_API_KEY in the env file: no settings call, no Linear call
fresh_state; printf 'LINEAR_TEAM=CRO\n' > "$H/env/crolin.env"
gate --pending >/dev/null
[ "$(linear_settings_count)" = 0 ] && [ "$(linear_req_count)" = 0 ] && ok \
  || bad "I9 no key must cost 0 settings and 0 Linear requests: settings=$(cat "$LS_STATE/settings.log" 2>/dev/null | tr '\n' ' ') linear=$(linear_req_count)"
envfile

# I10 plain mode
fresh_state; echo 9999999999 > "$H/state/crolin.gate-meta"   # a sweep clock in the future: the daily sweep is not due
out=$(gate); [ "$out" = "RUN no-gate-state" ] && ok || bad "I10 tick 1: $out"
out=$(gate --seed); [ "$out" = "SEEDED 1 tickets" ] && ok || bad "I10 --seed: $out"
out=$(gate); [ "$out" = "SKIP no-change (1 tickets)" ] && ok || bad "I10 tick 2 on an unchanged list: $out"
jq '.data.issues.nodes[0].comments.nodes += [{id:"00000000-0000-0000-0000-c00000000123"}]' "$FIX/issues.json" > "$LS_STATE/issues.json"
out=$(gate); [ "$out" = "RUN board-changed" ] && ok || bad "I10 a new comment on CRO-12 (2 -> 3): $out"
[ "$(jq -r '.linear[0].commentCount' "$H/state/crolin.gate.pending" 2>/dev/null)" = 3 ] && ok || bad "I10 the pending fingerprint carries the new count"
rm -f "$LS_STATE/issues.json"
[ ! -s "$LS_STATE/gh.log" ] && ok || bad "I10 plain mode called gh: $(cat "$LS_STATE/gh.log")"
[ ! -e "$H/logs/alert-line.log" ] && ok || bad "I10 the board self-write classifier ran for a Linear project: $(cat "$H/logs/alert-line.log")"

# I12 the settings worker is down: the column-4 fallback, the GitHub arm
fresh_state; linear_settings_down
gate --pending >/dev/null; rc=$?
[ "$rc" = 1 ] && [ "$(linear_req_count)" = 0 ] && [ -s "$LS_STATE/gh.log" ] && ok \
  || bad "I12 a down worker must fall back to the GitHub arm with no Linear request (rc=$rc linear=$(linear_req_count))"
rm -f "$LS_STATE/settings-down"

# I13 a Linear context that does not load (a team row that disagrees with the env file)
fresh_state; linear_set tracker_linear.crolin.team OPS
: > "$H/logs/ALERTS.log"
gate --pending >/dev/null; rc=$?
[ "$rc" = 1 ] && ok || bad "I13 --pending on a context that does not load must exit 1 (rc=$rc)"
out=$(gate); [ "$out" = "SKIP token-unresolved" ] && ok || bad "I13 plain mode: $out"
out=$(gate --seed); case "$out" in SEED-FAILED*) ok ;; *) bad "I13 --seed: $out" ;; esac
[ "$(gate --buildable-strict CRO-12)" = "BLOCKED token-unresolved" ] && ok || bad "I13 --buildable-strict"
[ "$(grep -c 'crolin' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "I13 exactly one ALERTS line: $(cat "$H/logs/ALERTS.log")"
grep -q 'linear' "$H/logs/ALERTS.log" && ok || bad "I13 the ALERTS line names the tracker: $(cat "$H/logs/ALERTS.log")"
[ "$(linear_req_count)" = 0 ] && [ ! -s "$LS_STATE/gh.log" ] && ok || bad "I13 a context that did not load must call no tracker (linear=$(linear_req_count))"
linear_set tracker_linear.crolin.team CRO

# I11 the key reached nothing it should not
LEAK=$(grep -rlF -- "$KEY" "$H/state" "$H/logs" "$H/flags" "$LS_STATE" "$T/out" 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "I11 the key reached: $LEAK"
[ "$(find "$H/state" "$LS_STATE" -type f | grep -c .)" -gt 0 ] && ok || bad "I11 scanned an empty tree"

echo "triage-intake-linear.bh-7920: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
