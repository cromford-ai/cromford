#!/bin/bash
# tests/fleet-status-ci-advisory.bh-9210-test.sh — BH-9210: the fleet-status
# snapshot's `ci_advisory_red`, the heads per repo marked red only by advisory
# failures in the last 24 h, read from state/merge-conductor/ci-advisory-red.tsv
# (written by mca_note in bin/lib/mc-ci-advisory.sh). Driven through the real
# bin/fleet-status-push.sh with curl and beat.sh replaced by capture stubs, so
# nothing leaves the machine.
#   F1  two repos: [{repo, heads}] most heads first; the beat carries the field
#   F2  a line older than 24 h is not counted
#   F3  one head written twice counts 1; a junk line is dropped
#   F4  no file (no state/merge-conductor at all) → [] and the push still happens
# Run: HARNESS_TEST_SANDBOX=1 bash tests/fleet-status-ci-advisory.bh-9210-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: fleet-status-ci-advisory: $1"; }

mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/flags" "$T/env" "$T/builds" "$T/fakebin"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$T/bin/"
cp "$DIR/bin/alert_family.py" "$T/bin/"
printf 'HARNESS_SECRET=test-secret-fixture\nWATCHDOG_URL=http://watchdog.invalid\n' > "$T/env/global.env"
printf '#!/bin/bash\nprintf %%s "$1" > %s/BEAT.json\n' "$T" > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
printf '#!/bin/bash\ncat > %s/PUSH.json\n' "$T" > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
cat > "$T/fleet.conf" <<'EOF'
alpha-os Org/alpha https://a.example /api/board 2 hub
EOF

run() { rm -f "$T/PUSH.json" "$T/BEAT.json"; PATH="$T/fakebin:$PATH" HARNESS="$T" FLEET_CONF="$T/fleet.conf" bash "$DIR/bin/fleet-status-push.sh"; }
q()   { jq -r "$1" "$T/PUSH.json" 2>/dev/null; }

# The push reads its own clock; every line sits far from the 24 h edge.
NOW=$(date +%s)
MC="$T/state/merge-conductor"
F="$MC/ci-advisory-red.tsv"
sha() { printf "$1%.0s" $(seq 40); }
line() { mkdir -p "$MC"; printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$F"; }

# ── F1 + F2: two repos, one old line ────────────────────────────────────────
line $((NOW - 300)) Org/alpha "$(sha 1)" unit-clock
line $((NOW - 600)) Org/alpha "$(sha 2)" unit-clock,unit-shuffle
line $((NOW - 900)) Org/beta "$(sha 3)" unit-clock
line $((NOW - 90000)) Org/beta "$(sha 4)" unit-clock
run
[ -s "$T/PUSH.json" ] && ok || bad "F1: nothing was pushed"
[ "$(q '.ci_advisory_red | tojson')" = '[{"repo":"Org/alpha","heads":2},{"repo":"Org/beta","heads":1}]' ] \
  && ok || bad "F1/F2: two heads of Org/alpha, one of Org/beta (the old line not counted), got $(q '.ci_advisory_red | tojson')"
[ -s "$T/BEAT.json" ] && [ "$(jq -c '.ci_advisory_red' "$T/BEAT.json")" = "$(q '.ci_advisory_red | tojson')" ] \
  && ok || bad "F1: the beat carries the same field"
[ "$(q 'has("projects")')" = true ] && ok || bad "F1: the rest of the snapshot is there"

# ── F3: one head twice, a junk line ─────────────────────────────────────────
scratch_rm "$MC"
line $((NOW - 300)) Org/alpha "$(sha 1)" unit-clock
line $((NOW - 200)) Org/alpha "$(sha 1)" unit-shuffle
printf 'junk\n' >> "$F"
line abc Org/gamma "$(sha 5)" unit-clock
run
[ "$(q '.ci_advisory_red | tojson')" = '[{"repo":"Org/alpha","heads":1}]' ] && ok || bad "F3: one head counts 1, junk dropped, got $(q '.ci_advisory_red | tojson')"

# ── F4: no file ─────────────────────────────────────────────────────────────
scratch_rm "$MC"
run
[ -s "$T/PUSH.json" ] && ok || bad "F4: nothing was pushed"
[ "$(q '.ci_advisory_red | tojson')" = '[]' ] && ok || bad "F4: a missing file is [], got $(q '.ci_advisory_red | tojson')"

echo "fleet-status-ci-advisory.bh-9210: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
