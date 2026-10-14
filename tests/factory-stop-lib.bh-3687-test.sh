#!/bin/bash
# tests/factory-stop-lib.bh-3687-test.sh — bin/lib/factory-stop.sh (BH-3708,
# slice 1 of BH-3687): the factory-stop switch read through lane_switch.
#
# What is proved here, sourcing the real lib into a cold shell per case against
# a stub jobs worker:
#   L1 row switch.factory-stop=1 -> factory_stopped rc 0, FACTORY_STOP_SRC=fleet-row
#      (exported into a child);
#   L2 row =0 -> rc 1;
#   L3 no row, no flags/factory-stop -> rc 1, the "no readable" line in
#      logs/lane-gate.log, and zero /api/flags requests (file mode);
#   L4 values `yes`, ` on`, `2` and empty -> rc 1 plus _ls_row's line;
#   L5 a day-old cache holding row 1, worker down -> rc 0 (a stop recorded
#      before an outage keeps holding);
#   L6 factory_stop_status prints `state<TAB>since<TAB>actor<TAB>note` from one
#      GET /api/settings/switch.factory-stop: on / none / unknown; a worker
#      500, an unparseable body and an empty JOBS_URL are rc 2 with no output;
#      factory_stop_dur formats and refuses bad input;
#   N1 look-alike keys switch.factory-stopped / switch.factory-stop-x -> rc 1;
#   N2 a pauses row what=builds -> rc 1;
#   N3 worker down, no cache, no file -> rc 1 plus the no-readable line;
#   F1 the legacy flags/factory-stop file with no row -> rc 0, src
#      legacy-file, no no-readable line;
#   M1/M2 (D1) the L cases re-run against two mutants of the lib: one whose
#      factory_stopped always answers 1 must turn L1 red, one without the
#      no-readable log must turn L3 red.
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

FS="${FS_UNDER_TEST:-$DIR/bin/lib/factory-stop.sh}"
NOW=1758300000
mkdir -p "$T/h/bin/lib" "$T/h/flags" "$T/h/state" "$T/h/logs"
cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/lane-switch.sh" "$T/h/bin/lib/"
cp "$FS" "$T/h/bin/lib/factory-stop.sh"

# The stub worker. /api/settings answers the rows in $ROWS_FILE; the single-key
# GET answers $ONE_FILE verbatim; anything else (and everything, when
# UNREACHABLE is set) is an outage. Every request is counted in $CALLS.
cat > "$T/h/bin/jobs-client.sh" <<'SH'
_jobs_req() {
  echo "$1 $2" >> "$CALLS"
  [ -n "${UNREACHABLE:-}" ] && return 1
  case "$2" in
    /api/settings) printf '{"settings":%s}' "$(cat "$ROWS_FILE" 2>/dev/null || echo '[]')" ;;
    /api/settings/switch.factory-stop) [ -r "$ONE_FILE" ] || return 1; cat "$ONE_FILE" ;;
    /api/pauses*) printf '{"pauses":[{"what":"builds","active":1}]}' ;;
    *) return 1 ;;
  esac
}
SH

rows() {
  local out='[]' kv
  for kv in "$@"; do
    out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"api"}]')
  done
  printf '%s' "$out" > "$T/rows.json"
}
reset() {
  rm -rf "$T/h/state/lane-gate" "$T/h/logs/lane-gate.log"
  rm -f "$T/h/state/settings-cache.json" "$T/h/flags"/* "$T/rows.json" "$T/one.json"
  : > "$T/calls"; UNREACHABLE=""; URL=http://stub.invalid
}

# fs <shell code> — the code, run in a cold child that sourced the lib.
fs() {
  env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" ROWS_FILE="$T/rows.json" \
      ONE_FILE="$T/one.json" UNREACHABLE="$UNREACHABLE" JOBS_BOX=hub-1 JOBS_URL="$URL" \
      bash -c '
        set -uo pipefail
        . "$HARNESS/bin/lib/factory-stop.sh" || exit 9
        eval "$1"' _ "$1" 2>/dev/null
}
# ask — factory_stopped; prints `rc=<n> src=<FACTORY_STOP_SRC as a child sees it>`.
ask() { fs 'factory_stopped; rc=$?; echo "rc=$rc src=$(bash -c "echo \${FACTORY_STOP_SRC:-unset}")"'; }
calls() { grep -c -- "$1" "$T/calls"; }
loglines() { [ -f "$T/h/logs/lane-gate.log" ] && grep -c -- "$1" "$T/h/logs/lane-gate.log" || echo 0; }
NOROW='factory-stop: no readable switch.factory-stop row'

# L1 / L2 — the fleet row decides.
reset; rows switch.factory-stop=1
eq "L1 row 1 stops, src exported" "$(ask)" "rc=0 src=fleet-row"
reset; rows switch.factory-stop=0
eq "L2 row 0 does not stop" "$(ask)" "rc=1 src=fleet-row"
eq "L2 a row answer logs no no-readable line" "$(loglines "$NOROW")" "0"

# L3 — no row, no file: not stopped, said once, file mode only.
reset; rows
eq "L3 no row, no file" "$(ask)" "rc=1 src=legacy-file"
eq "L3 the no-readable line is logged" "$(loglines "$NOROW (src=legacy-file) — read as NOT stopped (pausing must be explicit)")" "1"
eq "L3 zero /api/flags requests" "$(calls '/api/flags')" "0"

# L4 — an unreadable value is never a stop.
for v in yes ' on' 2 ''; do
  reset; rows "switch.factory-stop=$v"
  eq "L4 value '$v'" "$(ask)" "rc=1 src=legacy-file"
  if [ -n "$v" ]; then
    eq "L4 value '$v' logged by _ls_row" "$(loglines "switch factory-stop: row switch.factory-stop='$v'")" "1"
  fi
  eq "L4 value '$v' falls to the no-readable line" "$(loglines "$NOROW")" "1"
done

# L5 — a stale cache outlives an outage.
reset; UNREACHABLE=1
jq -nc --argjson fa $((NOW-86400)) '{fetched_at:$fa,values:{"switch.factory-stop":"1"},seeded:{}}' \
  > "$T/h/state/settings-cache.json"
eq "L5 day-old cache row 1, worker down" "$(ask)" "rc=0 src=fleet-row"

# L6 — factory_stop_status and factory_stop_dur.
TAB=$(printf '\t')
SINCE=$(date -u -d "@$((NOW-7200))" '+%Y-%m-%dT%H:%M:%SZ')
reset
jq -nc --arg u "$SINCE" '{key:"switch.factory-stop",setting:{key:"switch.factory-stop",value:"1",updated_at:$u,actor:"hub",note:"x"},source:"settings",as_of:"t"}' > "$T/one.json"
OUT=$(fs 'factory_stop_status; echo "rc=$?"')
eq "L6 status on" "$OUT" "on${TAB}${SINCE}${TAB}hub${TAB}x
rc=0"
eq "L6 status is one direct GET" "$(calls '^GET /api/settings/switch.factory-stop$')" "1"
reset
jq -nc --arg u "$SINCE" '{setting:{value:"OFF",updated_at:$u,actor:"a\tb",note:"line1\nline2"}}' > "$T/one.json"
eq "L6 status off, tabs and newlines flattened" "$(fs 'factory_stop_status')" "off${TAB}${SINCE}${TAB}a b${TAB}line1 line2"
reset; echo '{"key":"switch.factory-stop","setting":null,"source":"none"}' > "$T/one.json"
eq "L6b no row prints none" "$(fs 'factory_stop_status; echo "rc=$?"')" "none${TAB}${TAB}${TAB}
rc=0"
reset
eq "L6c worker 500 -> rc 2, nothing printed" "$(fs 'factory_stop_status; echo "rc=$?"')" "rc=2"
reset; echo 'not json' > "$T/one.json"
eq "L6c unparseable body -> rc 2" "$(fs 'factory_stop_status; echo "rc=$?"')" "rc=2"
reset; echo '{"key":"switch.factory-stop"}' > "$T/one.json"
eq "L6c a body with no setting field -> rc 2" "$(fs 'factory_stop_status; echo "rc=$?"')" "rc=2"
reset; URL=""; echo '{"setting":null}' > "$T/one.json"
eq "L6c empty JOBS_URL -> rc 2" "$(fs 'factory_stop_status; echo "rc=$?"')" "rc=2"
reset; echo '{"setting":{"value":"maybe","updated_at":"u","actor":"x","note":""}}' > "$T/one.json"
eq "L6d an unknown value prints unknown" "$(fs 'factory_stop_status')" "unknown${TAB}u${TAB}x${TAB}"
reset
eq "L6e 7500s"  "$(fs 'factory_stop_dur 7500')"  "2h05m"
eq "L6e 11520s" "$(fs 'factory_stop_dur 11520')" "3h12m"
eq "L6e 3600s"  "$(fs 'factory_stop_dur 3600')"  "1h00m"
eq "L6e 125s"   "$(fs 'factory_stop_dur 125')"   "2m"
eq "L6e 0s"     "$(fs 'factory_stop_dur 0')"     "0m"
for b in -5 abc '' 1.5; do
  eq "L6e '$b' refused" "$(fs "factory_stop_dur '$b'; echo \"rc=\$?\"")" "rc=1"
done

# N1-N3 — nothing that is not the row stops the factory.
reset; rows switch.factory-stopped=1 switch.factory-stop-x=1
eq "N1 look-alike keys" "$(ask)" "rc=1 src=legacy-file"
reset; rows
eq "N2 a pauses row what=builds" "$(ask)" "rc=1 src=legacy-file"
reset; UNREACHABLE=1
eq "N3 worker down, no cache, no file" "$(ask)" "rc=1 src=legacy-file"
eq "N3 the no-readable line is logged" "$(loglines "$NOROW")" "1"

# F1 — a legacy file that says stop is a real answer, and not a no-readable one.
reset; rows; touch "$T/h/flags/factory-stop"
eq "F1 legacy file, no row" "$(ask)" "rc=0 src=legacy-file"
eq "F1 no no-readable line" "$(loglines "$NOROW")" "0"

# M1/M2 (D1) — the suite goes red on a lib that does not do the job.
if [ -z "${FS_UNDER_TEST:-}" ]; then
  mutant() { # mutant <name> <sed expr> <case that must go red>
    local m="$T/mutant-$1.sh" out
    sed "$2" "$FS" > "$m"
    if cmp -s "$m" "$FS"; then bad "M $1: the mutation did not apply"; return; fi
    out=$(FS_UNDER_TEST="$m" HARNESS_TEST_SANDBOX=1 bash "$0" 2>&1)
    grep -q "^FAIL: $3" <<<"$out" && ok || bad "M $1: $3 stayed green under the mutant"
  }
  mutant always-run 's/^factory_stopped() {$/factory_stopped() { return 1;/' "L1 row 1 stops"
  mutant no-norow-log '/_lg_log_throttled factory-stop-norow/d' "L3 the no-readable line is logged"
fi

echo "factory-stop-lib: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
