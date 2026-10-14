#!/bin/bash
# tests/fleet-status-ci-timeout.bh-3775-test.sh — BH-3788 (BH-3775.4): the
# fleet-status snapshot's `ci_timeout_budget`, built from the budget firings
# the merge conductor writes to state/merge-conductor/ci-timeout-firing.tsv
# (format: bin/lib/mc-ci-timeout.sh, CIT_FIRING_TSV). Driven through the real
# bin/fleet-status-push.sh with curl and beat.sh replaced by capture stubs, so
# nothing leaves the machine.
#   F1  a fresh firing → one row with the ten keys; a firing older than 24 h is
#       left out; the beat carries the same snapshot; no truncation key
#   F2  no file (no state/merge-conductor at all) → []
#   F3  garbage lines are skipped, never zero-filled; the push is otherwise whole
#   F4  25 pairs → the newest 20 plus ci_timeout_budget_truncated: 25
#   F5  a payload over 60000 bytes sheds ci_timeout_budget
#   F6  the same (repo, check) twice → one row, the newest line's values
# Run from anywhere: tests/fleet-status-ci-timeout.bh-3775-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/flags" "$T/env" "$T/builds" "$T/fakebin"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$T/bin/"
cp "$DIR/bin/alert_family.py" "$T/bin/"
printf 'HARNESS_SECRET=test-secret\nWATCHDOG_URL=http://watchdog.invalid\n' > "$T/env/global.env"
printf '#!/bin/bash\nprintf %%s "$1" > %s/BEAT.json\n' "$T" > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
printf '#!/bin/bash\ncat > %s/PUSH.json\n' "$T" > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
cat > "$T/fleet.conf" <<'EOF'
alpha-os Org/alpha https://a.example /api/board 2 hub
EOF

run() { rm -f "$T/PUSH.json" "$T/BEAT.json"; PATH="$T/fakebin:$PATH" HARNESS="$T" FLEET_CONF="$T/fleet.conf" bash "$DIR/bin/fleet-status-push.sh"; }
q()   { jq -r "$1" "$T/PUSH.json" 2>/dev/null; }

NOW=$(date +%s)
DAY=$(date -u +%Y-%m-%d)
MC="$T/state/merge-conductor"
F="$MC/ci-timeout-firing.tsv"
# line <epoch> <slug> <check> <wfpath> <T> <X> <Y> <p50> <p90> <prs> — one
# firing, the 11 tab-separated fields of the CIT_FIRING_TSV contract.
line() { mkdir -p "$MC"; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$DAY" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" >> "$F"; }
fresh() { line $((NOW - 300)) Org/alpha Unit .github/workflows/ci.yml 20 3 5 1100 1190 "12 14"; }

# ── F1: one fresh firing, one older than 24 h on a different check ──────────
fresh
line $((NOW - 90000)) Org/alpha Lint .github/workflows/ci.yml 10 4 5 500 590 "9"
run
[ -s "$T/PUSH.json" ] && ok || bad "F1: nothing was pushed"
[ "$(q '.ci_timeout_budget | length')" = 1 ] && ok || bad "F1: exactly the fresh row must be kept, got $(q '.ci_timeout_budget | tojson')"
[ "$(q '.ci_timeout_budget[0] | [.repo, .check, .workflow] | join("|")')" = "Org/alpha|Unit|.github/workflows/ci.yml" ] \
  && ok || bad "F1: repo/check/workflow must be the fixture's, got $(q '.ci_timeout_budget[0] | tojson')"
[ "$(q '.ci_timeout_budget[0] | [.timeout_min, .hit, .of, .p50_s, .p90_s] | tojson')" = '[20,3,5,1100,1190]' ] \
  && ok || bad "F1: numbers must be the fixture's, as numbers, got $(q '.ci_timeout_budget[0] | tojson')"
[ "$(q '.ci_timeout_budget[0].prs | tojson')" = '[12,14]' ] && ok || bad "F1: prs must be [12,14], got $(q '.ci_timeout_budget[0].prs | tojson')"
[ "$(q '.ci_timeout_budget[0].at')" = "$((NOW - 300))" ] && ok || bad "F1: at must be the firing epoch, got $(q '.ci_timeout_budget[0].at')"
[ "$(q '.ci_timeout_budget[0] | keys | tojson')" = '["at","check","hit","of","p50_s","p90_s","prs","repo","timeout_min","workflow"]' ] \
  && ok || bad "F1: keys must be exactly the ten, got $(q '.ci_timeout_budget[0] | keys | tojson')"
[ "$(q 'has("ci_timeout_budget_truncated")')" = false ] && ok || bad "F1: one row must carry no truncation count"
[ -s "$T/BEAT.json" ] && [ "$(jq -c 'del(.kind,.rkey)' "$T/BEAT.json")" = "$(jq -c . "$T/PUSH.json")" ] \
  && ok || bad "F1: the beat must carry the same snapshot as the push"

# ── F2: no file, no directory ────────────────────────────────────────────────
scratch_rm "$MC"
run
[ -s "$T/PUSH.json" ] && ok || bad "F2: nothing was pushed"
[ "$(q '.ci_timeout_budget | tojson')" = '[]' ] && ok || bad "F2: a missing file must be [], got $(q '.ci_timeout_budget | tojson')"
[ "$(q 'has("projects")')" = true ] && ok || bad "F2: the rest of the snapshot must still be there"

# ── F3: garbage lines are skipped ────────────────────────────────────────────
fresh
printf '%s\t%s\t%s\n' "$NOW" "$DAY" Org/alpha >> "$F"
line abc Org/alpha Bad1 .github/workflows/ci.yml 20 3 5 1100 1190 "1"
line $((NOW - 200)) Org/alpha Bad2 .github/workflows/ci.yml 20 3 5 1100 1190 "1 x"
line $((NOW - 200)) Org/alpha Bad3 .github/workflows/ci.yml 20 3 5 1100 1190 "1	extra"
run
jq -e . "$T/PUSH.json" >/dev/null 2>&1 && ok || bad "F3: the payload must stay valid JSON"
[ "$(q '[.ci_timeout_budget[].check] | tojson')" = '["Unit"]' ] && ok || bad "F3: only the good row may survive, got $(q '.ci_timeout_budget | tojson')"
[ "$(q 'has("projects") and has("lanes_down") and has("pushed_at")')" = true ] && ok || bad "F3: the rest of the snapshot must still be there"
[ "$(q 'has("snapshot_trimmed")')" = false ] && ok || bad "F3: a small payload must not be trimmed"
scratch_rm "$MC"

# ── F4: more than 20 pairs → the newest 20 and a truncation count ────────────
for i in $(seq 1 25); do
  line $((NOW - 100 - i)) Org/alpha "$(printf 'c%02d' "$i")" .github/workflows/ci.yml 20 3 5 1100 1190 ""
done
run
[ "$(q '.ci_timeout_budget | length')" = 20 ] && ok || bad "F4: the array must be capped at 20, got $(q '.ci_timeout_budget | length')"
[ "$(q '.ci_timeout_budget_truncated')" = 25 ] && ok || bad "F4: truncated must count all 25, got $(q '.ci_timeout_budget_truncated')"
[ "$(q '[.ci_timeout_budget[].at] | min')" = "$((NOW - 120))" ] && ok || bad "F4: the newest 20 must be kept, oldest kept at $(q '[.ci_timeout_budget[].at] | min')"
[ "$(q '.ci_timeout_budget[0].prs | tojson')" = '[]' ] && ok || bad "F4: an empty prs field must be [], got $(q '.ci_timeout_budget[0].prs | tojson')"
scratch_rm "$MC"

# ── F5: the 60000-byte backstop sheds it ─────────────────────────────────────
fresh
jq -n --arg k "$(printf 'p%.0s' $(seq 1 61000))" '{($k):{count:3}}' > "$T/state/stale-owed.json"
run
[ "$(q '.snapshot_trimmed')" = size ] && ok || bad "F5: an oversized payload must be trimmed, got $(q 'keys|tojson')"
[ "$(q 'has("ci_timeout_budget")')" = false ] && ok || bad "F5: ci_timeout_budget must be shed"
scratch_rm "$T/state/stale-owed.json"; rm -f "$T/state/stale-owed-reported.json"
scratch_rm "$MC"

# ── F6: the same pair twice → the newest line ────────────────────────────────
line $((NOW - 600)) Org/alpha Unit .github/workflows/ci.yml 20 2 5 1100 1190 "12"
line $((NOW - 60))  Org/alpha Unit .github/workflows/ci.yml 20 4 5 1100 1190 "12 14"
run
[ "$(q '.ci_timeout_budget | length')" = 1 ] && ok || bad "F6: one (repo, check) must be one row, got $(q '.ci_timeout_budget | tojson')"
[ "$(q '.ci_timeout_budget[0].hit')" = 4 ] && ok || bad "F6: the newest line's hit must win, got $(q '.ci_timeout_budget[0].hit')"
[ "$(q '.ci_timeout_budget[0].at')" = "$((NOW - 60))" ] && ok || bad "F6: the newest line's epoch must win, got $(q '.ci_timeout_budget[0].at')"

echo "fleet-status-ci-timeout: PASS $PASS FAIL $FAIL"
[ "$FAIL" -eq 0 ]
