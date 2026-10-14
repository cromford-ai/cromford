#!/bin/bash
# tests/factory-stop-cli.bh-3687-test.sh — bin/factory-stop.sh (BH-3712, slice
# 5 of BH-3687): the operator CLI that writes and re-reads the settings row
# switch.factory-stop.
#
# The real script runs in a scratch HARNESS beside the real bin/lib/{factory-
# stop,lane-switch,lane-gate}.sh, against a stub jobs worker that stores what a
# PUT /api/settings wrote and answers the GETs from it:
#   C1  on with no --reason, or a blank one -> rc 2, no PUT, no log line;
#   C2  on -> the PUT body (key, value "1", actor, reason, note), rc 0 only
#       because the re-read shows the row, `factory-stop is ON`, one
#       logs/factory-stop.log line;
#   C2b the PUT answers 200 but the row does not change -> rc 1, NOT confirmed;
#   C3  off after C2 -> value "0", rc 0, `factory-stop is OFF`;
#   C4  PUT 500 on `on` -> rc 1 and exactly one alert line; C4b on `off` -> none;
#   C5  status: state, since, duration, actor, reason; no row -> OFF;
#       worker down -> status unknown, rc 1;
#   C6  bash -n and shellcheck -S error;
#   C7  actor registry-seed, or one with a space/`;` -> rc 2, no PUT;
#   C8  no bin/jobs-client.sh -> rc 3, NOT recorded, one alert on `on` only;
#   C9  the PUT lands but the settings GET fails, and a cache from before the
#       PUT already holds the asked-for value -> rc 1 (a stale cache is not a
#       re-read);
#   M1/M2 (D1) mutants: a CLI that confirms without re-reading must turn C2b
#       red; one whose alert call is dropped must turn C4 red.
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
has() { if grep -qF -- "$3" <<<"$2"; then ok; else bad "$1: '$3' not in: $2"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1: '$3' unexpectedly in: $2"; else ok; fi; }

CLI="${CLI_UNDER_TEST:-$DIR/bin/factory-stop.sh}"
H="$T/h"
mkdir -p "$H/bin/lib" "$H/flags" "$H/state" "$H/logs"
cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/factory-stop.sh" "$H/bin/lib/"
cp "$CLI" "$H/bin/factory-stop.sh"; chmod +x "$H/bin/factory-stop.sh"

# The stub worker. A PUT /api/settings answers PUT_HTTP (200) and, on a 2xx,
# upserts the row into $ROWS_FILE unless STICKY_ROWS=1. GET /api/settings
# answers those rows (GET_DOWN=1 is an outage); the single-key GET answers
# $ONE_FILE. Every request is "METHOD PATH BODY" in $CALLS.
cat > "$T/jobs-client.sh" <<'SH'
_jobs_req() {
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$CALLS"
  JOBS_HTTP=""
  case "$1 $2" in
    "PUT /api/settings")
      JOBS_HTTP="${PUT_HTTP:-200}"
      case "$JOBS_HTTP" in 2*) ;; *) return 1 ;; esac
      if [ "${STICKY_ROWS:-}" != 1 ]; then
        jq -c --argjson b "$3" '[.[] | select(.key != $b.key)] + [{key:$b.key,value:$b.value,actor:$b.actor}]' \
          "$ROWS_FILE" > "$ROWS_FILE.tmp" && mv "$ROWS_FILE.tmp" "$ROWS_FILE"
      fi
      printf '{"ok":true}'; return 0 ;;
    "GET /api/settings")
      [ -n "${GET_DOWN:-}" ] && return 1
      JOBS_HTTP=200; printf '{"settings":%s}' "$(cat "$ROWS_FILE")"; return 0 ;;
    "GET /api/settings/switch.factory-stop")
      [ -r "$ONE_FILE" ] || return 1
      JOBS_HTTP=200; cat "$ONE_FILE"; return 0 ;;
  esac
  return 1
}
SH
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
for a; do last="$a"; done
printf '%s\n' "$last" >> "$HARNESS/logs/ALERTS.log"
SH
chmod +x "$H/bin/alert-line.sh"

reset() {
  scratch_rm "$H/state/lane-gate"; rm -f "$H/state/settings-cache.json" "$H/logs"/* "$T/one.json"
  cp "$T/jobs-client.sh" "$H/bin/jobs-client.sh"
  echo '[]' > "$T/rows.json"; : > "$T/calls"
  PUT_HTTP=200; STICKY_ROWS=""; GET_DOWN=""; URL=http://stub.invalid
}
# fsc <args...> — the CLI as an operator runs it; prints stdout+stderr then `rc=<n>`.
fsc() {
  local out rc
  out=$(env HARNESS="$H" CALLS="$T/calls" ROWS_FILE="$T/rows.json" ONE_FILE="$T/one.json" \
      PUT_HTTP="$PUT_HTTP" STICKY_ROWS="$STICKY_ROWS" GET_DOWN="$GET_DOWN" JOBS_URL="$URL" JOBS_BOX=hub-1 \
      FACTORY_STOP_ACTOR="${ACTOR:-qa@box}" FACTORY_STOP_NOW="${NOW:-}" \
      "$H/bin/factory-stop.sh" "$@" 2>&1); rc=$?
  printf '%s\nrc=%s' "$out" "$rc"
}
rcof() { printf '%s' "${1##*rc=}"; }
puts() { grep -c '^PUT /api/settings ' "$T/calls"; }
putbody() { grep '^PUT /api/settings ' "$T/calls" | tail -1 | cut -d' ' -f3-; }
alerts() { [ -f "$H/logs/ALERTS.log" ] && grep -c . "$H/logs/ALERTS.log" || echo 0; }
oplog() { [ -f "$H/logs/factory-stop.log" ] && cat "$H/logs/factory-stop.log"; }

# C1 — a stop with no reason is refused before anything is sent.
reset
O=$(fsc on); eq "C1 on, no --reason -> rc 2" "$(rcof "$O")" 2
has "C1 says why" "$O" "factory-stop: --reason is required"
O=$(fsc on --reason "   "); eq "C1 on, blank reason -> rc 2" "$(rcof "$O")" 2
O=$(fsc off --reason ""); eq "C1 off, empty reason -> rc 2" "$(rcof "$O")" 2
eq "C1 no PUT" "$(puts)" 0
eq "C1 no operator log line" "$(oplog | grep -c .)" 0
O=$(fsc maybe --reason x); eq "C1 unknown verb -> rc 2" "$(rcof "$O")" 2
O=$(fsc on --reason x --bogus); eq "C1 unknown flag -> rc 2" "$(rcof "$O")" 2
eq "C1 still no PUT" "$(puts)" 0

# C2 — on: the body, the re-read, the log.
reset
O=$(fsc on --reason "  x  ")
eq "C2 on -> rc 0" "$(rcof "$O")" 0
has "C2 says ON from the row" "$O" "factory-stop is ON (settings switch.factory-stop)"
eq "C2 one PUT" "$(puts)" 1
eq "C2 PUT body" "$(putbody | jq -c -S .)" '{"actor":"qa@box","key":"switch.factory-stop","note":"x","reason":"x","value":"1"}'
eq "C2 re-read went to the worker" "$(grep -c '^GET /api/settings $' "$T/calls")" 1
eq "C2 one operator log line" "$(oplog | grep -c .)" 1
eq "C2 log fields" "$(oplog | cut -f2-5)" "on	qa@box	confirmed	x"
has "C2 log line is timestamped" "$(oplog | cut -f1)" "Z"
eq "C2 no alert" "$(alerts)" 0

# C3 — off after C2 flips the same row.
O=$(fsc off --reason y)
eq "C3 off -> rc 0" "$(rcof "$O")" 0
has "C3 says OFF" "$O" "factory-stop is OFF (settings switch.factory-stop)"
eq "C3 value 0" "$(putbody | jq -r .value)" 0
eq "C3 second log line" "$(oplog | tail -1 | cut -f2-5)" "off	qa@box	confirmed	y"

# C2b — the worker answered 200 but the row never changed.
reset; STICKY_ROWS=1
O=$(fsc on --reason x)
eq "C2b PUT 200, re-read 0 row-less -> rc 1" "$(rcof "$O")" 1
has "C2b NOT confirmed" "$O" "factory-stop ON NOT confirmed"
hasnt "C2b never claims ON" "$O" "factory-stop is ON"
eq "C2b log says not-confirmed" "$(oplog | cut -f4)" "not-confirmed"
reset; STICKY_ROWS=1; echo '[{"key":"switch.factory-stop","value":"0","actor":"qa"}]' > "$T/rows.json"
O=$(fsc on --reason x)
eq "C2b row still 0 -> rc 1" "$(rcof "$O")" 1
has "C2b row still 0 names the row" "$O" "NOT confirmed: settings switch.factory-stop"
reset; STICKY_ROWS=1; echo '[{"key":"switch.factory-stop","value":"1","actor":"qa"},{"key":"switch.factory-stop.hub-1","value":"1","actor":"qa"}]' > "$T/rows.json"
O=$(fsc off --reason x)
eq "C2b off while the box row says 1 -> rc 1" "$(rcof "$O")" 1
hasnt "C2b never claims OFF" "$O" "factory-stop is OFF"
reset; STICKY_ROWS=1
O=$(fsc off --reason x)
eq "C2b off with no row at all is not a confirmation -> rc 1" "$(rcof "$O")" 1

# C4 — a failed PUT is rc 1 and, for `on` only, one alert line.
reset; PUT_HTTP=500
O=$(fsc on --reason x)
eq "C4 PUT 500 -> rc 1" "$(rcof "$O")" 1
has "C4 NOT recorded" "$O" "factory-stop ON NOT recorded (http=500)"
eq "C4 exactly one alert" "$(alerts)" 1
has "C4 alert text" "$(cat "$H/logs/ALERTS.log" 2>/dev/null)" "factory-stop ON requested by qa@box was NOT recorded (http=500)"
eq "C4 log not-recorded" "$(oplog | cut -f4)" "not-recorded"
hasnt "C4 no re-read after a failed PUT" "$(cat "$T/calls")" "GET /api/settings"
reset; PUT_HTTP=500
O=$(fsc off --reason x)
eq "C4b off PUT 500 -> rc 1" "$(rcof "$O")" 1
eq "C4b no alert on off" "$(alerts)" 0

# C5 — status.
reset
NOW=1758300000
SINCE=$(date -u -d "@$((NOW - 11520))" '+%Y-%m-%dT%H:%M:%SZ')
jq -nc --arg u "$SINCE" '{key:"switch.factory-stop",setting:{value:"1",updated_at:$u,actor:"qa",note:"why"}}' > "$T/one.json"
O=$(fsc status)
eq "C5 status -> rc 0" "$(rcof "$O")" 0
has "C5 state" "$O" "factory-stop is ON"
has "C5 since and duration" "$O" "since $SINCE (3h12m)"
has "C5 actor" "$O" "by qa"
has "C5 reason" "$O" "reason: why"
eq "C5 status writes nothing" "$(puts)" 0
echo '{"key":"switch.factory-stop","setting":null}' > "$T/one.json"
O=$(fsc status)
eq "C5 no row -> rc 0" "$(rcof "$O")" 0
has "C5 no row reads OFF" "$O" "factory-stop is OFF (no switch.factory-stop row)"
jq -nc '{setting:{value:"0",updated_at:"garbage",actor:"qa",note:"n"}}' > "$T/one.json"
O=$(fsc status)
has "C5 OFF row" "$O" "factory-stop is OFF"
hasnt "C5 unparseable since prints no duration" "$O" "("
rm -f "$T/one.json"
O=$(fsc status)
eq "C5 worker down -> rc 1" "$(rcof "$O")" 1
has "C5 worker down says unknown" "$O" "factory-stop status unknown: the jobs worker did not answer"
NOW=""

# C6 — the script as shipped parses and lints.
if bash -n "$CLI"; then ok; else bad "C6 bash -n"; fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S error "$CLI"; then ok; else bad "C6 shellcheck -S error"; fi
fi
[ -x "$DIR/bin/factory-stop.sh" ] && ok || bad "C6 bin/factory-stop.sh is not executable"

# C7 — actors that must never be written.
reset
for a in registry-seed 'a b' 'x;rm' ''; do
  O=$(ACTOR=x fsc --actor "$a" on --reason x)
  eq "C7 actor '$a' -> rc 2" "$(rcof "$O")" 2
done
O=$(ACTOR=registry-seed fsc on --reason x)
eq "C7 FACTORY_STOP_ACTOR=registry-seed -> rc 2" "$(rcof "$O")" 2
eq "C7 no PUT" "$(puts)" 0
O=$(fsc --actor operator@example.com on --reason x)
eq "C7 --actor beats FACTORY_STOP_ACTOR" "$(putbody | jq -r .actor)" "operator@example.com"

# C8 — no jobs client.
reset; rm -f "$H/bin/jobs-client.sh"
O=$(fsc on --reason x)
eq "C8 no client -> rc 3" "$(rcof "$O")" 3
has "C8 NOT recorded" "$O" "factory-stop ON NOT recorded: jobs not configured"
eq "C8 one alert on on" "$(alerts)" 1
O=$(fsc off --reason x)
eq "C8 off no client -> rc 3" "$(rcof "$O")" 3
eq "C8 no alert on off" "$(alerts)" 1
reset; URL=""
O=$(fsc on --reason x)
eq "C8 empty JOBS_URL -> rc 3" "$(rcof "$O")" 3
eq "C8 empty JOBS_URL sent nothing" "$(puts)" 0

# C9 — a cache written before the PUT is not a re-read.
reset; GET_DOWN=1
jq -nc --argjson fa "$(($(date -u +%s) - 30))" '{fetched_at:$fa,values:{"switch.factory-stop":"1"},seeded:{}}' > "$H/state/settings-cache.json"
O=$(fsc on --reason x)
eq "C9 PUT ok, GET down, old cache says 1 -> rc 1" "$(rcof "$O")" 1
hasnt "C9 never claims ON" "$O" "factory-stop is ON"

# M1/M2 (D1) — the suite goes red on a CLI that does not do the job.
if [ -z "${CLI_UNDER_TEST:-}" ]; then
  mutant() { # mutant <name> <sed expr> <case that must go red>
    local m="$T/mutant-$1.sh" out
    sed "$2" "$CLI" > "$m"
    if cmp -s "$m" "$CLI"; then bad "M $1: the mutation did not apply"; return; fi
    out=$(CLI_UNDER_TEST="$m" HARNESS_TEST_SANDBOX=1 bash "$0" 2>&1)
    grep -q "^FAIL: $3" <<<"$out" && ok || bad "M $1: $3 stayed green under the mutant"
  }
  mutant no-reread 's/^confirmed() {$/confirmed() { return 0;/' "C2b PUT 200, re-read 0 row-less -> rc 1"
  mutant no-alert '/alert-line.sh" --id factory-stop-unrecorded/s/^/: /' "C4 exactly one alert"
fi

echo "factory-stop-cli: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
